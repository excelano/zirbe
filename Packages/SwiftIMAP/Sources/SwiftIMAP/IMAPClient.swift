// A high-level async IMAP client over swift-nio-imap. Connect, authenticate,
// select a mailbox, and fetch message envelopes. Read-only and deliberately
// thin; SMTP, OAuth, mailbox listing, and bodies are future extensions.

import Logging
import NIOCore
import NIOIMAP
import NIOPosix
import NIOSSL

public actor IMAPClient {
    public enum Failure: Error, Sendable {
        /// A command was issued before `connect`/`login`, or after disconnect.
        case notConnected
        /// The server returned NO/BAD for a command.
        case commandRejected(String)
        /// The connection closed before the command completed.
        case connectionClosed
    }

    private let logger: Logger
    private let group: EventLoopGroup
    private let ownsGroup: Bool

    private var channel: Channel?
    private var iterator: AsyncStream<Response>.AsyncIterator?
    private var status: MailboxStatus?
    private var tagNumber = 0

    /// - Parameter eventLoopGroup: Supply one to share with other NIO work;
    ///   otherwise the client owns a single-threaded group and shuts it down on
    ///   `disconnect()`.
    public init(logger: Logger = Logger(label: "swift-imap"), eventLoopGroup: EventLoopGroup? = nil) {
        self.logger = logger
        if let eventLoopGroup {
            self.group = eventLoopGroup
            self.ownsGroup = false
        } else {
            self.group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
            self.ownsGroup = true
        }
    }

    // MARK: - Lifecycle

    public func connect(to server: IMAPServer) async throws {
        let (stream, continuation) = AsyncStream<Response>.makeStream()
        let host = server.host
        let sslContext = try NIOSSLContext(configuration: .clientDefault)

        let bootstrap = ClientBootstrap(group: group)
            .channelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    let tls = try NIOSSLClientHandler(context: sslContext, serverHostname: host)
                    try channel.pipeline.syncOperations.addHandlers([
                        tls,
                        IMAPClientHandler(),
                        ResponseCollector(continuation),
                    ])
                }
            }

        let channel = try await bootstrap.connect(host: server.host, port: server.port).get()
        self.channel = channel
        self.iterator = stream.makeAsyncIterator()

        // The server opens with an untagged greeting before we send anything.
        _ = await nextResponse()
        logger.debug("connected to \(server.host):\(server.port)")
    }

    public func login(_ credentials: Credentials) async throws {
        _ = try await send(.login(username: credentials.username, password: credentials.password))
        logger.debug("authenticated as \(credentials.username)")
    }

    public func logout() async {
        _ = try? await send(.logout)
    }

    /// Logs out, closes the connection, and (if the client owns its event-loop
    /// group) shuts the group down.
    public func disconnect() async {
        await logout()
        try? await channel?.close().get()
        channel = nil
        iterator = nil
        status = nil
        if ownsGroup {
            try? await group.shutdownGracefully()
        }
    }

    // MARK: - Mailboxes

    @discardableResult
    public func selectMailbox(_ name: String) async throws -> MailboxStatus {
        let responses = try await send(.select(MailboxName(ByteBuffer(string: name)), []))
        var status = MailboxStatus(name: name)
        for response in responses {
            guard case .untagged(let payload) = response,
                  case .mailboxData(let data) = payload else { continue }
            switch data {
            case .exists(let count): status.messageCount = count
            case .recent(let count): status.recentCount = count
            default: break
            }
        }
        self.status = status
        logger.debug("selected \(name): \(status.messageCount) message(s)")
        return status
    }

    // MARK: - Fetching

    public func fetchEnvelopes(_ range: MessageRange) async throws -> [MessageEnvelope] {
        let sequence = SequenceNumber(rawValue: range.lowerBound) ... SequenceNumber(rawValue: range.upperBound)
        let attributes: [FetchAttribute] = [.uid, .envelope, .flags, .internalDate]
        let responses = try await send(.fetch(.range(sequence), attributes, []))
        return Self.parseEnvelopes(responses)
    }

    /// Fetches the envelopes of the most recent `limit` messages in the
    /// currently selected mailbox.
    public func fetchRecentEnvelopes(limit: Int = 20) async throws -> [MessageEnvelope] {
        guard let status else { throw Failure.notConnected }
        guard status.messageCount > 0 else { return [] }
        let upper = UInt32(status.messageCount)
        let lower = UInt32(max(1, status.messageCount - limit + 1))
        return try await fetchEnvelopes(MessageRange(lower, through: upper))
    }

    // MARK: - Command plumbing

    /// Writes one tagged command and collects every response up to and
    /// including its tagged completion. Throws on a NO/BAD result. Internal:
    /// it traffics in codec types that the public API hides.
    @discardableResult
    private func send(_ command: Command) async throws -> [Response] {
        guard let channel, iterator != nil else { throw Failure.notConnected }

        tagNumber += 1
        let tag = "A\(tagNumber)"
        let message = IMAPClientHandler.Message.part(.tagged(.init(tag: tag, command: command)))
        try await channel.writeAndFlush(message).get()

        var collected: [Response] = []
        while let response = await nextResponse() {
            collected.append(response)
            switch response {
            case .tagged(let tagged) where tagged.tag == tag:
                guard case .ok = tagged.state else {
                    throw Failure.commandRejected(String(reflecting: tagged.state))
                }
                return collected
            case .fatal(let text):
                throw Failure.commandRejected(String(reflecting: text))
            default:
                continue
            }
        }
        throw Failure.connectionClosed
    }

    private func nextResponse() async -> Response? {
        // The stream iterator's `next()` is mutating-async and can't be called
        // on an actor-stored property directly. Advance a local copy (it shares
        // the stream's backing storage) and store it back. Commands run one at
        // a time, so there is no concurrent advancement.
        guard var local = iterator else { return nil }
        let value = await local.next()
        iterator = local
        return value
    }

    private static func parseEnvelopes(_ responses: [Response]) -> [MessageEnvelope] {
        var result: [MessageEnvelope] = []
        var current = MessageEnvelope()
        var active = false

        for response in responses {
            guard case .fetch(let fetch) = response else { continue }
            switch fetch {
            case .start(let sequence):
                if active { result.append(current) }
                current = MessageEnvelope()
                current.sequenceNumber = sequence.rawValue
                active = true
            case .simpleAttribute(let attribute):
                current.apply(attribute)
            case .finish:
                if active {
                    result.append(current)
                    active = false
                }
            default:
                continue
            }
        }
        if active { result.append(current) }
        return result
    }
}
