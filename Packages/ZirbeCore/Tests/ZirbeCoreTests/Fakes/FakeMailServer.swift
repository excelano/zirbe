// Author: David M. Anderson
// Built with AI assistance (Claude, Anthropic)
//
// An in-memory IMAP server for tests: mailboxes as UID maps with a UIDVALIDITY
// each, the operations SyncService performs applied to them the way a real
// server would (a move takes the message out of one folder and gives it a fresh
// UID in another; a seen flag lands on the envelope), and a log of every call so
// a test can assert what reached the server and in what order. Any operation can
// be told to fail, once or until told otherwise, to drive the error paths.

import Foundation
import ZirbeMail

actor FakeMailServer: IMAPTransport {
    /// One server folder. `messages` is keyed by UID; UIDs are issued by
    /// `nextUID` and never reused, matching IMAP's rule.
    struct Folder {
        var info: MailboxInfo
        var uidValidity: UInt32
        var nextUID: UInt32 = 1
        var messages: [UInt32: MailEnvelope] = [:]
        var bodies: [UInt32: MessageBody] = [:]
        var htmlBodies: [UInt32: HTMLBody] = [:]
        /// Attachment bytes keyed by "uid/partID".
        var attachments: [String: Data] = [:]
    }

    /// The operations a test can fail, and the log records.
    enum Operation: Hashable {
        case connect, fetchRecentEnvelopes, mailboxState, listMailboxes, fetchTextBodies
        case fetchHTMLBody, fetchAttachment, saveToSent, saveToDrafts, removeDraft
        case setSeen, setFlagged, idleChanges, trash, move, archive, markJunk
    }

    /// A call as the server saw it, for order and argument assertions.
    enum Call: Equatable {
        case connect(username: String)
        case fetchRecentEnvelopes(mailbox: String, limit: Int)
        case mailboxState(mailbox: String)
        case listMailboxes
        case fetchTextBodies(mailbox: String, uids: [UInt32])
        case fetchHTMLBody(mailbox: String, uid: UInt32)
        case fetchAttachment(mailbox: String, uid: UInt32, partID: String)
        case saveToSent(messageID: String)
        case saveToDrafts(messageID: String, replacing: UInt32?)
        case removeDraft(uid: UInt32)
        case setSeen(Bool, mailbox: String, uids: [UInt32])
        case setFlagged(Bool, mailbox: String, uids: [UInt32])
        case idleChanges(mailbox: String)
        case stopIdle
        case trash(mailbox: String, uids: [UInt32])
        case move(mailbox: String, uids: [UInt32], to: String)
        case archive(mailbox: String, uids: [UInt32])
        case markJunk(mailbox: String, uids: [UInt32])
        case disconnect
    }

    /// The error a scripted failure throws, naming the operation so a test can
    /// tell a scripted failure from a real bug in the fake.
    struct ScriptedFailure: Error, Equatable {
        let operation: Operation
    }

    private(set) var folders: [String: Folder] = [:]
    private(set) var calls: [Call] = []
    /// The credentials of the current session; nil when disconnected.
    private(set) var session: (username: String, password: String)?
    /// Every message appended by `saveToSent`, in order.
    private(set) var sentCopies: [OutgoingMessage] = []

    private var failOnce: Set<Operation> = []
    private var failAlways: Set<Operation> = []
    private var idle: AsyncStream<Void>.Continuation?

    /// A server with the standard special-use folders present and empty. The
    /// UIDVALIDITY seeds differ per folder so a test can't confuse them.
    init() {
        var validity: UInt32 = 1000
        for (name, use) in [("INBOX", MailboxSpecialUse.inbox), ("Sent", .sent), ("Drafts", .drafts),
                            ("Trash", .trash), ("Archive", .archive), ("Junk", .junk)] {
            folders[name] = Folder(info: MailboxInfo(name: name, specialUse: use), uidValidity: validity)
            validity += 1
        }
    }

    // MARK: Scripting

    /// Make the next call to `operation` throw, then behave normally.
    func failNext(_ operation: Operation) { failOnce.insert(operation) }

    /// Make every call to `operation` throw until `succeed` is called.
    func fail(_ operation: Operation) { failAlways.insert(operation) }

    /// Clear a standing failure.
    func succeed(_ operation: Operation) { failAlways.remove(operation) }

    /// Add a message to a folder and return its UID. A folder unknown to the
    /// server is created as a plain user folder.
    @discardableResult
    func add(_ envelope: MailEnvelope, to mailbox: String = "INBOX", body: MessageBody? = nil, html: HTMLBody? = nil) -> UInt32 {
        ensureFolder(mailbox)
        var folder = folders[mailbox]!
        let uid = folder.nextUID
        folder.nextUID += 1
        var stored = envelope
        stored.uid = uid
        stored.sequenceNumber = UInt32(folder.messages.count + 1)
        folder.messages[uid] = stored
        if let body { folder.bodies[uid] = body }
        if let html { folder.htmlBodies[uid] = html }
        folders[mailbox] = folder
        return uid
    }

    /// Store attachment bytes a later `fetchAttachment` returns.
    func addAttachment(_ data: Data, to mailbox: String, uid: UInt32, partID: String) {
        folders[mailbox]?.attachments["\(uid)/\(partID)"] = data
    }

    /// Remove a message the way another client's delete would: it vanishes from
    /// the folder and the next sync's state no longer lists it.
    func delete(uid: UInt32, from mailbox: String = "INBOX") {
        folders[mailbox]?.messages[uid] = nil
    }

    /// Renumber a folder: a new UIDVALIDITY, and every message reissued from
    /// UID 1, the way a server rebuild or migration invalidates a client's cache.
    func renumber(_ mailbox: String = "INBOX") {
        guard var folder = folders[mailbox] else { return }
        let ordered = folder.messages.keys.sorted().compactMap { folder.messages[$0] }
        folder.uidValidity += 1
        folder.messages = [:]
        folder.nextUID = 1
        folders[mailbox] = folder
        for envelope in ordered { add(envelope, to: mailbox) }
    }

    /// Fire one IDLE change notification, if a watch is running.
    func tick() { idle?.yield() }

    var isWatching: Bool { idle != nil }

    /// The UIDs a folder holds, ascending.
    func uids(in mailbox: String) -> [UInt32] {
        folders[mailbox].map { Array($0.messages.keys).sorted() } ?? []
    }

    /// The envelopes a folder holds, in UID order.
    func messages(in mailbox: String) -> [MailEnvelope] {
        uids(in: mailbox).compactMap { folders[mailbox]?.messages[$0] }
    }

    /// The calls of one kind, in order.
    func calls(_ operation: Operation) -> [Call] {
        calls.filter { $0.operation == operation }
    }

    // MARK: IMAPTransport

    func connect(username: String, password: String) async throws {
        calls.append(.connect(username: username))
        try check(.connect)
        session = (username, password)
    }

    func fetchRecentEnvelopes(in mailbox: String, limit: Int) async throws -> [MailEnvelope] {
        calls.append(.fetchRecentEnvelopes(mailbox: mailbox, limit: limit))
        try check(.fetchRecentEnvelopes)
        return Array(messages(in: mailbox).suffix(limit))
    }

    func mailboxState(in mailbox: String) async throws -> MailboxState {
        calls.append(.mailboxState(mailbox: mailbox))
        try check(.mailboxState)
        let folder = try folder(mailbox)
        return MailboxState(uidValidity: folder.uidValidity, uids: Set(folder.messages.keys))
    }

    func listMailboxes() async throws -> [MailboxInfo] {
        calls.append(.listMailboxes)
        try check(.listMailboxes)
        return folders.keys.sorted().map { folders[$0]!.info }
    }

    func fetchTextBodies(in mailbox: String, messages: [(id: String, uid: UInt32)]) async throws -> [String: MessageBody] {
        calls.append(.fetchTextBodies(mailbox: mailbox, uids: messages.map(\.uid)))
        try check(.fetchTextBodies)
        let folder = try folder(mailbox)
        var result: [String: MessageBody] = [:]
        for (id, uid) in messages {
            if let body = folder.bodies[uid] { result[id] = body }
        }
        return result
    }

    func fetchHTMLBody(in mailbox: String, uid: UInt32) async throws -> HTMLBody? {
        calls.append(.fetchHTMLBody(mailbox: mailbox, uid: uid))
        try check(.fetchHTMLBody)
        return try folder(mailbox).htmlBodies[uid]
    }

    func fetchAttachment(in mailbox: String, uid: UInt32, partID: String) async throws -> Data {
        calls.append(.fetchAttachment(mailbox: mailbox, uid: uid, partID: partID))
        try check(.fetchAttachment)
        guard let data = try folder(mailbox).attachments["\(uid)/\(partID)"] else {
            throw MailEngineError.partNotFound
        }
        return data
    }

    func saveToSent(_ outgoing: OutgoingMessage) async throws {
        calls.append(.saveToSent(messageID: outgoing.messageID))
        try check(.saveToSent)
        sentCopies.append(outgoing)
        add(envelope(for: outgoing), to: folderName(for: .sent))
    }

    func saveToDrafts(_ outgoing: OutgoingMessage, replacing previousUID: UInt32?) async throws -> UInt32? {
        calls.append(.saveToDrafts(messageID: outgoing.messageID, replacing: previousUID))
        try check(.saveToDrafts)
        let drafts = folderName(for: .drafts)
        if let previousUID { folders[drafts]?.messages[previousUID] = nil }
        return add(envelope(for: outgoing), to: drafts)
    }

    func removeDraft(uid: UInt32) async throws {
        calls.append(.removeDraft(uid: uid))
        try check(.removeDraft)
        folders[folderName(for: .drafts)]?.messages[uid] = nil
    }

    func setSeen(_ seen: Bool, in mailbox: String, uids: [UInt32]) async throws {
        calls.append(.setSeen(seen, mailbox: mailbox, uids: uids))
        try check(.setSeen)
        try setFlag("\\Seen", seen, in: mailbox, uids: uids)
    }

    func setFlagged(_ flagged: Bool, in mailbox: String, uids: [UInt32]) async throws {
        calls.append(.setFlagged(flagged, mailbox: mailbox, uids: uids))
        try check(.setFlagged)
        try setFlag("\\Flagged", flagged, in: mailbox, uids: uids)
    }

    func idleChanges(in mailbox: String) async throws -> AsyncStream<Void> {
        calls.append(.idleChanges(mailbox: mailbox))
        try check(.idleChanges)
        idle?.finish()
        let (stream, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        idle = continuation
        return stream
    }

    func stopIdle() async {
        calls.append(.stopIdle)
        idle?.finish()
        idle = nil
    }

    func trash(in mailbox: String, uids: [UInt32]) async throws {
        calls.append(.trash(mailbox: mailbox, uids: uids))
        try check(.trash)
        try relocate(uids, from: mailbox, to: folderName(for: .trash))
    }

    func move(in mailbox: String, uids: [UInt32], to destination: String) async throws {
        calls.append(.move(mailbox: mailbox, uids: uids, to: destination))
        try check(.move)
        try relocate(uids, from: mailbox, to: destination)
    }

    func archive(in mailbox: String, uids: [UInt32]) async throws {
        calls.append(.archive(mailbox: mailbox, uids: uids))
        try check(.archive)
        try relocate(uids, from: mailbox, to: folderName(for: .archive))
    }

    func markJunk(in mailbox: String, uids: [UInt32]) async throws {
        calls.append(.markJunk(mailbox: mailbox, uids: uids))
        try check(.markJunk)
        try relocate(uids, from: mailbox, to: folderName(for: .junk))
    }

    func disconnect() async {
        calls.append(.disconnect)
        idle?.finish()
        idle = nil
        session = nil
    }

    // MARK: Internals

    private func check(_ operation: Operation) throws {
        if failOnce.remove(operation) != nil || failAlways.contains(operation) {
            throw ScriptedFailure(operation: operation)
        }
        guard operation == .connect || session != nil else { throw MailEngineError.notConnected }
    }

    private func folder(_ name: String) throws -> Folder {
        guard let folder = folders[name] else { throw FakeServerError.noSuchMailbox(name) }
        return folder
    }

    private func ensureFolder(_ name: String) {
        if folders[name] == nil {
            folders[name] = Folder(info: MailboxInfo(name: name), uidValidity: UInt32(2000 + folders.count))
        }
    }

    /// The folder carrying a special-use role, the way the engine resolves Sent
    /// and the others by attribute rather than by name.
    private func folderName(for use: MailboxSpecialUse) -> String {
        folders.values.first { $0.info.specialUse == use }?.info.name ?? use.rawValue.capitalized
    }

    private func setFlag(_ flag: String, _ on: Bool, in mailbox: String, uids: [UInt32]) throws {
        var folder = try folder(mailbox)
        for uid in uids {
            guard var envelope = folder.messages[uid] else { continue }
            envelope.flags.removeAll { $0 == flag }
            if on { envelope.flags.append(flag) }
            folder.messages[uid] = envelope
        }
        folders[mailbox] = folder
    }

    /// Move messages between folders: gone from the source, reissued a UID in
    /// the destination, as a server MOVE does.
    private func relocate(_ uids: [UInt32], from mailbox: String, to destination: String) throws {
        var source = try folder(mailbox)
        var moved: [(MailEnvelope, MessageBody?, HTMLBody?)] = []
        for uid in uids {
            guard let envelope = source.messages.removeValue(forKey: uid) else { continue }
            moved.append((envelope, source.bodies.removeValue(forKey: uid), source.htmlBodies.removeValue(forKey: uid)))
        }
        folders[mailbox] = source
        for (envelope, body, html) in moved {
            add(envelope, to: destination, body: body, html: html)
        }
    }

    /// The envelope a server would show for an appended message.
    private func envelope(for outgoing: OutgoingMessage) -> MailEnvelope {
        MailEnvelope(
            subject: outgoing.subject,
            from: outgoing.from.address,
            to: outgoing.to.map(\.address),
            cc: outgoing.cc.map(\.address),
            date: Date(),
            messageID: outgoing.messageID,
            inReplyTo: outgoing.inReplyTo,
            references: outgoing.references,
            flags: ["\\Seen"]
        )
    }

    enum FakeServerError: Error, Equatable {
        case noSuchMailbox(String)
    }
}

extension FakeMailServer.Call {
    /// The operation a logged call belongs to, for filtering the log.
    var operation: FakeMailServer.Operation? {
        switch self {
        case .connect: .connect
        case .fetchRecentEnvelopes: .fetchRecentEnvelopes
        case .mailboxState: .mailboxState
        case .listMailboxes: .listMailboxes
        case .fetchTextBodies: .fetchTextBodies
        case .fetchHTMLBody: .fetchHTMLBody
        case .fetchAttachment: .fetchAttachment
        case .saveToSent: .saveToSent
        case .saveToDrafts: .saveToDrafts
        case .removeDraft: .removeDraft
        case .setSeen: .setSeen
        case .setFlagged: .setFlagged
        case .idleChanges: .idleChanges
        case .trash: .trash
        case .move: .move
        case .archive: .archive
        case .markJunk: .markJunk
        case .stopIdle, .disconnect: nil
        }
    }
}
