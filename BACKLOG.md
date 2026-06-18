# Backlog

Working backlog for Zirbe. Order reflects current priority, not a commitment,
and shifts as the app and its users teach us what matters. Two constraints shape
everything here: the no-backend privacy posture (the only network destinations
are the user's own IMAP and SMTP servers, so anything needing a server to broker
it is off the table), and app-password-only auth today (a real adoption ceiling
until OAuth lands).

## In priority order

- **M5 — offline and IDLE.** Foreground live refresh while the inbox is open, and
  a best-effort background poll for new mail via BGTaskScheduler. More than polish:
  a Messages-style app that doesn't auto-update breaks the illusion. But there is
  no instant push — real push needs a server the privacy posture forbids — so the
  win is capped at foreground-live plus poll, and that limit must be disclosed
  honestly.
- **Send-side attachments.** Attach a photo or file to a compose or reply, the
  outbound complement to opening attachments — it closes the attachment story end
  to end. Design the UX from the chat metaphor first (Messages-style inline media
  and file bubbles, not a paperclip-and-MIME list). Ranked above multiple accounts
  because attaching a file is a far more frequent need for a single-account user
  than juggling two accounts.
- **Drafts.** Save a half-written message and resume it; compose is send-or-discard
  today.
- **Folder browsing, archive, and move.** Reach mailboxes beyond INBOX (Sent,
  Archive, custom folders), and add archive and move-to-folder as first-class
  actions beside trash, since archive is the verb most people reach for over
  delete (today only Trash exists).
- **Multiple accounts and an integrated inbox.** Connect more than one account
  and read them together. The Keychain and session layer is already keyed per
  account, so this generalizes cleanly.
- **Microsoft OAuth.** The tractable half of OAuth: MSAL public client plus PKCE
  feeding SwiftMail's XOAUTH2, no embedded secret and no audit gate. App-password
  sign-in is being deprecated for M365, so eventually Microsoft accounts stop
  connecting without it — a real external clock, but adoption-facing, not blocking
  current dogfooding, so it sits after the experience-deepening work. Grouped here
  with Google OAuth so the two token flows get built back to back.
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
