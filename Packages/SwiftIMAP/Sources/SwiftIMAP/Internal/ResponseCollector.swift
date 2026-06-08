// Bridges inbound IMAP `Response` values off the NIO event loop into an
// AsyncStream that `IMAPClient` consumes. Internal to SwiftIMAP.

import NIOCore
import NIOIMAP

final class ResponseCollector: ChannelInboundHandler, @unchecked Sendable {
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
