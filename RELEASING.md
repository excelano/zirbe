# Releasing Zirbe

A release runs from a clone that holds a `ship.toml` (gitignored), through the
release apps in `excelano/shipping`: `shots-appstore` takes the screenshots on
the simulator, `build-release` bumps the version, archives and exports the
signed build on the Mac, tags, and attaches the `.ipa` to the GitHub release,
and `ship-appstore` uploads that build, fills in App Store Connect, and submits
it for review. Nothing is done in Xcode or in the App Store Connect website.

What the repository holds for that:

- `Zirbe/Config/Version.xcconfig` is the single source of the marketing version
  and the build number. Every target inherits both from the project-level base
  configuration; do not re-declare either key in a target's build settings, or
  the target's value silently wins. The build number is global and monotonic
  across the app record, and App Store Connect rejects one it has already
  accepted, so a re-upload after a rejection moves to the next number.
- `packaging/store-listing.toml` is the listing copy and the reviewer's notes,
  pushed on every release. The demo mailbox's address and password live only in
  the App Store Connect sign-in fields, never here: the repository is public.
- `packaging/release-notes.toml` is what changed in the release being cut, and
  its `version` must match, or the release stops.
- `packaging/ios/shots.sh` is the screenshot recipe: which screens, in which
  state, from the demo data the Debug build carries (`--demo` and its
  companions in `DemoMode.swift`).

Because the app is unusable without a mail account, App Review needs Sign-In
Required on and the demo mailbox on the record. That mailbox is on a private
server with no preset, so the notes tell the reviewer the IMAP and SMTP hosts
and ports to enter by hand. App Privacy stays "Data Not Collected": the only
network destinations are the user's own servers, and the on-device cache is
local storage, not collection.

Development installs on a device go through `~/bin/build-to-phone.sh zirbe`
on the Mac.
