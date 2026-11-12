# Releasing Zirbe

Zirbe ships the way every iOS app in the fleet does: through the release apps
in `excelano/shipping` (`shots-appstore`, `build-release`, `ship-appstore`), run
from a clone that holds a `ship.toml` (gitignored), with the version submitted
for App Review by hand in App Store Connect. What follows is particular to
Zirbe.

Because the app is unusable without a mail account, App Review needs Sign-In
Required on and the demo mailbox on the record. That mailbox is on a private
server with no preset, so the reviewer's notes in
`packaging/store-listing.toml` give the IMAP and SMTP hosts and ports to enter
by hand; its address and password live only in App Store Connect's sign-in
fields, since the repository is public. App Privacy stays "Data Not
Collected": the only network destinations are the user's own servers, and the
on-device cache is local storage, not collection.
