// Author: David M. Anderson
// Built with AI assistance (Claude, Anthropic)
//
// End-to-end demo for the M2 store pipeline: fetch a real INBOX through
// ZirbeMail, persist it in an in-memory ZirbeCore store, and print the
// conversations the store produces. macOS only; not part of any app.
//
// Run with credentials in the environment, never on the command line:
//   cd Packages/ZirbeCore   # from the repo root
//   IMAP_HOST=imap.mail.me.com IMAP_USER=you@icloud.com IMAP_PASS='app-pw' swift run sync-demo
// Optional: IMAP_MAILBOX (default INBOX), IMAP_LIMIT (default 50), SMTP_HOST.

import Foundation
import ZirbeCore

func env(_ key: String) -> String? { ProcessInfo.processInfo.environment[key] }

guard let host = env("IMAP_HOST"), let user = env("IMAP_USER"), let pass = env("IMAP_PASS") else {
    FileHandle.standardError.write(Data(
        "Set IMAP_HOST, IMAP_USER, and IMAP_PASS (optional: IMAP_MAILBOX, IMAP_LIMIT, SMTP_HOST).\n".utf8
    ))
    exit(2)
}

let mailbox = env("IMAP_MAILBOX") ?? "INBOX"
let limit = env("IMAP_LIMIT").flatMap(Int.init) ?? 50

let account = Account(
    emailAddress: user,
    imapHost: host,
    smtpHost: env("SMTP_HOST") ?? host,
    username: user
)

let store = try MailStore()
let sync = SyncService(account: account, store: store)
let summaries = try await sync.syncInbox(password: pass, mailbox: mailbox, limit: limit)

let formatter = DateFormatter()
formatter.dateFormat = "yyyy-MM-dd HH:mm"

print("\(summaries.count) conversation(s) in \(mailbox), most recent first:\n")
for summary in summaries {
    let unread = summary.isUnread ? "●" : " "
    let when = summary.lastActivity.map(formatter.string(from:)) ?? "—"
    let who = summary.participants.prefix(3).map(\.label).joined(separator: ", ")
    let title = summary.subject.isEmpty ? "(no subject)" : summary.subject
    print("\(unread) [\(summary.messageCount)] \(title)")
    print("    \(who)  ·  \(when)")
}
