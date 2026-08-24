// Author: David M. Anderson
// Built with AI assistance (Claude, Anthropic)
//
// The avatar beside an incoming bubble: the sender's photo from the on-device
// address book when there is one, otherwise a colored circle with their
// initials. The lookup is local and display-only, nothing leaves the device,
// and a denied Contacts permission degrades silently to the monogram.

import SwiftUI
import Contacts
import ZirbeCore

/// A round avatar for a sender. Shows the contact photo when one is already
/// known, and otherwise the monogram, swapping the photo in once the local
/// lookup resolves — with no layout shift either way.
@MainActor
struct SenderAvatar: View {
    let participant: Participant
    var size: CGFloat = 30

    @State private var photo: UIImage?

    init(participant: Participant, size: CGFloat = 30) {
        self.participant = participant
        self.size = size
        // A face already resolved — a row scrolling back into view, or another
        // bubble from the same sender — is taken here rather than in `.task`, which
        // runs a frame later. Otherwise every recycled row shows a monogram for a
        // frame before the photo it already had lands again.
        _photo = State(initialValue: ContactAvatarCache.shared.resolved(participant.address) ?? nil)
    }

    var body: some View {
        ZStack {
            if let photo {
                Image(uiImage: photo)
                    .resizable()
                    .scaledToFill()
            } else {
                AvatarPalette.color(for: participant.address)
                monogram
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .task(id: participant.address) {
            guard ContactAvatarCache.shared.resolved(participant.address) == nil else { return }
            photo = await ContactAvatarCache.shared.avatar(for: participant.address)
        }
    }

    @ViewBuilder
    private var monogram: some View {
        let initials = Monogram.initials(displayName: participant.displayName, address: participant.address)
        if initials.isEmpty {
            Image(systemName: "person.fill")
                .font(.system(size: size * 0.5))
                .foregroundStyle(.white)
        } else {
            Text(initials)
                .font(.system(size: size * 0.42, weight: .semibold))
                .foregroundStyle(.white)
        }
    }
}

/// The deterministic monogram colors. Brand pine and teal lead, then a muted
/// spread from cool to warm so distinct senders read apart without clashing and
/// the set stays in the icon's natural-green family. White initials sit on every
/// one of them.
enum AvatarPalette {
    static let colors: [Color] = [
        Color(red: 0.17, green: 0.40, blue: 0.30), // brand pine
        Color(red: 0.09, green: 0.44, blue: 0.42), // teal
        Color(red: 0.16, green: 0.43, blue: 0.55), // lake blue
        Color(red: 0.24, green: 0.31, blue: 0.55), // slate indigo
        Color(red: 0.42, green: 0.29, blue: 0.46), // plum
        Color(red: 0.60, green: 0.35, blue: 0.24), // terracotta
        Color(red: 0.37, green: 0.42, blue: 0.18), // olive
        Color(red: 0.54, green: 0.43, blue: 0.18), // muted gold
    ]

    static func color(for address: String) -> Color {
        colors[Monogram.paletteIndex(for: address, count: colors.count)]
    }
}

/// The resolved contact photos, by address.
///
/// The cache sits on the main actor so a row can read it while it is being built,
/// and the lookup behind it runs off the main actor because a Contacts query is
/// disk I/O. Concurrent askers for the same address share one lookup rather than
/// each starting their own, which matters on first scroll when a run of bubbles
/// from one sender all appear at once.
///
/// A miss is cached as firmly as a hit: most senders have no contact photo, and
/// without that a sender who isn't in Contacts would be looked up again for every
/// message they have ever sent.
@MainActor
final class ContactAvatarCache {
    static let shared = ContactAvatarCache()

    /// Resolved faces. A `.some(nil)` means looked up and no photo, which is a
    /// different thing from an address not yet looked up at all.
    private var faces: [String: UIImage?] = [:]
    private var inFlight: [String: Task<UIImage?, Never>] = [:]
    private let lookup = ContactPhotoLookup()

    /// The face for an address if it has been resolved: nil while still unknown,
    /// `.some(nil)` once resolved to no photo.
    func resolved(_ address: String) -> UIImage?? {
        faces[address.lowercased()]
    }

    /// The face for an address, looking it up if this is the first ask.
    func avatar(for address: String) async -> UIImage? {
        let key = address.lowercased()
        if let known = faces[key] { return known }
        if let running = inFlight[key] { return await running.value }

        let task = Task { await lookup.photo(for: key) }
        inFlight[key] = task
        let image = await task.value
        inFlight[key] = nil
        faces[key] = image
        return image
    }
}

/// The Contacts query itself, off the main actor. Returns a decoded, draw-ready
/// image: `UIImage(data:)` defers the bitmap decode to the first draw, so handing
/// back an undecoded image would pay that cost again on every row that shows the
/// face instead of once here. Authorization is requested lazily on the first
/// lookup, and a denied or restricted store simply yields no photo, so callers
/// fall back to the monogram.
private actor ContactPhotoLookup {
    private let store = CNContactStore()

    func photo(for address: String) async -> UIImage? {
        guard await ContactsAuthorization.granted(store) else { return nil }
        let keys = [CNContactThumbnailImageDataKey as CNKeyDescriptor]
        let predicate = CNContact.predicateForContacts(matchingEmailAddress: address)
        let matches = (try? store.unifiedContacts(matching: predicate, keysToFetch: keys)) ?? []
        guard let data = matches.first?.thumbnailImageData, let image = UIImage(data: data) else {
            return nil
        }
        return await image.byPreparingForDisplay() ?? image
    }
}
