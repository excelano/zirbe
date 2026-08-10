# Zirbe

An open-source email client for iPhone that looks and feels like a texting app,
while keeping real email underneath. Standards-only, no backend, free. iPad is
next.

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

Zirbe 1.0 is [on the App Store](https://apps.apple.com/app/id6778170645),
iPhone-only for now, and connects to any IMAP/SMTP account with a password or
app-specific password. It reads and sends mail, threads it into conversations,
handles attachments and inline images, and covers the surrounding surface a
daily mail app needs: folders, archive and move, drafts, junk and block-sender,
search, pinning, reactions, voice messages, and local new-mail notifications.
The full picture of what is built and what is next is in
[BACKLOG.md](BACKLOG.md).

The mail engine is [Cocoanetics/SwiftMail](https://github.com/Cocoanetics/SwiftMail),
a mature actor-based async IMAP and SMTP client, consumed through a thin adapter
in `Packages/ZirbeMail` (a `MailEngine` actor returning Zirbe-owned value types,
so the engine stays swappable). Email content parsing — HTML to text, quote
folding, signatures, inline images — comes from the shared
[Klartext](https://github.com/excelano/klartext) package.

Next up is an iPad split-view layout, then multiple accounts and an integrated
inbox, then OAuth for the providers that are retiring app passwords.

## License

MIT. See [LICENSE](LICENSE).
