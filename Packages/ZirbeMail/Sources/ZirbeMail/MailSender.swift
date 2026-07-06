// Author: David M. Anderson
// Built with AI assistance (Claude, Anthropic)
//
// The send adapter. Wraps SwiftMail's SMTPServer to send one Zirbe
// OutgoingMessage. Intentionally thin: SwiftMail does the protocol work.
//
// Unlike the read engine, this does not keep a warm session. SMTP here offers no
// liveness probe and a send is not idempotent, so a held-open connection the
// server quietly dropped could neither be detected nor safely retried. Each send
// therefore connects, authenticates, sends once, and disconnects. A failure
// surfaces to the caller; a user-driven retry reuses the message's Message-ID,
// so the Sent-folder copy deduplicates rather than doubling.

import Foundation
import Logging
import SwiftMail

public actor MailSender {
    private let server: SMTPServer
    private let logger: Logger

    public init(config: MailServerConfig, logger: Logger = Logger(label: "zirbe.smtp")) {
        self.logger = logger
        self.server = SMTPServer(
            host: config.host,
            port: config.port,
            transportSecurity: Self.transportSecurity(port: config.port)
        )
    }

    /// Require TLS rather than leave it opportunistic. 465 is implicit TLS; every
    /// other submission port (587, legacy 25) upgrades via STARTTLS and we demand
    /// it — not "if available", which a network attacker can strip to plaintext
    /// and capture the login. This matters most here because SwiftMail's automatic
    /// inference sends in the clear on a non-standard SMTP port; requiring STARTTLS
    /// instead fails closed if the server can't secure the connection.
    private static func transportSecurity(port: Int) -> MailTransportSecurity {
        port == 465 ? .implicitTLS : .startTLS
    }

    /// Send one message: open an authenticated SMTP connection, send, and close
    /// it. The credentials are passed per call and not retained, mirroring the
    /// read path; they are used only for the SMTP login over TLS.
    public func send(_ outgoing: OutgoingMessage, username: String, password: String) async throws {
        try await server.connect()
        do {
            try await server.login(username: username, password: password)
            try await server.sendEmail(Email(outgoing))
        } catch {
            try? await server.disconnect()
            throw error
        }
        try? await server.disconnect()
    }
}
