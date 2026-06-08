# Zirbe

An open-source email client for iPhone and iPad that looks and feels like a
texting app, while keeping real email underneath. Standards-only, no backend,
free.

## The name

*Zirbe* is German for the Swiss stone pine, the pine of the Alps. The name
continues a lineage of text-mode mail clients that runs **Elm → Pine → Alpine**,
and lands on another pine. The hidden meaning is the point: it reads like a
coined word and rewards anyone who looks it up.

## What it is

A conversation in Zirbe is an email **thread**, not a person. A thread is
identified by the RFC 5322 `Message-ID`, `In-Reply-To`, and `References`
headers and shown like a named group chat: the **subject is the title**, the
people on `From`/`To`/`Cc` are the members, and each message is one bubble in
time order. The same person writing five different-subject threads produces
five conversations, which is correct email behavior. Starting a new
conversation requires naming it, and that name is the subject.

## Principles

Apple Messages is the aesthetic muse, never a clone. We implement only what the
email RFCs define (5321 SMTP, 5322 message format, 2045/2046/2047 MIME) and
nothing that isn't email: no video or voice calls, no shared notes, tasks, or
team workspaces. The CheckIn privacy posture carries over wholesale: no
backend, no third-party SDKs, no telemetry. Credentials and tokens live in the
Keychain, device-bound, never synced off the device that obtained them. The
only network destinations are the user's own mail servers and identity
providers.

## Status

Early. The IMAP engine lives in `Packages/SwiftIMAP`, a standalone high-level
IMAP client built on Apple's
[`swift-nio-imap`](https://github.com/apple/swift-nio-imap) that Zirbe consumes.
It compiles and links for iOS (device and simulator) and can connect,
authenticate, select a mailbox, and fetch message envelopes. The current work
is the M1 runtime check against live accounts.

## License

MIT. See [LICENSE](LICENSE).
