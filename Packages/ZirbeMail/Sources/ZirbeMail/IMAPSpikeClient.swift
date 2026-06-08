// Author: David M. Anderson
// Built with AI assistance (Claude, Anthropic)
//
// M1 spike: prove Apple's swift-nio-imap can connect, authenticate, select a
// mailbox, and fetch message envelopes from a real IMAP server over TLS.
// This is deliberately small and read-only. It is the thing the whole plan
// gates on; once it runs on iOS the rest of ZirbeMail can be built around it.

import Logging
import NIOCore
import NIOIMAP
import NIOPosix
import NIOSSL

/// A flattened view of one message's envelope, enough to prove the fetch and
/// MIME-header decode worked and to seed the thread model later.
public struct FetchedEnvelope: Sendable {
    public var sequenceNumber: UInt32?
    public var uid: UInt32?
    public var subject: String?
    public var from: String?
    public var date: String?
    public var messageID: String?
    public var inReplyTo: String?
}

/// Bridges inbound `Response` values off the NIO event loop into an
/// `AsyncStream` the async client can iterate.
private final class ResponseCollector: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = Response

    private let continuation: AsyncStream<Response>.Continuation

    init(_ continuation: AsyncStream<Response>.Continuation) {
        self.continuation = continuation
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        continuation.yield(unwrapInboundIn(data))
    }

    func channelInactive(context: ChannelHandlerContext) {
        continuation.finish()
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        continuation.finish()
        context.fireErrorCaught(error)
    }
}

/// Serializes access to the single response stream so `send` can await the
/// responses that belong to the command it just wrote.
private actor ResponseReader {
    private var iterator: AsyncStream<Response>.AsyncIterator

    init(_ stream: AsyncStream<Response>) {
        self.iterator = stream.makeAsyncIterator()
    }

    func next() async -> Response? {
        // The stream iterator's `next()` is mutating-async, which can't be
        // called directly on an actor-stored property. Advance a local copy
        // (it shares the stream's backing storage) and store it back. The
        // actor serializes calls, so there is never concurrent advancement.
        var local = iterator
        let value = await local.next()
        iterator = local
        return value
    }
}

public enum IMAPSpikeError: Error, Sendable {
    case notConnected
    case taggedFailure(String)
    case connectionClosed
}

public final class IMAPSpikeClient {
    public struct Config: Sendable {
        public var host: String
        public var port: Int
        public var username: String
        public var password: String

        public init(host: String, port: Int = 993, username: String, password: String) {
            self.host = host
            self.port = port
            self.username = username
            self.password = password
        }
    }

    private let group: EventLoopGroup
    private let logger: Logger
    private var channel: Channel?
    private var reader: ResponseReader?
    private var tagCounter = 0

    public init(logger: Logger = Logger(label: "zirbe.imap.spike")) {
        self.group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        self.logger = logger
    }

    // MARK: - Connection

    public func connect(_ config: Config) async throws {
        let (stream, continuation) = AsyncStream<Response>.makeStream()
        let reader = ResponseReader(stream)
        self.reader = reader

        let sslContext = try NIOSSLContext(configuration: .clientDefault)
        let host = config.host

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

        logger.info("connecting to \(config.host):\(config.port)")
        self.channel = try await bootstrap.connect(host: config.host, port: config.port).get()

        // The server opens with an untagged greeting before we send anything.
        if let greeting = await reader.next() {
            logger.info("greeting: \(Self.describe(greeting))")
        }
    }

    // MARK: - Commands

    private func nextTag() -> String {
        tagCounter += 1
        return "Z\(tagCounter)"
    }

    /// Writes one tagged command and collects every response up to and
    /// including this command's tagged completion. Throws on a NO/BAD result.
    @discardableResult
    public func send(_ command: Command) async throws -> [Response] {
        guard let channel, let reader else { throw IMAPSpikeError.notConnected }

        let tag = nextTag()
        let message = IMAPClientHandler.Message.part(.tagged(.init(tag: tag, command: command)))
        try await channel.writeAndFlush(message).get()

        var collected: [Response] = []
        while let response = await reader.next() {
            collected.append(response)
            switch response {
            case .tagged(let tagged) where tagged.tag == tag:
                if case .ok = tagged.state {
                    return collected
                } else {
                    throw IMAPSpikeError.taggedFailure(Self.describe(response))
                }
            case .fatal:
                throw IMAPSpikeError.taggedFailure(Self.describe(response))
            default:
                continue
            }
        }
        throw IMAPSpikeError.connectionClosed
    }

    public func login(username: String, password: String) async throws {
        _ = try await send(.login(username: username, password: password))
        logger.info("authenticated as \(username)")
    }

    /// Selects `mailbox`, fetches the envelopes of the most recent `limit`
    /// messages, and returns them flattened.
    public func fetchRecentEnvelopes(in mailbox: String, limit: Int = 20) async throws -> [FetchedEnvelope] {
        let selectResponses = try await send(.select(MailboxName(ByteBuffer(string: mailbox)), []))

        var exists = 0
        for response in selectResponses {
            if case .untagged(let payload) = response,
               case .mailboxData(.exists(let count)) = payload {
                exists = count
            }
        }
        logger.info("selected \(mailbox): \(exists) message(s)")
        guard exists > 0 else { return [] }

        let lower = UInt32(max(1, exists - limit + 1))
        let upper = UInt32(exists)
        let range = SequenceNumber(rawValue: lower) ... SequenceNumber(rawValue: upper)
        let attributes: [FetchAttribute] = [.uid, .envelope, .flags, .internalDate]

        let responses = try await send(.fetch(.range(range), attributes, []))
        return Self.parseEnvelopes(responses)
    }

    public func logout() async {
        _ = try? await send(.logout)
        try? await channel?.close().get()
        channel = nil
    }

    public func shutdown() async {
        try? await group.shutdownGracefully()
    }

    // MARK: - Parsing

    private static func parseEnvelopes(_ responses: [Response]) -> [FetchedEnvelope] {
        var result: [FetchedEnvelope] = []
        var current = FetchedEnvelope()
        var active = false

        for response in responses {
            guard case .fetch(let fetch) = response else { continue }
            switch fetch {
            case .start(let sequence):
                if active { result.append(current) }
                current = FetchedEnvelope()
                current.sequenceNumber = sequence.rawValue
                active = true
            case .simpleAttribute(let attribute):
                apply(attribute, to: &current)
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

    private static func apply(_ attribute: MessageAttribute, to envelope: inout FetchedEnvelope) {
        switch attribute {
        case .uid(let uid):
            envelope.uid = uid.rawValue
        case .envelope(let env):
            envelope.subject = env.subject.map { String(buffer: $0) }
            envelope.from = env.from.compactMap(describeAddress).joined(separator: ", ")
            envelope.date = env.date.map { String(describing: $0) }
            envelope.messageID = env.messageID.map { String(describing: $0) }
            envelope.inReplyTo = env.inReplyTo.map { String(describing: $0) }
        default:
            break
        }
    }

    private static func describeAddress(_ element: EmailAddressListElement) -> String? {
        switch element {
        case .singleAddress(let address):
            let name = address.personName.map { String(buffer: $0) }
            let mailbox = address.mailbox.map { String(buffer: $0) } ?? ""
            let host = address.host.map { String(buffer: $0) } ?? ""
            let addr = host.isEmpty ? mailbox : "\(mailbox)@\(host)"
            if let name, !name.isEmpty { return "\(name) <\(addr)>" }
            return addr
        case .group(let group):
            return String(describing: group)
        }
    }

    private static func describe(_ response: Response) -> String {
        String(reflecting: response)
    }
}
