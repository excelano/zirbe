# Releasing Zirbe to the App Store

The end-to-end runbook for cutting a Zirbe release: bump the version, archive,
upload, fill in App Store Connect, and submit. This is the store counterpart to the
CLI dev-install path (`~/bin/build-to-phone.sh zirbe`). It is modeled on Blick's
`RELEASING.md`; where Zirbe differs from Blick the difference is called out, because
those are the places a habit from the other project would bite.

Zirbe ships **iPhone-only** (`TARGETED_DEVICE_FAMILY = 1`), with **no watch app and
no widgets**, so the archive is just the app and the screenshot matrix is a single
size. iPad returns once the split-view layout is built (see `BACKLOG.md`); until
then the target stays iPhone-only so a submission needs no iPad screenshot set. It
authenticates to
the **user's own IMAP and SMTP servers with an app-specific password**, not a
Microsoft sign-in, which changes what App Review needs. And it is a **public,
MIT-licensed** repository, so nothing sensitive (demo-account logins, reviewer notes)
may be committed; that material lives in the gitignored `app-store-connect-metadata.md`.

## Versioning

`MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` live in
`Zirbe/Config/Version.xcconfig`, wired as the project-level base configuration for
both the Debug and Release configurations, the way Blick does it. A version bump is
therefore a two-line edit in one file, with no way to update Debug and forget
Release. Do not re-declare either key in any target's build settings: a target-level
value silently wins over the xcconfig and the two surfaces drift apart without
warning.

Build numbers are global and monotonic across the whole app record, independent of
the marketing version: each upload takes the next one, whether the release is a
patch or a feature. App Store Connect rejects a build number it has already
accepted, even for a submission that was later rejected, so a re-upload after a
rejection also moves to the next number. For what the last upload used, read the
git tags and `Config/Version.xcconfig` rather than trusting a number written down
here — it would be wrong within a release or two.

## Create the app record (first release only)

Before the first archive can be uploaded there has to be an app record to receive
it. In App Store Connect, **Apps → + → New App**: platform iOS, the primary language,
the bundle ID `com.excelano.zirbe` (must already exist in the Developer portal's
Identifiers, and match the project's `PRODUCT_BUNDLE_IDENTIFIER`), and an SKU (any
stable internal string, e.g. `zirbe-ios`). The name reserved here is the store name;
see `app-store-connect-metadata.md` for the exact text to use.

## Archive and upload

What has to be true at the end, however you get there: a Release-configuration
archive of the intended commit, exported and signed for App Store distribution,
uploaded to App Store Connect under the right version and a build number that
record has never accepted before. The routes below all produce that; pick whichever
suits the session. Zirbe has no watch app or widget extension, so the archive is
the app alone either way.

**Archiving in Xcode.** Set the run destination to **Any iOS Device (arm64)** —
Archive is greyed out while a simulator or a specific device is selected — then
**Product → Archive**. The Organizer opens when it finishes.

**Archiving from the command line**, which works over SSH with no GUI:

```bash
xcodebuild -project Zirbe/Zirbe.xcodeproj -scheme Zirbe \
  -configuration Release -destination 'generic/platform=iOS' \
  -archivePath ~/Library/Developer/Xcode/Archives/$(date +%F)/Zirbe-<version>-b<build>.xcarchive \
  -allowProvisioningUpdates archive
```

The path matters only if the Organizer is going to be the next step: it lists
archives under `~/Library/Developer/Xcode/Archives/<date>/` and nowhere else, so an
archive written to a scratch directory simply won't appear and can look like the
upload is blocked when nothing is wrong.

**Uploading from the Organizer.** Select the archive, then **Distribute App → App
Store Connect → Upload**, taking the defaults on signing. This needs the GUI, at
the machine or over VNC.

**Uploading from the command line** needs an App Store Connect API key, since
there is no interactive sign-in. Generate one under App Store Connect → Users and
Access → Integrations, put the `.p8` in `~/.appstoreconnect/private_keys/`, then
export and upload:

```bash
xcodebuild -exportArchive -archivePath <archive> -exportPath <dir> \
  -exportOptionsPlist <plist> -allowProvisioningUpdates      # method: app-store-connect
xcrun altool --upload-app -f <dir>/Zirbe.ipa -t ios --apiKey <id> --apiIssuer <issuer>
```

Two things look wrong on this Mac and are not:

- **There is no Apple Distribution certificate in the keychain, and there should
  not be.** Distribution signing is cloud-managed: Apple holds the certificate and
  key and signs on request. `security find-identity -v -p codesigning` showing only
  an Apple Development identity is the expected state, and every release has shipped
  this way. Don't try to create one.
- **A finished archive records `SigningIdentity = Apple Development`.** Distribution
  signing happens at export, not at archive, so this is true of archives that have
  already shipped. Verify the exported build instead: `codesign -dvvv` on the `.app`
  inside the `.ipa` should name `Apple Distribution: Excelano LLC (9K6W5PMFYP)`, and
  the export's `DistributionSummary.plist` should read
  `type = Cloud Managed Apple Distribution`.

Zirbe's dependencies (SwiftMail, GRDB, swift-nio, Klartext) are Swift packages built
from source, so their dSYMs are present and there is no third-party binary framework
to throw an "Upload Symbols Failed" warning. If one appears, read it rather than
reflexively ignoring it.

After "Upload Successful," give App Store Connect roughly ten to fifteen minutes to
finish processing before the build becomes attachable.

## App Store Connect (web)

Create the version page first if it does not exist, so the processed build has
somewhere to attach. Fill the App Information and Version fields from
`app-store-connect-metadata.md`, attach the build in the Build section, confirm the
release option (Automatic releases the moment it is approved; Manual waits for you
to click Release), and Submit for Review.

Things worth re-checking each time, and the ones that differ from Blick:

- **App Privacy** is "Data Not Collected." Zirbe's only network destinations are the
  user's own IMAP and SMTP servers; the on-device SQLite cache is local storage, not
  collection, because nothing is transmitted to the developer or a third party.
  `PRIVACY.md` is the substance behind the label. Revisit this only if a release
  genuinely changes what leaves the device.
- **App Review needs a working demo mailbox.** Zirbe is unusable without an email
  account, so turn Sign-In Required on and provide, in the review notes, a demo
  account the reviewer can actually sign in to: an email address and its
  app-specific password, and — unless the account is on a provider Zirbe already has
  presets for — the IMAP host/port and SMTP host/port. Prefer a preset provider so
  the server fields auto-fill and the reviewer only pastes the address and password.
  Note plainly that this is a standards-based IMAP/SMTP client and the sign-in is the
  user's own mail account, not a Zirbe account. Keep the real credentials only in App
  Store Connect; the metadata file holds a placeholder.
- **Screenshots.** Only one size is required and App Store Connect scales it down for
  smaller devices: iPhone 6.9" at 1320×2868. There is no iPad set (iPhone-only) and
  no watch set. Stage them in `~/Downloads/zirbe-screenshots/iphone-6.9/`. When
  iPad returns, add the iPad 13" set at 2064×2752.
- **Transport security.** Zirbe requires TLS on both transports. Every mainstream
  provider offers it on the standard ports, so this is invisible in practice; it is
  only worth remembering if a reviewer or tester ever points the app at a plaintext-
  only test server, which will (correctly) fail to connect.

The listing text and reviewer notes live in `app-store-connect-metadata.md`, which is
gitignored precisely because this repository is public. Per-submission paste sheets are
staged in the repo root as `Zirbe-<version>-ASC-paste.md`, gitignored the way
Blick's are, so the release copy sits beside the code rather than on the Desktop.
Discard one once its submission has gone through.

## Tag the release

After the build is uploaded and submitted, tag the exact commit it was built from,
annotated, matching the scheme `vMAJOR.MINOR.PATCH`:

```bash
git tag -a v1.0 -m "Zirbe 1.0 — first App Store release (build 1, submitted <date>)" <commit>
git push origin v1.0
```

Commit and tag from the Mac. The home directory is SMB-shared to the Debian VM and
`.git/objects` writes over that mount fail, so a commit or tag initiated from the
Debian side does not complete.

## If a submission is rejected

A build cannot be hot-swapped into an in-flight review. Fix the issue, bump to the
next build number, re-archive, re-upload, and resubmit. For a first release the two
likeliest causes are the demo-account path (the reviewer could not sign in, so
double-check the credentials and server settings are correct and the account is
reachable from outside your network).
