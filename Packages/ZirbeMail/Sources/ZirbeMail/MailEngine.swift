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
    /// The requested MIME part wasn't found in the message's structure, e.g. the
    /// message changed on the server since its attachments were listed.
    case partNotFound
    /// The part's bytes couldn't be decoded with its transfer encoding.
    case decodeFailed
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
    /// The resolved Archive mailbox name, cached like `sentMailboxName` so
    /// archiving doesn't re-list the special-use mailboxes on every action.
    private var archiveMailboxName: String?
    /// The dedicated IDLE session watching a mailbox while live refresh is on.
    /// Held so `stopIdle()` can tear it down; nil when not watching.
    private var idleSession: IMAPIdleSession?

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

    /// List the server's folders, over the warm session, as Zirbe-owned values
    /// with each folder's special-use role resolved from its RFC 6154 attributes.
    /// The full set is returned, including non-selectable container folders (the
    /// `\Noselect` parents some servers use for hierarchy, marked
    /// `isSelectable == false`); deciding what to show, and how to flatten any
    /// hierarchy, is the caller's. Names are the server's own, the identifiers
    /// every other folder operation takes.
    public func listMailboxes() async throws -> [MailboxInfo] {
        try await perform {
            try await self.server.listMailboxes().map(MailboxInfo.init)
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
            // be absent) from the cheap structure. The full structure is kept too,
            // so the attachment parts can be read off it without a second fetch.
            var candidates: [(id: String, uid: UID, plain: MessagePart?, html: MessagePart?, structure: [MessagePart])] = []
            for message in messages {
                let uid = UID(message.uid)
                let structure = try await self.server.fetchStructure(uid)
                let plain = Self.textLeaf(in: structure, type: "text/plain")
                let html = Self.textLeaf(in: structure, type: "text/html")
                if plain != nil || html != nil {
                    candidates.append((message.id, uid, plain, html, structure))
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
                // The HTML markup, if any, drives both the readable-text fallback
                // and the attachment cid join (which parts the body references and
                // so are inline, not real attachments).
                let htmlMarkup = c.html != nil ? text(of: c.html, uid: c.uid) : nil
                let attachments = Self.userFacingAttachments(
                    in: c.structure,
                    bodySections: [c.plain?.section, c.html?.section].compactMap { $0 },
                    html: htmlMarkup
                )

                let hasHTML = c.html != nil
                if let plain = text(of: c.plain, uid: c.uid),
                   !plain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    bodies[c.id] = MessageBody(text: plain, hasHTML: hasHTML, attachments: attachments)
                } else if let htmlMarkup {
                    let reduced = Klartext.plainText(fromHTML: htmlMarkup)
                    if !reduced.isEmpty {
                        bodies[c.id] = MessageBody(text: reduced, hasHTML: true, attachments: attachments)
                    }
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

    /// Fetch and decode one attachment's bytes, over the warm session, identified
    /// by its MIME part section (the `partID` the chip carries). Re-reads the
    /// message's structure to recover the part's transfer encoding, downloads that
    /// one part, and returns its decoded bytes ready to write to a file. Re-reading
    /// the structure (rather than trusting a stored encoding) keeps the open robust
    /// and is cheap. Throws `partNotFound` when the section is gone (the message
    /// changed server-side) and `decodeFailed` when the bytes won't decode.
    public func fetchAttachment(in mailbox: String, uid: UInt32, partID: String) async throws -> Data {
        try await perform {
            _ = try await self.server.selectMailbox(mailbox)
            let u = UID(uid)
            let structure = try await self.server.fetchStructure(u)
            guard let part = structure.first(where: { $0.section.description == partID }) else {
                throw MailEngineError.partNotFound
            }
            let fetched = try await self.server.fetchPartsPipelined(parts: [(u, part.section)])
            guard let raw = fetched[u]?.first(where: { $0.section == part.section })?.data else {
                throw MailEngineError.partNotFound
            }
            var filled = part
            filled.data = raw
            guard let decoded = filled.decodedData() else {
                throw MailEngineError.decodeFailed
            }
            return decoded
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

    /// Set or clear the `\Flagged` flag on messages, over the warm session, so a
    /// flag toggled locally is reflected on the server and every client agrees. A
    /// no-op when no UIDs are given.
    public func setFlagged(_ flagged: Bool, in mailbox: String, uids: [UInt32]) async throws {
        guard !uids.isEmpty else { return }
        try await perform {
            _ = try await self.server.selectMailbox(mailbox)
            let set = UIDSet(uids.map(UID.init))
            try await self.server.store(flags: [.flagged], on: set, operation: flagged ? .add : .remove)
        }
    }

    /// Watch `mailbox` for server-side changes via IMAP IDLE on a dedicated
    /// connection, yielding once per change so the caller can re-sync. New mail
    /// (`exists`), expunges, and QRESYNC vanishes tick the stream; housekeeping
    /// events (flag-definition or recent-count changes, capability updates) are
    /// ignored. A burst collapses to a single pending tick, so a flurry of
    /// arrivals triggers one refresh, not many.
    ///
    /// The stream finishes when the server closes the session or `stopIdle()` is
    /// called. A prior `connect` is required: the IDLE connection reuses the
    /// session's authentication. SwiftMail renews IDLE and reconnects underneath,
    /// so a dropped socket doesn't silently end the watch. The dedicated IDLE
    /// connection is separate from the warm session, so a sync triggered in
    /// response runs on the primary connection without disturbing the watch.
    public func idleChanges(in mailbox: String) async throws -> AsyncStream<Void> {
        try await ensureSession()
        await stopIdle()
        let session = try await server.idle(on: mailbox)
        idleSession = session
        return AsyncStream<Void>(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let consumer = Task.detached {
                for await event in session.events {
                    switch event {
                    case .exists, .expunge, .vanished:
                        continuation.yield()
                    default:
                        break
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in consumer.cancel() }
        }
    }

    /// Tear down the IDLE session and its dedicated connection, ending the change
    /// stream. Safe to call when not watching.
    public func stopIdle() async {
        guard let session = idleSession else { return }
        idleSession = nil
        try? await session.done()
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

    /// Move messages from one folder to another, over the warm session, by the
    /// server's own folder names. Uses the IMAP MOVE extension where the server
    /// supports it, otherwise COPY + `\Deleted` + EXPUNGE underneath; either way
    /// the messages leave the source and appear in the destination, so every
    /// client agrees. A no-op when no UIDs are given. Like `trash` (itself a
    /// move), a connection dropped mid-move is restored and retried once.
    public func move(in mailbox: String, uids: [UInt32], to destination: String) async throws {
        guard !uids.isEmpty else { return }
        try await perform {
            _ = try await self.server.selectMailbox(mailbox)
            try await self.server.move(messages: UIDSet(uids.map(UID.init)), to: destination)
        }
    }

    /// Move messages to the server's Archive folder, over the warm session.
    /// SwiftMail resolves the special-use Archive folder, falling back to one
    /// named "Archive". Unlike SwiftMail's own `archive`, this does not mark the
    /// messages `\Seen`: archiving preserves unread state, matching Apple Mail.
    /// A no-op when no UIDs are given.
    public func archive(in mailbox: String, uids: [UInt32]) async throws {
        guard !uids.isEmpty else { return }
        try await perform {
            let destination = try await self.resolvedArchiveMailbox()
            _ = try await self.server.selectMailbox(mailbox)
            try await self.server.move(messages: UIDSet(uids.map(UID.init)), to: destination)
        }
    }

    /// Move messages to the server's Junk folder, over the warm session, so a
    /// client-side "mark as junk" matches every other client. SwiftMail resolves
    /// the special-use Junk folder, falling back to one named "Junk" or "Spam".
    /// A no-op when no UIDs are given.
    public func markJunk(in mailbox: String, uids: [UInt32]) async throws {
        guard !uids.isEmpty else { return }
        try await perform {
            _ = try await self.server.selectMailbox(mailbox)
            try await self.server.markAsJunk(messages: UIDSet(uids.map(UID.init)))
        }
    }

    /// Close the session and forget the credentials. Call on sign-out. Tears down
    /// any live IDLE watch first, so its dedicated connection closes too.
    public func disconnect() async {
        await stopIdle()
        isLoggedIn = false
        credentials = nil
        sentMailboxName = nil
        archiveMailboxName = nil
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

    /// The server's Archive mailbox name, resolved once and cached. Lists the
    /// special-use mailboxes on first call (which also populates the general list,
    /// so the name-based fallback works on a server without SPECIAL-USE), then
    /// reads the Archive folder. Throws if the server has no archive folder.
    private func resolvedArchiveMailbox() async throws -> String {
        if let archiveMailboxName { return archiveMailboxName }
        try await server.listSpecialUseMailboxes()
        let name = try await server.archiveFolder.name
        archiveMailboxName = name
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

    // MARK: - Attachments

    /// The user-facing attachments of a message: its non-body parts, resolved
    /// against the HTML so the parts the body references inline (signature logos,
    /// embedded images) are dropped and only real attachments remain. The cid join
    /// is Klartext's, the single matching rule both apps trust; with no HTML every
    /// part is a real attachment. Names with no filename fall back to a type label.
    static func userFacingAttachments(
        in parts: [MessagePart],
        bodySections: [Section],
        html: String?
    ) -> [AttachmentInfo] {
        // The candidate parts and the inputs derived from them stay index-aligned
        // (Klartext's classify maps inputs 1:1 in order), so zipping the resolved
        // attachments back to their source parts recovers each one's section for
        // the partID. The cid join then drops the parts the body references inline.
        let candidates = attachmentParts(in: parts, excluding: bodySections)
        guard !candidates.isEmpty else { return [] }
        let resolved = Klartext.parse(html: html, attachments: candidates.map(rawInput)).attachments
        return zip(resolved, candidates).compactMap { attachment, part in
            guard !attachment.isTrulyInline else { return nil }
            return AttachmentInfo(
                filename: attachment.filename ?? fallbackName(for: attachment.mimeType),
                mimeType: attachment.mimeType,
                partID: part.section.description
            )
        }
    }

    /// A message's candidate attachment parts: everything but inline body content.
    /// Excluded are the chosen body leaves, the container multiparts, and any bare
    /// text part. Files, and the inline images the cid join will then classify, are
    /// all candidates.
    static func attachmentParts(in parts: [MessagePart], excluding bodySections: [Section]) -> [MessagePart] {
        parts.filter { part in
            !bodySections.contains(part.section)
                && !part.contentType.lowercased().hasPrefix("multipart/")
                && !isBareInlineText(part)
        }
    }

    /// Whether a part is inline body text rather than an attachment: a text/plain
    /// or text/html leaf with no filename and not flagged as an attachment. These
    /// are body content even when they aren't the single part chosen for display,
    /// such as the trailing text segment a multipart/mixed wraps around a file (an
    /// "inline attachment" layout). A genuinely attached .txt or .html carries a
    /// filename or an attachment disposition, so it is not bare and stays a
    /// candidate.
    private static func isBareInlineText(_ part: MessagePart) -> Bool {
        let type = part.contentType.lowercased()
        guard type.hasPrefix("text/plain") || type.hasPrefix("text/html") else { return false }
        return part.filename == nil && part.disposition?.lowercased() != "attachment"
    }

    /// Build raw attachment inputs from a message's MIME parts for the cid join.
    static func attachmentInputs(in parts: [MessagePart], excluding bodySections: [Section]) -> [RawAttachmentInput] {
        attachmentParts(in: parts, excluding: bodySections).map(rawInput)
    }

    /// One part as a cid-join input. Size is omitted: IMAP BODYSTRUCTURE carries
    /// it but SwiftMail doesn't surface it, and the chip shows only a name.
    private static func rawInput(_ part: MessagePart) -> RawAttachmentInput {
        RawAttachmentInput(
            filename: part.filename,
            mimeType: baseMIMEType(part.contentType),
            size: nil,
            contentID: part.contentId,
            disposition: disposition(part.disposition)
        )
    }

    /// Map a Content-Disposition header value to Klartext's enum. The header is
    /// only a claim; the cid join, not this, decides whether a part is truly
    /// inline.
    static func disposition(_ raw: String?) -> Disposition {
        switch raw?.lowercased() {
        case "inline": return .inline
        case "attachment": return .attachment
        default: return .unknown
        }
    }

    /// A display name for an attachment that arrived without a filename, by type
    /// family, so a chip never reads blank.
    static func fallbackName(for mimeType: String) -> String {
        let type = mimeType.lowercased()
        if type.hasPrefix("image/") { return "Image" }
        if type == "application/pdf" { return "PDF" }
        return "Attachment"
    }

    /// The bare MIME type without parameters (e.g. `image/png` from
    /// `image/png; name=logo.png`).
    private static func baseMIMEType(_ contentType: String) -> String {
        contentType.components(separatedBy: ";").first?
            .trimmingCharacters(in: .whitespaces) ?? contentType
    }
}
