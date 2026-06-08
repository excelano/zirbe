// Author: David M. Anderson
// Built with AI assistance (Claude, Anthropic)
//
// Command-line harness for the ZirbeMail M1 spike. macOS only; not shipped.
// Point it at a real account with app-password credentials supplied via the
// environment, never on the command line or in source:
//
//   ZIRBE_HOST=imap.fastmail.com \
//   ZIRBE_USER=you@example.com \
//   ZIRBE_PASS='app-specific-password' \
//   ZIRBE_MAILBOX=INBOX \
//   ZIRBE_LIMIT=10 \
//   swift run imap-spike
//
// iCloud:   ZIRBE_HOST=imap.mail.me.com
// Gmail:    ZIRBE_HOST=imap.gmail.com   (app password required)
// Outlook:  ZIRBE_HOST=outlook.office365.com

import Foundation
import Logging
import ZirbeMail

func env(_ key: String) -> String? {
    guard let value = ProcessInfo.processInfo.environment[key], !value.isEmpty else { return nil }
    return value
}

guard let host = env("ZIRBE_HOST"),
      let user = env("ZIRBE_USER"),
      let pass = env("ZIRBE_PASS") else {
    FileHandle.standardError.write(Data(
        "Missing required env: set ZIRBE_HOST, ZIRBE_USER, ZIRBE_PASS (see file header).\n".utf8
    ))
    exit(2)
}

let mailbox = env("ZIRBE_MAILBOX") ?? "INBOX"
let port = env("ZIRBE_PORT").flatMap(Int.init) ?? 993
let limit = env("ZIRBE_LIMIT").flatMap(Int.init) ?? 10

var logger = Logger(label: "zirbe.imap.spike")
logger.logLevel = .info

let client = IMAPSpikeClient(logger: logger)
let config = IMAPSpikeClient.Config(host: host, port: port, username: user, password: pass)

do {
    try await client.connect(config)
    try await client.login(username: user, password: pass)
    let envelopes = try await client.fetchRecentEnvelopes(in: mailbox, limit: limit)

    print("\n— \(envelopes.count) message(s) from \(mailbox) —\n")
    for envelope in envelopes.reversed() {
        let seq = envelope.sequenceNumber.map(String.init) ?? "?"
        let uid = envelope.uid.map(String.init) ?? "?"
        print("#\(seq)  uid:\(uid)")
        print("  subject: \(envelope.subject ?? "(none)")")
        print("  from:    \(envelope.from ?? "(none)")")
        print("  date:    \(envelope.date ?? "(none)")")
        print("  msg-id:  \(envelope.messageID ?? "(none)")")
        if let inReplyTo = envelope.inReplyTo {
            print("  in-reply-to: \(inReplyTo)")
        }
        print("")
    }

    await client.logout()
    await client.shutdown()
} catch {
    FileHandle.standardError.write(Data("spike failed: \(error)\n".utf8))
    await client.shutdown()
    exit(1)
}
