# Backlog

Working backlog for Zirbe. Order reflects current priority, not a commitment,
and shifts as the app and its users teach us what matters. Two constraints shape
everything here: the no-backend privacy posture (the only network destinations
are the user's own IMAP and SMTP servers, so anything needing a server to broker
it is off the table), and app-password-only auth today (a real adoption ceiling
until OAuth lands).

## Next milestone

- **M5 — offline and IDLE.** Foreground live refresh while the inbox is open, and
  a best-effort background poll for new mail via BGTaskScheduler. There is no
  instant push: real push needs a server the privacy posture forbids, so
  notifications are poll-timed and that limit must be disclosed honestly.

## Then, in priority order

- **Search.** Find an old message by sender, subject, or text. The largest single
  usability hole today, so it leads the post-M5 work.
- **Folder browsing, archive, and move.** Reach mailboxes beyond INBOX (Sent,
  Archive, custom folders), and add archive and move-to-folder as first-class
  actions beside trash, since archive is the verb most people reach for over
  delete.
- **Multiple accounts and an integrated inbox.** Connect more than one account
  and read them together. The Keychain and session layer is already keyed per
  account, so this generalizes cleanly.
- **OAuth for Gmail and Microsoft.** App-password auth is being deprecated,
  Microsoft especially, so without OAuth a large share of real users cannot
  connect. Its own deliberate project, not a small feature, because the
  no-backend posture makes the token flow genuinely tricky.

## Unscheduled

- **Drafts.** Save a half-written message and resume it; compose is send-or-discard
  today.
- **Flag and star.** Surface IMAP `\Flagged` as a lightweight triage marker,
  cheap since `\Seen` is already managed.
- **Signature surfacing.** Keep the trailing signature that the quote fold
  currently discards and show it dimmed or collapsible, reusing Klartext's parsed
  `signature`.
- **Send-side attachments.** Attach a photo or file to a compose or reply, the
  outbound complement to opening attachments.
- **Multi-segment text body assembly.** When a message splits its body across
  several text parts (Apple Mail's inline-attachment layout wraps body text, the
  file, then a trailing text segment), the bubble shows only the first segment.
  Assemble all the inline body text parts in order so text written after an inline
  attachment isn't hidden. Today the trailing segment is usually empty, so this is
  a correctness edge, not a common loss.
