# Security Policy

## Reporting a vulnerability

Please report suspected vulnerabilities privately, using the **Report a vulnerability** button on the Security tab of the repository concerned. If that button is not there, or you would rather not go through GitHub, email david.anderson@excelano.com instead. I aim to respond within seven days.

Please do not open public issues for security problems.

## Supported versions

The latest release receives security fixes. Older versions are not supported.
A fix ships in a new App Store release.

## What Zirbe can access

Zirbe reads mail from the IMAP server of each account a user adds and sends mail
through that account's SMTP server. Both connections require TLS: implicit TLS
on ports 993 and 465, and STARTTLS demanded on any other port, so a connection
that cannot be secured fails instead of falling back to plain text. Server
settings for a known provider come from a table built into the app, never from
an autoconfig or SRV lookup. There is no Zirbe server, no account of its own, no
analytics, no crash reporter and no third-party SDK.

An account that signs in with Microsoft opens Microsoft's sign-in page at
`login.microsoftonline.com` in an ephemeral browser session that keeps no
cookies, and Zirbe then calls Microsoft's token endpoint there to redeem and
refresh tokens. The source also carries a Google sign-in, which is offered only
when a Google client identifier is set, and this repository leaves it empty. An
account that signs in with a password contacts no sign-in service.

Mail arrives from other people and is the input this application has to
withstand. Messages are shown as text, with HTML turned into text by the
`Klartext` package. A message's HTML is rendered only in Web View, which the
user opens per message, in a `WKWebView` with WebKit's default settings, so
script in the message is not disabled. Until the user chooses Show Images for
that message, or turns on the setting that loads remote images by default, a
content rule blocks every `http` and `https` request the page makes, and only
the images carried inside the message load. Once remote content is allowed the
page loads whatever it references from the sender's servers, which lets them see
the request. Tapping a link hands it to the system to open. A crash on a
malformed or hostile message, or anything in Web View that reaches the network
while remote content is blocked, is worth reporting.

Zirbe asks iOS for these permissions, each when a feature first needs it.
Contacts is read on the device to show sender photos and suggest recipients,
and is never written or sent anywhere. Calendar access is write-only, used to
add a meeting from an invitation through the system's event editor. The camera
takes a photo to attach, and the microphone records a voice message to attach.
Background app refresh lets iOS run a sync now and then, and new-mail
notifications are posted locally by the app.

## What Zirbe stores

Each account's app-specific password, or the access and refresh tokens a
provider issued, in the iOS Keychain under the services `com.excelano.zirbe` and
`com.excelano.zirbe.oauth`, written with
`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, so the secret neither syncs
to iCloud Keychain nor moves to another device in a backup restore.

The mail cache in `zirbe.sqlite` under the app's Application Support directory:
each account's address, display name, label, color and IMAP and SMTP settings,
its folder list, the messages it has synced with their bodies and inline
images, pinned conversations, blocked senders, and the position of the last
new-mail notification. Attachment bytes are cached in `ZirbeAttachments` under
the app's Caches directory, which iOS may purge. Removing an account deletes its
Keychain item, its rows in the database and the attachment cache; removing the
last account erases the database.

The display and notification settings and the account last viewed, in the app's
user defaults. An attachment the user opens is written to `attachments` in the
app's temporary directory for Quick Look, and a voice message is recorded into
that directory before it is attached. Web View uses WebKit's default website
data store, so anything a sender's server sets once remote content is allowed is
kept by WebKit inside the app's container. Everything above lives in the app's
own sandbox, and none of it is sent anywhere except the mail the user sends and
the changes the user makes to the mailbox on the server.
