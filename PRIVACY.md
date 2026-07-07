# Zirbe: Privacy Statement

Zirbe is an open-source iOS and iPadOS email client. It connects only to your own
mail servers, keeps everything it holds on your device, and sends nothing about
you anywhere. This document is the canonical statement of what Zirbe does and does
not do with your data. The app is open source so that every claim here is
independently verifiable, and the claims are enforced by how the code is built,
not by a policy that depends on the developer behaving well.

## The short version

Zirbe talks to two things and two things only: the IMAP server and the SMTP server
you sign in to. There is no Zirbe server, no account to create with us, no
analytics, no telemetry, and no third-party SDK. Your mail and your credentials
stay on your device. When Zirbe ships to the App Store its App Privacy declaration
is "Data Not Collected," because the developer collects nothing.

## What stays on your device

Unlike a summary tool that reads and forgets, an email client has to remember. So
that your inbox opens instantly, works on a train with no signal, and does not
re-download the same messages every time, Zirbe keeps a local copy of the mail it
has synced. That copy lives in a private SQLite database inside the app's own
container on your device, readable only by Zirbe. It holds your messages and their
threading, the folders you have opened, cached message bodies and downsampled image
thumbnails, and small pieces of local-only state you create in the app, such as
which conversations you have pinned and which senders you have blocked. This is an
on-device cache of your own mailbox. It is never uploaded, never backed up to any
Zirbe service, and never shared with anyone. Signing out erases it: the app tears
the database down and rebuilds it empty.

Your sign-in credentials are held separately in the iOS Keychain, device-bound. The
email address and the app-specific password you enter are stored there so Zirbe can
reconnect, and nowhere else. They are never written to the message database, never
copied to another device, and never synced through iCloud Keychain. A credential
obtained on one device stays on that device.

## What leaves your device

**Your IMAP and SMTP servers.** When Zirbe syncs, it makes an encrypted connection
to the IMAP host you configured and fetches the mail your account already holds.
When you send, reply, save a draft, move a message, or set a flag, it makes the
corresponding request to your IMAP or SMTP host. These connections carry the
credentials you entered, which your mail provider uses to identify you, exactly as
any standards-based mail client does. Zirbe adds no headers, identifiers, or
analytics to that traffic. It requires transport encryption: TLS is implicit on the
standard secure ports and demanded via STARTTLS otherwise, and a connection that
cannot be secured fails rather than falling back to plaintext.

**Nothing else.** Zirbe makes no other network request. There is no analytics
service, no crash reporter, no telemetry, no usage logging that leaves the device,
and no third-party SDK that would do any of those things. The project imports none
of that on purpose. Remote images in HTML mail are blocked by default, so simply
opening a message does not reach out to a sender's web server or load a tracking
pixel; images load only when you choose to load them.

## Writes to your mailbox

Zirbe writes to your mailbox only in response to something you do. You can send and
reply, save and discard drafts, mark messages read or unread, flag them, move them
between folders, archive them, delete them, move mail to Junk, and block a sender.
Each write is the direct result of a tap, a swipe, or a send, carried over the same
authenticated connection to your own server. Zirbe performs no writes on its own.

Two features are worth naming explicitly because they touch the wire in a specific
way. Blind carbon copy is transport-only: a Bcc recipient reaches the SMTP envelope
so the message is delivered to them, but it is never written into a stored header,
so the copy stays blind. Reactions (the tapback badges) are sent as ordinary email
over your own SMTP: a reaction is a small reply carrying a Zirbe header, so another
Zirbe user sees the badge while every other mail client sees a plain readable line.
There is no separate reaction channel and no server brokering it.

## Contacts

If you grant Contacts access, Zirbe uses it locally and for display only: to show a
sender's photo as an avatar, and to suggest matching people as you type a recipient.
The lookup happens entirely on your device, the address book is never transmitted,
and denying access simply means no avatars and no suggestions. You can still type any
address by hand.

## Notifications

New-mail notifications are generated on your device. When the background refresh that
iOS occasionally grants finds new mail, Zirbe itself posts the local notification.
There is no push server, which is also why notifications arrive on the cadence iOS
allows a background app rather than the instant a message lands; the app's Settings
disclose that plainly. No notification content leaves your device.

## What Zirbe does not collect

Zirbe does not collect the contents of your mail, your search queries, your usage,
screen views, taps, feature counts, crash reports, performance metrics, diagnostic
logs, device identifiers, advertising identifiers, installation identifiers, or
anything else. It has no way to, because it has nowhere to send them. This document
and the open-source repository are the substance behind the "Data Not Collected"
label.

## One thing outside the app's control

Apple aggregates anonymous crash logs at the iOS level from devices that have **Share
With App Developers** turned on, and surfaces those aggregates to developers in App
Store Connect. Zirbe neither collects this data nor contains any code that touches
it, but Apple may still surface aggregate, anonymized crash signatures to the
developer account regardless of what the app does. If you would rather no anonymous
crash data from your device reach any developer, including this one, the control is
at **Settings > Privacy & Security > Analytics & Improvements > Share With App
Developers**. Turning it off applies to every app on your phone.

## How to verify the claims yourself

The full source is at [github.com/excelano/zirbe](https://github.com/excelano/zirbe).
To check the claims here independently:

1. Search the project for the code that opens network connections. Every server
   connection targets the IMAP and SMTP hosts the user configured; the app defines
   no other destination.
2. Search for analytics and crash-reporter SDK names: Firebase, Sentry, Crashlytics,
   Mixpanel, Amplitude, Segment, GoogleAnalytics. None appear. The package manifests
   list only the mail engine (SwiftMail), the local database (GRDB), and the content
   parser (Klartext), none of which phone home.
3. Confirm there is no server component anywhere in the repository. There is nothing
   to self-host because Zirbe has no backend by design: your mail provider is the
   only server involved, and it is one you already chose.

## Updates to this document

This document changes as the design changes. The change history is the git log of
`PRIVACY.md`. A substantive change to the privacy posture (a new data flow, a new
dependency that touches data) requires a corresponding update here in the same
commit.
