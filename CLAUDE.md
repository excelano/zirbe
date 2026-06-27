# CLAUDE.md — Zirbe (excelano/zirbe)

Project guidance for Zirbe. This repo is public and MIT-licensed; keep this file
to project facts. (On the maintainer's machine a home-root `~/CLAUDE.md` adds
personal working style and writing standards; it is not part of this repo.)

## What Zirbe is

An open-source iOS/iPadOS email client that looks like Messages but keeps real
email semantics: a thread is a conversation, the subject is its title, and
messages render as chat bubbles. The canonical roadmap is `BACKLOG.md` (the
"Shipped" section plus git history are the changelog). Don't restate shipped
work here.

## Tech stack

- Swift / SwiftUI, current Xcode and Swift toolchain.
- The app uses an Xcode synchronized folder: drop a new `.swift` file into
  `Zirbe/Zirbe/` and it's picked up automatically — no `.pbxproj` editing.
- Local Swift packages live under `Packages/`.

## Architecture

Three layers, each depending only on the one below:

- **App target** (`Zirbe/Zirbe/`) — SwiftUI views.
- **ZirbeCore** (`Packages/ZirbeCore/`) — the domain layer: the GRDB-backed
  `MailStore`, the `@Observable @MainActor InboxModel`, and `SyncService`. No UIKit,
  no transport. Unit-testable; run `swift test` here.
- **ZirbeMail** (`Packages/ZirbeMail/`) — a thin adapter over Cocoanetics/SwiftMail
  for IMAP/SMTP. The only place that talks to a server.

Email content parsing (HTML → text, quote folding, signatures, inline images) is
not done in this repo. It comes from the shared package `excelano/klartext`
(`Klartext` for content, `KlartextUI` for the force-light HTML view). See the
boundary rule below.

## Privacy posture (non-negotiable)

No backend, no third-party SDK, no telemetry. The only network destinations are
the user's own IMAP and SMTP servers. Credentials are device-bound in the
Keychain and never iCloud-synced. Remote images in HTML mail are blocked by
default. Bcc is transport-only (it reaches the SMTP envelope, never a stored
header). Introducing any server, analytics, external destination, or credential
sync is a hard stop — pause and confirm.

## Klartext boundary

Zirbe consumes Klartext/KlartextUI but does not own them. Never edit the Klartext
package from this repo. Request changes by opening an issue on `excelano/klartext`,
written as an API spec. Transport stays here; content parsing stays there.

## Conventions

- Swift files authored with AI assistance carry a two-line header:
  `// Author: David M. Anderson` / `// Built with AI assistance (Claude, Anthropic)`.
- Commits use the trailer `Co-Authored-By: Claude <noreply@anthropic.com>`.
- SourceKit "No such module" warnings in the editor are reindex noise; the real
  check is an `xcodebuild` of the app scheme and `swift test` in `ZirbeCore`.
