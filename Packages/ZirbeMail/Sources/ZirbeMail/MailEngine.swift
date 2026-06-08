// Author: David M. Anderson
// Built with AI assistance (Claude, Anthropic)
//
// The mail engine adapter. Wraps SwiftMail's IMAPServer and returns Zirbe-owned
// MailEnvelope values. Intentionally thin: SwiftMail does the protocol work.

import Foundation
import Logging
import SwiftMail

public actor MailEngine {
    private let server: IMAPServer
    private let logger: Logger

    public init(config: MailServerConfig, logger: Logger = Logger(label: "zirbe.mail")) {
        self.logger = logger
        self.server = IMAPServer(host: config.host, port: config.port)
    }

    public func connect() async throws {
        try await server.connect()
        logger.debug("connected")
    }

    public func login(username: String, password: String) async throws {
        try await server.login(username: username, password: password)
        logger.debug("authenticated as \(username)")
    }

    /// Selects `mailbox` and returns the envelopes of the most recent `limit`
    /// messages, newest last (server order).
    public func fetchRecentEnvelopes(in mailbox: String, limit: Int = 20) async throws -> [MailEnvelope] {
        let selection = try await server.selectMailbox(mailbox)
        logger.debug("selected \(mailbox): \(selection.messageCount) message(s)")
        guard let identifiers = selection.latest(limit) else { return [] }
        let infos = try await server.fetchMessageInfosBulk(using: identifiers)
        return infos.map(MailEnvelope.init)
    }

    public func disconnect() async {
        try? await server.disconnect()
    }
}
