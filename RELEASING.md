# Releasing Zirbe to the App Store

The end-to-end runbook for cutting a Zirbe release: bump the version, archive,
upload, fill in App Store Connect, and submit. This is the store counterpart to the
CLI dev-install path (`~/bin/build-to-phone.sh zirbe`). It is modeled on Blick's
`RELEASING.md`; where Zirbe differs from Blick the difference is called out, because
those are the places a habit from the other project would bite.

Zirbe 1.0 ships **iPhone-only** (`TARGETED_DEVICE_FAMILY = 1`), with **no watch app
and no widgets**, so the archive is just the app and the screenshot matrix is a
single size. iPad returns as a fast-follow once the split-view layout is built (see
`BACKLOG.md`); until then the target stays iPhone-only so the submission needs no
iPad screenshot set. It authenticates to
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
the marketing version. 1.0 shipped as build 1; the next upload is build 2 regardless
of whether it is a patch or a feature release. App Store Connect rejects a build
number it has already accepted, even for a rejected submission, so a re-upload after
a rejection always takes the next number.

## Create the app record (first release only)

Before the first archive can be uploaded there has to be an app record to receive
it. In App Store Connect, **Apps → + → New App**: platform iOS, the primary language,
the bundle ID `com.excelano.zirbe` (must already exist in the Developer portal's
Identifiers, and match the project's `PRODUCT_BUNDLE_IDENTIFIER`), and an SKU (any
stable internal string, e.g. `zirbe-ios`). The name reserved here is the store name;
see `app-store-connect-metadata.md` for the exact text to use.

## Archive and upload (Xcode, on the Mac)

1. Set the run destination to **Any iOS Device (arm64)**. Archive is greyed out
   while a simulator or a specific device is selected.
2. **Product → Archive.** This builds the Release configuration and opens the
   Organizer when it finishes. There is no watch app or widget extension to embed,
   so the archive is the app alone.
3. In the Organizer, select the new archive, then **Distribute App → App Store
   Connect → Upload**, taking the defaults on signing (the team distribution cert).
4. Zirbe's dependencies (SwiftMail, GRDB, swift-nio, Klartext) are Swift packages
   built from source, so their dSYMs are present and there is no third-party binary
   framework to throw an "Upload Symbols Failed" warning. If one appears, read it
   rather than reflexively ignoring it.
5. After "Upload Successful," give App Store Connect roughly ten to fifteen minutes
   to finish processing before the build becomes attachable.

## App Store Connect (web)

Create the version page first if it does not exist, so the processed build has
somewhere to attach. Fill the App Information and Version fields from
`app-store-connect-metadata.md`, attach the build in the Build section, confirm the
release option (Automatic releases the moment it is approved; Manual waits for you
to click Release), and Submit for Review.

First-release specifics, and the ones that differ from Blick:

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
  smaller devices: iPhone 6.9" at 1320×2868. There is no iPad set (iPhone-only 1.0)
  and no watch set. Stage them in `~/Downloads/zirbe-screenshots/iphone-6.9/`. When
  iPad returns, add the iPad 13" set at 2064×2752.
- **Transport security.** Zirbe requires TLS on both transports. Every mainstream
  provider offers it on the standard ports, so this is invisible in practice; it is
  only worth remembering if a reviewer or tester ever points the app at a plaintext-
  only test server, which will (correctly) fail to connect.

The listing text and reviewer notes live in `app-store-connect-metadata.md`, which is
gitignored precisely because this repository is public. Per-submission paste sheets
can be staged on the Desktop and discarded after use.

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
