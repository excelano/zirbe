// Example client for the ZirbeMail adapter. macOS only; not part of any app.
//
// Point it at a real account with credentials from the environment, never on
// the command line or in source:
//
//   IMAP_HOST=imap.fastmail.com \
//   IMAP_USER=you@example.com \
//   IMAP_PASS='app-specific-password' \
//   IMAP_MAILBOX=INBOX \
//   IMAP_LIMIT=10 \
//   swift run imap-demo
//
// Presets: iCloud imap.mail.me.com · Gmail imap.gmail.com (app password) ·
// Outlook outlook.office365.com · Yahoo imap.mail.yahoo.com (app password)

import Foundation
import Logging
import ZirbeMail

func env(_ key: String) -> String? {
    guard let value = ProcessInfo.processInfo.environment[key], !value.isEmpty else { return nil }
    return value
}

guard let host = env("IMAP_HOST"),
      let user = env("IMAP_USER"),
      let pass = env("IMAP_PASS") else {
    FileHandle.standardError.write(Data(
        "Missing required env: set IMAP_HOST, IMAP_USER, IMAP_PASS (see file header).\n".utf8
    ))
    exit(2)
}

let mailbox = env("IMAP_MAILBOX") ?? "INBOX"
let port = env("IMAP_PORT").flatMap(Int.init) ?? 993
let limit = env("IMAP_LIMIT").flatMap(Int.init) ?? 10

var logger = Logger(label: "imap-demo")
logger.logLevel = .info

let engine = MailEngine(config: MailServerConfig(host: host, port: port), logger: logger)

do {
    try await engine.connect()
    try await engine.login(username: user, password: pass)
    let envelopes = try await engine.fetchRecentEnvelopes(in: mailbox, limit: limit)

    print("\n— \(envelopes.count) message(s) from \(mailbox) —\n")
    for envelope in envelopes.reversed() {
        let seq = envelope.sequenceNumber.map(String.init) ?? "?"
        let uid = envelope.uid.map(String.init) ?? "?"
        print("#\(seq)  uid:\(uid)")
        print("  subject:     \(envelope.subject ?? "(none)")")
        print("  from:        \(envelope.from ?? "(none)")")
        print("  date:        \(envelope.date.map { ISO8601DateFormatter().string(from: $0) } ?? "(none)")")
        print("  message-id:  \(envelope.messageID ?? "(none)")")
        if let inReplyTo = envelope.inReplyTo {
            print("  in-reply-to: \(inReplyTo)")
        }
        if !envelope.references.isEmpty {
            print("  references:  \(envelope.references.count) (\(envelope.references.last ?? ""))")
        }
        print("")
    }

    await engine.disconnect()
} catch {
    FileHandle.standardError.write(Data("demo failed: \(error)\n".utf8))
    await engine.disconnect()
    exit(1)
}
