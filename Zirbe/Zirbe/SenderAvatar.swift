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

/// A round avatar for a sender. Shows the monogram immediately and swaps in the
/// contact photo once the local lookup resolves, with no layout shift either way.
struct SenderAvatar: View {
    let participant: Participant
    var size: CGFloat = 30

    @State private var photo: UIImage?

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
            let found = await ContactAvatarService.shared.avatar(for: participant.address)
            if let data = found.imageData, let image = UIImage(data: data) {
                photo = image
            }
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

/// The deterministic monogram colors. Brand navy and cyan lead, then a cool,
/// muted spread so distinct senders read apart without clashing. White initials
/// sit on every one of them.
enum AvatarPalette {
    static let colors: [Color] = [
        Color(red: 0.05, green: 0.18, blue: 0.36), // brand navy
        Color(red: 0.00, green: 0.55, blue: 0.78), // brand cyan, darkened for white text
        Color(red: 0.20, green: 0.40, blue: 0.72), // royal blue
        Color(red: 0.36, green: 0.32, blue: 0.66), // indigo
        Color(red: 0.58, green: 0.32, blue: 0.58), // plum
        Color(red: 0.18, green: 0.52, blue: 0.50), // teal
        Color(red: 0.74, green: 0.44, blue: 0.30), // terracotta
        Color(red: 0.40, green: 0.50, blue: 0.28), // olive
    ]

    static func color(for address: String) -> Color {
        colors[Monogram.paletteIndex(for: address, count: colors.count)]
    }
}

/// Looks a sender up in the local Contacts store by email and returns their
/// photo and name. Lookups are cached in memory by address, the store query
/// runs off the main thread (this is an actor), and authorization is requested
/// lazily on the first lookup. A denied or restricted store returns an empty
/// result, so callers fall back to the monogram.
actor ContactAvatarService {
    static let shared = ContactAvatarService()

    struct Avatar: Sendable {
        let imageData: Data?
        let fullName: String?
    }

    private let store = CNContactStore()
    private var cache: [String: Avatar] = [:]

    func avatar(for address: String) async -> Avatar {
        let key = address.lowercased()
        if let cached = cache[key] { return cached }
        let result = await lookup(key)
        cache[key] = result
        return result
    }

    private func lookup(_ address: String) async -> Avatar {
        guard await hasAccess() else { return Avatar(imageData: nil, fullName: nil) }
        let keys: [CNKeyDescriptor] = [
            CNContactThumbnailImageDataKey as CNKeyDescriptor,
            CNContactFormatter.descriptorForRequiredKeys(for: .fullName),
        ]
        let predicate = CNContact.predicateForContacts(matchingEmailAddress: address)
        let matches = (try? store.unifiedContacts(matching: predicate, keysToFetch: keys)) ?? []
        guard let contact = matches.first else { return Avatar(imageData: nil, fullName: nil) }
        return Avatar(
            imageData: contact.thumbnailImageData,
            fullName: CNContactFormatter.string(from: contact, style: .fullName)
        )
    }

    /// Whether the store may be read, requesting permission once if it has never
    /// been asked. Limited access (iOS 18+) is enough to read matches.
    private func hasAccess() async -> Bool {
        let status = CNContactStore.authorizationStatus(for: .contacts)
        switch status {
        case .authorized:
            return true
        case .notDetermined:
            return (try? await store.requestAccess(for: .contacts)) ?? false
        default:
            if #available(iOS 18.0, *), status == .limited { return true }
            return false
        }
    }
}
