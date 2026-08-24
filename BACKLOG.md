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

- **Performance pass on delete and the sync path.** Deleting a conversation used
  to make it vanish, return, and vanish again, worst on a bulk selection: a sync
  and a mutation could interleave, so a sync that had already read the server's
  message list wrote that stale list back over rows the delete had just removed,
  and our own expunges were firing that sync through the IDLE watch. Whole
  operations now serialize, live-refresh ticks arriving mid-mutation coalesce into
  one catch-up sync instead of one per conversation, and rows for trash, archive,
  junk, and move leave the list immediately rather than waiting on the round trip.
  Alongside it, the work each sync repeated for an answer nothing had changed:
  inbox previews are derived once when a body is stored rather than re-parsed on
  every rethread (135 ms to 41.5 ms), a header-only re-save no longer reads and
  rewrites the body it isn't carrying, the backfill moves one thread's snippet
  instead of rebuilding every thread in the account, and the on-disk store runs in
  WAL so a read no longer waits on the writer (worst-case read during a sync, 49.2
  ms to 7.2 ms). In the view layer, each bubble's place in the stack is worked out
  once per thread rather than every frame of a timestamp-peek drag, and a contact
  photo is decoded once per sender rather than on every row that shows it.
  Verified on device.

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

- **Send robustness: failed-send retry and Bcc.** A reply whose SMTP send fails
  now lands in the thread as a red "Not Delivered · Tap to Retry" bubble; tapping
  resends the held draft verbatim (same recipients, body, attachments, and
  Message-ID, so a retry can't double), and on success the bubble flips to sent in
  place. Send-state persists, so the failed bubble survives a relaunch, though
  retry is same-session (a relaunched bubble reads "Not Delivered" without the
  retry, and the user recomposes). New conversations and forwards keep their
  composer open on failure instead, since a brand-new outgoing thread isn't in the
  INBOX-scoped home list and a bubble there would be invisible. Bcc joins the
  composer too: it reaches the SMTP envelope but never the headers, so the blind
  copy stays blind, and it counts as a recipient so a Bcc-only send works.
  Transport-only for now (not recorded in the Sent copy, no in-app Bcc display).
  Verified on device.

- **Voice messages.** Record a memo from the compose attach menu and send it as an
  audio attachment over the pipe already built. A received audio attachment renders
  inline as a small player (play/pause, progress track, running time) rather than a
  filename to tap; any `audio/*` file gets this, so the rich read is Zirbe-to-Zirbe
  while other clients still receive a normal playable attachment. The recorder is a
  staged record-review-attach sheet (mono AAC m4a, voice-grade) that drops a chip
  into the composer like any other attachment, so a voice memo can ride alongside
  text or a photo, and a memo sent with no words shows just the player with no
  placeholder line above it. No backend; the recording stays on device until the
  message sends. Verified on device.

- **Save or share a received attachment.** Tapping an attachment opens a full
  QuickLook preview with its native toolbar, so the Share action (AirDrop, Save to
  Files, and the rest) and Done are both there — an attachment can leave the app.
  Shared by the file chip and the inline image view. Verified on device.

- **Reactions (tapbacks).** Long-press a bubble for a floating emoji bar (👍 👎
  ❤️ 😂 ‼️ ❓, mirroring Messages) plus Forward; tap one and a badge lands on the
  bubble's corner. A reaction rides the user's own SMTP/IMAP like any mail (no
  backend): a real reply carrying an `X-Zirbe-Reaction` header and `In-Reply-To`,
  so a receiving Zirbe shows the badge and hides the reaction's own bubble while
  every other client sees a readable "Reacted 👍 to '…'" line (always-send and
  degrade, the way an iMessage tapback degrades to SMS). Reactions are filtered
  out of the bubble stream, the inbox preview, the unread state, the folder
  counts, and the new-mail notifier, so a tapback never bolds a thread or fires a
  notification. Remove and change work through a short send-delay undo window
  (~5s): the badge shows at once but the email waits, so pulling it back or
  switching emoji within the window never sends anything — and once it's out it's
  locked (no "reaction removed" follow-up email). Leaving the conversation or
  backgrounding flushes a pending reaction rather than dropping it. Zirbe-to-Zirbe
  for the rich read; the header round-trips through SwiftMail's existing full-
  header fetch, no extra round trip. Verified on device.

- **Contact type-ahead in recipient fields.** As the user types in To, Cc, or
  Bcc, matching contacts (by name or address) from the on-device Contacts store
  are suggested to tap, filling the field as a `Name <addr>` token. The address
  book is loaded once into memory and filtered per keystroke, ranked prefix
  first; it reuses the same local, display-only Contacts access already used for
  avatars, so nothing leaves the device and there's no backend. A denied
  permission simply yields no suggestions, and the field still takes a typed
  address. Shared by the new-conversation composer and the forward composer
  through one recipient-field component. Verified on device.

- **In-conversation search.** A "Find in Conversation" action in the thread's ⋯
  menu opens a search panel over the open conversation; typing filters it to the
  messages that contain the query, each shown as a result row with the sender and
  a one-line snippet with the match tinted. Tapping a result closes the panel and
  scrolls that bubble to center with a brief accent-outline flash. Matching is
  case- and diacritic-insensitive over the visible body text (quoted history and
  HTML aren't searched, so what you find is what the bubble shows), computed in
  memory over the already-loaded thread, so there's no network and the same
  no-backend posture as the inbox search. Verified on device.

- **Swipe-to-reply.** Swipe a bubble right to reply to that message specifically
  (right being the common reply direction, and leaving the left drag for the
  timestamp peek): it slides under the finger revealing a reply arrow, and past
  the threshold on release it starts a reply aimed at that message, with a
  "Replying to…" chip above the reply bar (✕ to cancel, which also drops the
  keyboard) and the field focused. A "Reply" item in the long-press menu is the
  non-gesture path. On send, that message is quoted and the reply threads onto it
  (`In-Reply-To`) rather than the thread's latest; clearing the chip falls back to
  a normal reply. The gesture is simultaneous with the scroll so it never blocks
  it, engaging only on a rightward, horizontal-dominant drag. Verified on device.

- **Peek per-bubble timestamps.** Drag the message stack left and every bubble
  slides under the finger to reveal its send time along the trailing edge,
  iMessage-style, springing back on release. Only the mid-run bubbles that don't
  already show a time below reveal one, filling the gaps. A simultaneous,
  leftward-only, horizontal-dominant drag, so it never blocks the scroll and never
  collides with the rightward reply swipe. View-layer only. Verified on device.

- **Pin a conversation.** Pin a thread to keep it at the top of the inbox, via a
  leading swipe action, a context-menu item, and a small pin marker on the row.
  Pinning is local-only app state (no server flag), so it needs no connection; it
  lives in its own `pinnedThread` table keyed by thread id rather than on the
  thread row, so it survives the rethread that rebuilds thread rows every sync.
  The inbox and per-folder reads sort pinned conversations to the top, then by
  recency; search results stay recency-ordered. Verified on device.

- **Junk and block-sender.** Move-to-Junk shipped with folders; block-sender
  completes it. Blocking a sender moves their existing INBOX mail to Junk and
  keeps new arrivals out, moving them to Junk during every sync before they reach
  the inbox. The blocklist is local app state (a `blockedSender` table keyed by
  the normalized address, surviving the rethread that rebuilds thread rows) and is
  enforced at sync time, reusing the same server move as the manual junk action,
  so nothing new leaves the device. You block from the conversation's ⋯ menu,
  with a confirmation since it sweeps existing mail, and manage the list in
  Settings › Blocked Senders (swipe to unblock). Matching is by exact address,
  case-insensitive; the account's own address can't be blocked. Unblocking stops
  future junking but leaves already-junked mail where it is. Retroactive over the
  synced INBOX window, not a sender's full history still on the server. Verified
  on device.

## Above the multi-account line

With junk and block-sender shipped, Zirbe meets the bar set at the top of this
file: a full single-account Apple Mail replacement, as chat-native as the
Messages metaphor allows. New single-account feature requests land here as they
surface.

- **iPad split view.** 1.0 shipped iPhone-only (`TARGETED_DEVICE_FAMILY = 1`) to
  clear the first submission without the iPad screenshot set. Next up: restore
  universal and build a proper iPad layout. The app's core navigation is a
  single-column `NavigationStack` in `RootView`; the work is an adaptive
  two-column `NavigationSplitView` (conversation list beside the open
  conversation) that collapses to today's push stack on compact width, so iPhone
  behavior is unchanged. The crux is that `InboxView`'s List already binds
  `selection` for bulk-select mode, so single-selection navigation has to branch
  by edit mode. Regression surface to cover: push nav, notification-tap routing,
  demo-open capture, Drafts-opens-composer, bulk select, and back behavior. Once
  it lands, re-enable the iPad 13" screenshot set and the "beside the
  conversation" marketing beat.

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
- **Outgoing signature.** Auto-append a user signature to composed mail. Cut from
  send robustness on purpose, not forgotten: a signature is a formal-email artifact
  at odds with Zirbe's chat-native identity (no one signs a text), and the From
  line plus avatar already say who sent a message. The one real surviving use is a
  business-card block (title, phone, company) on professional sends. Revisit only
  if a user asks; if built, it likely belongs on new conversations and forwards,
  not chat-style replies.
- **Multi-segment text body assembly.** When a message splits its body across
  several text parts (Apple Mail's inline-attachment layout wraps body text, the
  file, then a trailing text segment), the bubble shows only the first segment.
  Assemble all the inline body text parts in order so text written after an inline
  attachment isn't hidden. Today the trailing segment is usually empty, so this is
  a correctness edge, not a common loss.

### From the 2026-07-06 code review

A three-lens review (correctness, performance, security) ran after block-sender
shipped. Batch 1 landed the safe, high-value fixes the same day: bulk-action
rethreading, the narrowed unread-count read plus a mailbox index, TLS required on
the transports, header-injection sanitizing, and a type-ahead race. Batch 2
followed with the three that wanted more care: the pin now follows a thread
across a re-root (it was keyed by the thread id, which changes when an earlier
ancestor re-roots the tree); the conversation view caches its derived render
inputs off the thread so the timestamp peek stays smooth on long threads; and the
per-sync store reads (`pruneMessages`, `blockedInboxRefs`,
`latestMessagesNeedingBodies`) were narrowed to the columns they use, with
`blockedInboxRefs` also filtering in SQL.

The one review item left open is now closed too. `reconcile` no longer runs a
second full rethread after backfilling bodies: the reason it waited was that a
targeted snippet update would have duplicated the snippet logic living in
`ThreadRow`, and that logic has since moved to the message row, so the backfill
now moves each thread's snippet into place directly.

Parked as polish: FTS5 for local search (the 6-column leading-wildcard LIKE), a
selection-lookup dictionary, and redacting the account email from debug logs.

## Out of scope (privacy posture)

These can't be built without breaking the no-backend, no-third-party rule, so
they stay off the list rather than lingering as someday-maybes:

- **Rich link previews.** Fetching OpenGraph metadata leaks every link a user
  receives to arbitrary third-party servers.
- **Read receipts.** Privacy-hostile by nature, and against the posture even
  where the protocol (MDN) allows it.
