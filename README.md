# Zirbe

An open-source email client for iPhone and iPad that looks and feels like a
texting app, while keeping real email underneath. Standards-only, no backend,
free. On iPad the conversation list sits beside the open conversation. Its Linux
desktop port is [zirbe-desktop](https://github.com/excelano/zirbe-desktop).

https://excelano.com/zirbe/ is the product page for every platform.

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

Apple Messages is the aesthetic muse, never a clone. I implement only what the
email RFCs define (5321 SMTP, 5322 message format, 2045/2046/2047 MIME) and
nothing that isn't email: no video or voice calls, no shared notes, tasks, or
team workspaces. There is no backend, no third-party SDK and no
telemetry. Credentials and tokens live in the Keychain, device-bound, never
synced off the device that obtained them. The only network destinations are the
user's own IMAP and SMTP servers and, for a Microsoft account, Microsoft's sign-in
service. [PRIVACY.md](PRIVACY.md) states this in full.

## How it is built

The mail engine is [Cocoanetics/SwiftMail](https://github.com/Cocoanetics/SwiftMail),
a mature actor-based async IMAP and SMTP client, consumed through a thin adapter
in `Packages/ZirbeMail` (a `MailEngine` actor returning Zirbe-owned value types,
so the engine stays swappable). Email content parsing — HTML to text, quote
folding, signatures, inline images — comes from the shared
[Klartext](https://github.com/excelano/klartext) package.

## Building and testing

Open `Zirbe/Zirbe.xcodeproj` in Xcode to build and run the app. The domain and
mail layers are Swift packages under `Packages/`, each with its own test suite.
One script runs everything: both suites with line coverage, then a simulator
build of the app.

    scripts/check.sh             # tests, coverage, and the app build
    scripts/check.sh --skip-app  # tests and coverage only
    scripts/check.sh --files     # also list per-file coverage

ZirbeCore's tests drive the sync and send paths against an in-memory IMAP
server and SMTP sender, so no account or network is needed.

## License

MIT. See [LICENSE](LICENSE).
