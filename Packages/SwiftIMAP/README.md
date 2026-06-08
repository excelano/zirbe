# SwiftIMAP

A small, high-level async IMAP client for Swift, built on Apple's
[`swift-nio-imap`](https://github.com/apple/swift-nio-imap).

`swift-nio-imap` is a low-level codec: it parses and serializes the IMAP wire
protocol and gives you a NIO channel handler, but you still have to drive the
client conversation yourself. SwiftIMAP is that driver. It wraps the codec in an
`async`/`await` API and clean value types so callers never touch NIO or the
codec's internal grammar.

```swift
import SwiftIMAP

let client = IMAPClient()
try await client.connect(to: IMAPServer(host: "imap.fastmail.com"))
try await client.login(Credentials(username: "you@example.com", password: appPassword))

let status = try await client.selectMailbox("INBOX")
let messages = try await client.fetchRecentEnvelopes(limit: 20)

for message in messages {
    print(message.subject ?? "(no subject)", "—", message.from.first?.description ?? "")
}

await client.disconnect()
```

## Scope

Connect over TLS, authenticate with a username and password (or app-specific
password), select a mailbox, and fetch message envelopes (subject, addresses,
date, and the `Message-ID` / `In-Reply-To` threading headers). It is read-only
and deliberately thin. SMTP, OAuth bearer tokens (XOAUTH2), mailbox listing,
body fetching, and IDLE are natural extensions that fit the same shape but are
not here yet.

## Design

The public surface is value types only: `IMAPServer`, `Credentials`, `Mailbox`,
`MailboxStatus`, `Address`, and `MessageEnvelope`. The codec's types stay
internal, so a consumer's code does not depend on `swift-nio-imap` and the two
can version independently.

`IMAPClient` is an actor. Issue one command at a time and `await` it before the
next; the client drains each command's responses before returning.

## Origin

Extracted from [Zirbe](https://github.com/excelano/zirbe), an email client, so
that the IMAP client could stand on its own. MIT licensed.
