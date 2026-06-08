// Example client for SwiftIMAP. macOS only; not part of any app.
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
import SwiftIMAP

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

let client = IMAPClient(logger: logger)

do {
    try await client.connect(to: IMAPServer(host: host, port: port))
    try await client.login(Credentials(username: user, password: pass))
    let status = try await client.selectMailbox(mailbox)
    let messages = try await client.fetchRecentEnvelopes(limit: limit)

    print("\n— \(messages.count) of \(status.messageCount) message(s) in \(mailbox) —\n")
    for message in messages.reversed() {
        let seq = message.sequenceNumber.map(String.init) ?? "?"
        let uid = message.uid.map(String.init) ?? "?"
        print("#\(seq)  uid:\(uid)")
        print("  subject:     \(message.subject ?? "(none)")")
        print("  from:        \(message.from.map(\.description).joined(separator: ", "))")
        print("  date:        \(message.date ?? "(none)")")
        print("  message-id:  \(message.messageID ?? "(none)")")
        if let inReplyTo = message.inReplyTo {
            print("  in-reply-to: \(inReplyTo)")
        }
        print("")
    }

    await client.disconnect()
} catch {
    FileHandle.standardError.write(Data("demo failed: \(error)\n".utf8))
    await client.disconnect()
    exit(1)
}
