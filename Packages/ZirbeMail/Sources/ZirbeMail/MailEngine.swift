// Author: David M. Anderson
// Built with AI assistance (Claude, Anthropic)
//
// The mail engine adapter. Wraps SwiftMail's IMAPServer and returns Zirbe-owned
// MailEnvelope values. Intentionally thin: SwiftMail does the protocol work.
//
// The engine keeps a warm, authenticated session: one TLS connection and login
// are reused across operations rather than paid per call. Credentials are held
// in memory only, for the life of the session, so a connection the server drops
// between operations can be transparently restored. Nothing is persisted.

import Foundation
import Klartext
import Logging
import SwiftMail

public enum MailEngineError: Error {
    /// An operation was attempted before `connect(username:password:)`.
    case notConnected
}

public actor MailEngine {
    private let server: IMAPServer
    private let logger: Logger
    /// The credentials of the current session, in memory only. Set by `connect`,
    /// cleared by `disconnect`; used to restore a dropped connection.
    private var credentials: (username: String, password: String)?
    /// Whether we hold a live, authenticated session. Reset when the socket dies.
    private var isLoggedIn = false
    /// The resolved Sent mailbox name, cached after the first lookup so saving a
    /// sent copy doesn't re-list the server's special-use mailboxes each time.
    private var sentMailboxName: String?

    public init(config: MailServerConfig, logger: Logger = Logger(label: "zirbe.mail")) {
        self.logger = logger
        self.server = IMAPServer(host: config.host, port: config.port)
    }

    /// Establish or reuse an authenticated session with these credentials.
    /// Idempotent: when a live session already exists this returns immediately
    /// without a new connection or login. The password is held in memory only so
    /// a dropped connection can be restored; it is never written to disk.
    public func connect(username: String, password: String) async throws {
        credentials = (username, password)
        try await ensureSession()
    }

    /// Selects `mailbox` and returns the envelopes of the most recent `limit`
    /// messages, newest last (server order).
    public func fetchRecentEnvelopes(in mailbox: String, limit: Int = 20) async throws -> [MailEnvelope] {
        try await perform {
            let selection = try await self.server.selectMailbox(mailbox)
            self.logger.debug("selected \(mailbox): \(selection.messageCount) message(s)")
            guard let identifiers = selection.latest(limit) else { return [] }
            let infos = try await self.server.fetchMessageInfosBulk(using: identifiers)
            return infos.map(MailEnvelope.init)
        }
    }

    /// A mailbox's identity and current contents, for reconciling deletions: the
    /// server's UID-validity and the full set of UIDs it holds right now. The UID
    /// list is cheap (a UID `SEARCH ALL` returns identifiers only, no envelopes),
    /// so comparing it against the cached UIDs to prune mail deleted elsewhere is
    /// affordable even on a large mailbox. A change in `uidValidity` means the
    /// server renumbered the mailbox and every cached UID is stale.
    public func mailboxState(in mailbox: String) async throws -> MailboxState {
        try await perform {
            let selection = try await self.server.selectMailbox(mailbox)
            guard selection.messageCount > 0 else {
                return MailboxState(uidValidity: selection.uidValidity.value, uids: [])
            }
            let result: ExtendedSearchResult<UID> = try await self.server.extendedSearch(criteria: [.all])
            let uids = (result.all ?? result.partial?.results)?.toArray().map(\.value) ?? []
            return MailboxState(uidValidity: selection.uidValidity.value, uids: Set(uids))
        }
    }

    /// Fetches the readable text bodies of several messages in one mailbox,
    /// reusing the warm session. Selects the mailbox once, reads each message's
    /// body structure, then downloads all the chosen text parts in a single
    /// pipelined burst rather than one round trip at a time. Returns the decoded
    /// body keyed by the caller's message id; a message with no text part (or one
    /// that fails to decode) is simply absent from the result.
    ///
    /// Only text parts are downloaded, never attachments. Both the `text/plain`
    /// and `text/html` alternatives are fetched when a message carries both,
    /// because some senders ship an empty or stub plain part ("view in browser")
    /// beside the real content in HTML. The non-empty plain text wins when it has
    /// real content; otherwise the HTML is reduced to readable text. Either way
    /// the body records whether an HTML alternative exists, so the UI can offer
    /// the Web View without re-deriving it. A message that yields nothing is
    /// simply absent, so it isn't cached as empty.
    public func fetchTextBodies(
        in mailbox: String,
        messages: [(id: String, uid: UInt32)]
    ) async throws -> [String: MessageBody] {
        guard !messages.isEmpty else { return [:] }
        return try await perform {
            _ = try await self.server.selectMailbox(mailbox)

            // For each message, locate its plain and html text leaves (either may
            // be absent) from the cheap structure.
            var candidates: [(id: String, uid: UID, plain: MessagePart?, html: MessagePart?)] = []
            for message in messages {
                let uid = UID(message.uid)
                let structure = try await self.server.fetchStructure(uid)
                let plain = Self.textLeaf(in: structure, type: "text/plain")
                let html = Self.textLeaf(in: structure, type: "text/html")
                if plain != nil || html != nil {
                    candidates.append((message.id, uid, plain, html))
                }
            }
            guard !candidates.isEmpty else { return [:] }

            // Download every candidate section in one pipelined burst.
            var requests: [(uid: UID, section: Section)] = []
            for c in candidates {
                if let plain = c.plain { requests.append((c.uid, plain.section)) }
                if let html = c.html { requests.append((c.uid, html.section)) }
            }
            let fetched = try await self.server.fetchPartsPipelined(parts: requests)

            // Decode one part's bytes, matched back by UID and section.
            func text(of part: MessagePart?, uid: UID) -> String? {
                guard let part,
                      let data = fetched[uid]?.first(where: { $0.section == part.section })?.data
                else { return nil }
                var filled = part
                filled.data = data
                return filled.textContent
            }

            var bodies: [String: MessageBody] = [:]
            for c in candidates {
                let hasHTML = c.html != nil
                if let plain = text(of: c.plain, uid: c.uid),
                   !plain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    bodies[c.id] = MessageBody(text: plain, hasHTML: hasHTML)
                } else if let html = text(of: c.html, uid: c.uid) {
                    let reduced = Klartext.plainText(fromHTML: html)
                    if !reduced.isEmpty { bodies[c.id] = MessageBody(text: reduced, hasHTML: true) }
                }
            }
            return bodies
        }
    }

    /// Fetch one message's raw HTML body, over the warm session, for the Web
    /// View. Unlike `fetchTextBodies` this returns the markup verbatim (not
    /// reduced to text), so a `WKWebView` can render it, along with the inline
    /// images the markup references by `cid:` so the renderer can paint embedded
    /// logos and signature graphics from on-device bytes. Returns nil when the
    /// message has no HTML alternative.
    ///
    /// The HTML part and the referenced inline images are pulled in one pipelined
    /// round trip. Only `image/*` parts carrying a Content-ID the HTML actually
    /// references are kept; unreferenced inline parts and real attachments are
    /// never carried out. No remote resources the markup points at are touched
    /// here; loading those is the renderer's decision, off by default.
    public func fetchHTMLBody(in mailbox: String, uid: UInt32) async throws -> HTMLBody? {
        try await perform {
            _ = try await self.server.selectMailbox(mailbox)
            let u = UID(uid)
            let structure = try await self.server.fetchStructure(u)
            guard let htmlPart = Self.textLeaf(in: structure, type: "text/html") else { return nil }

            // Inline image candidates: image parts carrying a Content-ID. Fetch
            // them alongside the HTML in one round trip, then keep only the ones
            // the rendered HTML references once we can read it.
            let imageParts = structure.filter {
                $0.contentId != nil && $0.contentType.lowercased().hasPrefix("image/")
            }
            let requests = [(u, htmlPart.section)] + imageParts.map { (u, $0.section) }
            let fetched = try await self.server.fetchPartsPipelined(parts: requests)
            func bytes(of part: MessagePart) -> Data? {
                fetched[u]?.first(where: { $0.section == part.section })?.data
            }

            guard let htmlData = bytes(of: htmlPart) else { return nil }
            var filledHTML = htmlPart
            filledHTML.data = htmlData
            guard let html = filledHTML.textContent else { return nil }

            let referenced = Self.referencedCIDs(in: html)
            let images: [InlineImagePart] = imageParts.compactMap { part in
                guard let cid = part.contentId,
                      referenced.contains(Self.normalizeCID(cid)),
                      let raw = bytes(of: part) else { return nil }
                var filled = part
                filled.data = raw
                guard let decoded = filled.decodedData() else { return nil }
                let mime = part.contentType.components(separatedBy: ";").first?
                    .trimmingCharacters(in: .whitespaces) ?? part.contentType
                return InlineImagePart(contentID: cid, mimeType: mime, data: decoded)
            }
            return HTMLBody(html: html, images: images)
        }
    }

    /// The normalized Content-IDs an HTML body references via `cid:` URLs (in an
    /// `<img src>`, a CSS `url()`, anywhere), so only inline parts the page
    /// actually paints are shipped to the renderer.
    private static func referencedCIDs(in html: String) -> Set<String> {
        guard let regex = try? NSRegularExpression(
            pattern: "cid:([^\"'\\s)>]+)", options: .caseInsensitive
        ) else { return [] }
        let range = NSRange(html.startIndex..., in: html)
        var ids: Set<String> = []
        for match in regex.matches(in: html, range: range) {
            guard let r = Range(match.range(at: 1), in: html) else { continue }
            ids.insert(normalizeCID(String(html[r])))
        }
        return ids
    }

    /// Strip angle brackets and whitespace and lowercase, so a part's `<id@host>`
    /// matches the HTML's bare `cid:id@host`. Mirrors KlartextUI's normalization.
    private static func normalizeCID(_ contentID: String) -> String {
        contentID.trimmingCharacters(in: CharacterSet(charactersIn: "<> \t")).lowercased()
    }

    /// Save a copy of a just-sent message to the server's Sent mailbox, over the
    /// warm session, so it appears in other mail clients and survives a local
    /// rebuild. Flagged `\Seen` since the user wrote it. The same Message-ID as
    /// the SMTP send is carried through, so a retry that re-appends is the user's
    /// to avoid; this does not retry on a dropped connection (unlike the read
    /// path), because an APPEND that half-committed could otherwise be doubled.
    public func saveToSent(_ outgoing: OutgoingMessage) async throws {
        try await ensureSession()
        let mailbox = try await resolvedSentMailbox()
        try await server.append(email: Email(outgoing), to: mailbox, flags: [.seen])
    }

    /// Set or clear the `\Seen` flag on messages, over the warm session. Used to
    /// reflect a read/unread change made locally back to the server, so every
    /// client agrees. A no-op when no UIDs are given.
    public func setSeen(_ seen: Bool, in mailbox: String, uids: [UInt32]) async throws {
        guard !uids.isEmpty else { return }
        try await perform {
            _ = try await self.server.selectMailbox(mailbox)
            let set = UIDSet(uids.map(UID.init))
            try await self.server.store(flags: [.seen], on: set, operation: seen ? .add : .remove)
        }
    }

    /// Move messages to the server's Trash, over the warm session. SwiftMail
    /// resolves the special-use Trash mailbox (falling back to a folder named
    /// "Trash"), so deleting a conversation here matches deleting it in any other
    /// client. A no-op when no UIDs are given.
    public func trash(in mailbox: String, uids: [UInt32]) async throws {
        guard !uids.isEmpty else { return }
        try await perform {
            _ = try await self.server.selectMailbox(mailbox)
            try await self.server.moveToTrash(messages: UIDSet(uids.map(UID.init)))
        }
    }

    /// Close the session and forget the credentials. Call on sign-out.
    public func disconnect() async {
        isLoggedIn = false
        credentials = nil
        sentMailboxName = nil
        try? await server.disconnect()
    }

    // MARK: - Session

    /// The server's Sent mailbox name, resolved once and cached. Lists the
    /// special-use mailboxes on first call (which also populates the general
    /// list, so the name-based fallback for a server without SPECIAL-USE works
    /// too), then reads the Sent folder.
    private func resolvedSentMailbox() async throws -> String {
        if let sentMailboxName { return sentMailboxName }
        try await server.listSpecialUseMailboxes()
        let name = try await server.sentFolder.name
        sentMailboxName = name
        return name
    }

    /// Ensure a live, authenticated session, reusing the existing one when it is
    /// still connected. Cheap and safe to call before every operation.
    private func ensureSession() async throws {
        guard let credentials else { throw MailEngineError.notConnected }
        if isLoggedIn, await server.isConnected { return }
        if await !server.isConnected {
            try await server.connect()
        }
        try await server.login(username: credentials.username, password: credentials.password)
        isLoggedIn = true
        logger.debug("session ready for \(credentials.username)")
    }

    /// Run an operation against the warm session. If the connection has died by
    /// the time the operation runs, restore it once and retry; other failures
    /// propagate unchanged. Operations here are reads, so a retry is safe.
    private func perform<T>(_ operation: () async throws -> T) async throws -> T {
        try await ensureSession()
        do {
            return try await operation()
        } catch {
            guard await !server.isConnected else { throw error }
            logger.debug("connection dropped mid-operation; restoring and retrying once")
            isLoggedIn = false
            try await ensureSession()
            return try await operation()
        }
    }

    // MARK: - Body part selection

    /// The first text leaf of `type` (e.g. `text/plain`), skipping anything
    /// marked as an attachment.
    private static func textLeaf(in parts: [MessagePart], type: String) -> MessagePart? {
        parts.first {
            $0.contentType.lowercased().hasPrefix(type) && $0.disposition?.lowercased() != "attachment"
        }
    }
}
