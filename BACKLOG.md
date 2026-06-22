# Backlog

Working backlog for Zirbe. Order reflects current priority, not a commitment,
and shifts as the app and its users teach us what matters. Two constraints shape
everything here: the no-backend privacy posture (the only network destinations
are the user's own IMAP and SMTP servers, so anything needing a server to broker
it is off the table), and app-password-only auth today (a real adoption ceiling
until OAuth lands).

One strategic line runs through the order: before Zirbe takes on a second
account, it earns the right to be someone's only mail app. Everything above the
multi-account line builds Zirbe into a full Apple Mail replacement for a single
IMAP account, as chat-native as the Messages metaphor allows. Multiple accounts
and the integrated inbox wait below that line.

## Shipped

- **M5 — offline and IDLE.** Done in two parts. Part 1: foreground live refresh
  while the inbox is open, a dedicated IMAP IDLE connection acting as a doorbell
  into the existing sync. Part 2: a best-effort background poll via BGTaskScheduler
  app-refresh, running one headless sync when iOS grants the wake. As promised
  there is no instant push — real push needs a server the privacy posture forbids
  — so new mail surfaces live in the foreground, at the next background poll iOS
  allows, and on pull-to-refresh, and the Settings sheet discloses that ceiling
  plainly.

- **Send-side attachments.** Attach photos, camera captures, or files to a
  compose or reply, staged as removable chips and sent over the existing send
  pipeline (SMTP send, Sent copy, optimistic local bubble). Verified on device.

- **Inline image thumbnails in bubbles.** Sent and received images render inline
  as downsampled thumbnails (ImageIO, cache-first), tap opens full resolution in
  QuickLook; non-image attachments stay as tappable chips. Shipped alongside
  send-side attachments. Verified on device.

- **Folder browsing, archive, and move.** Reach mailboxes beyond INBOX (Sent,
  Archive, Drafts, custom folders), with archive and move-to-folder as
  first-class actions beside trash. The structural foundation the rest leans on:
  drafts need a Drafts folder, junk needs a Junk folder, and move is the
  machinery both share. The home view stays scoped to INBOX so junk-only and
  sent-only threads don't leak in. Verified on device.

- **Drafts.** Save a half-written message and resume it, stored in the IMAP
  Drafts folder (the source of truth, via APPEND with `\Draft`). Saved on
  composer close — Save Draft or Discard on dismissing a non-empty composer, a
  quiet save on backgrounding — with an edit replacing the server copy
  (append-new, expunge-old, keyed on a stable Message-ID) and a send deleting
  the draft. Scoped to the new-conversation composer for v1; reply-drafts
  deferred. Resume by tapping a Drafts-folder thread to reopen the composer
  prefilled. Verified on device.

- **Sender avatars and day separators.** A round avatar beside each incoming run
  (the sender's photo from the on-device Contacts store, else a deterministic
  colored circle with their initials), bottom-aligned with the timestamp line and
  reserved as a gutter so a run stays aligned. The Contacts lookup is local and
  display-only, requested lazily, and degrades silently to monograms when denied.
  Plus a centered day divider ("Today", "Yesterday", weekday, then short date)
  between bubbles when the calendar day changes. Verified on device.

- **Local new-mail notifications.** When the background poll finds new INBOX mail,
  a local notification fires (one banner per message, a summary past three), the
  app badge tracks the inbox unread count, and a tap opens the conversation.
  Detection rides a per-account high-water mark of the highest INBOX UID already
  surfaced, so the same mail never notifies twice and only mail that arrived while
  the app was away is announced. A Settings toggle (default on) gates it. No
  backend and no instant push — it follows the same cadence as the background
  refresh, which Settings discloses. Verified on device.

## Above the multi-account line

In recommended sequence:

- **Send robustness: failed-send state, Bcc, and signature.** A sending/failed
  indicator on the optimistic bubble with a retry tap (today a dropped connection
  mid-send only sets an error string); Bcc in compose (we have To and Cc only,
  and Bcc is non-negotiable for a mail client); and an outgoing signature
  appended to composes (distinct from the received-signature surfacing in the
  held bucket below).
- **Voice messages.** Record a memo and send it as an audio attachment. Genuinely
  chat-native, and it rides the attachment pipe already built.
- **In-conversation search.** Find within an open thread, complementing the
  global search already shipped.
- **Save or share a received attachment.** A share sheet / Save to Files action
  from the QuickLook preview, so an attachment can leave the app.
- **Pin a conversation and swipe-to-reply.** Pin a thread to the top of the
  inbox, and reply with a swipe on a bubble. Cheap quality-of-life lifts.
- **Junk and block-sender.** A move-to-Junk action and a way to block a sender.
  Depends on folders, so it naturally follows that item.

## The multi-account line

Below the line: more than one account, and the auth tracks that widen reach.

- **Multiple accounts and an integrated inbox.** Connect more than one account
  and read them together. The Keychain and session layer is already keyed per
  account, so this generalizes cleanly.
- **Microsoft OAuth.** The tractable half of OAuth: MSAL public client plus PKCE
  feeding SwiftMail's XOAUTH2, no embedded secret and no audit gate. App-password
  sign-in is being deprecated for M365, so eventually Microsoft accounts stop
  connecting without it — a real external clock, but adoption-facing, not blocking
  current dogfooding. Grouped here with Google OAuth so the two token flows get
  built back to back.
- **Google OAuth.** The expensive half: gated behind Google's restricted-scope
  verification and an annual CASA security audit. Contingent on appetite for that
  audit; Gmail's reach is the only reason to take it on.

## Held (unscheduled)

- **Server-side search.** Local search (shipped) covers only mail already synced
  into the store. A "search everything" pass over IMAP SEARCH/ESEARCH would reach
  older mail still on the server. SwiftMail provides it; the work is merging server
  hits with local results and fetching the matches. Pull this up when the synced
  window proves too small in practice.
- **Signature surfacing.** Keep the trailing signature that the quote fold
  currently discards and show it dimmed or collapsible, reusing Klartext's parsed
  `signature`. Cheap but mild — polish, not a gap.
- **Multi-segment text body assembly.** When a message splits its body across
  several text parts (Apple Mail's inline-attachment layout wraps body text, the
  file, then a trailing text segment), the bubble shows only the first segment.
  Assemble all the inline body text parts in order so text written after an inline
  attachment isn't hidden. Today the trailing segment is usually empty, so this is
  a correctness edge, not a common loss.

## Out of scope (privacy posture)

These can't be built without breaking the no-backend, no-third-party rule, so
they stay off the list rather than lingering as someday-maybes:

- **Rich link previews.** Fetching OpenGraph metadata leaks every link a user
  receives to arbitrary third-party servers.
- **Tapback-style reactions.** No email protocol carries them, so they would be
  invisible to every other mail client.
- **Read receipts.** Privacy-hostile by nature, and against the posture even
  where the protocol (MDN) allows it.
