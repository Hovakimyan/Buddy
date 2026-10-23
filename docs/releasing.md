# Releasing Buddy (maintainer)

How to turn this repository into the two things colleagues install: a notarized `Buddy-<version>.dmg` for the Mac and a
TestFlight build for the iPhone. Colleagues follow [`installing.md`](installing.md). Script details and every flag:
[`scripts/README.md`](../scripts/README.md). Portal and CloudKit details: [`cloudkit-setup.md`](cloudkit-setup.md).

**Status.** The unsigned dmg path is built and checked on a machine with no Apple account. Signing, notarization, the
TestFlight export and upload, the real iPhone link and the first-run setup window have never run on a real account or
device (see "What has never been run" at the end). Expect to fix small things on the first real run. Never put your Team ID,
the API key file, its key id or its issuer id in a file in this repository: they go in environment variables only.

**Audience.** The dmg and the TestFlight build are for preview testers: no public download, no external TestFlight
testers, no App Store. All of the app's code and artwork is Buddy's own; the bundled sounds are CC0, each listed with its
source in `Apps/BuddyMac/Resources/sounds/SOURCES.md` (bundled in the app). `scripts/check-names.sh` (run by
`scripts/test-release.sh` on the tree and on the built app) checks that the names of the project Buddy was cloned from,
of its character and of its author appear nowhere: not in a tracked file's path or contents, nor in the app's file
names, file bytes, `Info.plist` files or the constants its code builds (details in `scripts/README.md`).

**Repository.** Buddy is maintained by [Sergey Hovakimyan](https://github.com/Hovakimyan) at
https://github.com/Hovakimyan/Buddy. Keep publication settings under the maintainer’s control.

**Identifier setup.** The Mac and phone identifiers use `com.sergeyhovakimyan.buddy`, and CloudKit uses
`iCloud.com.sergeyhovakimyan.buddy`. Register these identifiers and regenerate provisioning profiles before signed builds.
A renamed bundle is a separate app identity: preferences and existing CloudKit data do not migrate automatically.
Replace older local builds after testing; previously exported artifacts retain the identity they were built with.

## One-time Apple setup

1. **Paid Apple Developer Program account.** Some steps below need the Account Holder (creating the Developer ID
   certificate, and the API key unless you are an Admin). Accept the
   current agreements in the developer portal and in App Store Connect, or the scripts fail with an agreements error.
2. **Developer ID Application certificate** (signs the Mac app and dmg outside the App Store). Xcode > Settings > Accounts >
   your team > Manage Certificates > **+** > Developer ID Application. Check it is in your login keychain:
   `security find-identity -v -p codesigning` lists one `Developer ID Application: ...` line.
3. **App Store Connect API key with the Admin role.** App Store Connect > Users and Access > Integrations > App Store Connect
   API > Team Keys > **+**, access **Admin** (other roles often cannot create the cloud-managed distribution certificate).
   Download `AuthKey_<KEYID>.p8` once (Apple lets you download it only once), keep it outside the repo with mode 600
   (`chmod 600 AuthKey_<KEYID>.p8`), and note the key id and the issuer id shown on that page.
4. **notarytool keychain profile** (so notarization needs no password on the command line). With the key from step 3:

   ```sh
   xcrun notarytool store-credentials buddy-notary --key <path to AuthKey_KEYID.p8> --key-id <KEYID> --issuer <ISSUER_ID>
   ```

   `buddy-notary` is the profile name you will put in `BUDDY_NOTARY_PROFILE`. (With an Apple ID instead:
   `--apple-id`, `--team-id` and an app-specific password, which `notarytool` asks for.)
5. **App IDs and the iCloud container.** `com.sergeyhovakimyan.buddy.mac` and `com.sergeyhovakimyan.buddy.phone`, both with iCloud
   (CloudKit, container `iCloud.com.sergeyhovakimyan.buddy`) and Push Notifications: `docs/cloudkit-setup.md` sections 2 and 8.
   Automatic signing with `-allowProvisioningUpdates` creates them the first time.
6. **Register your iPhone first.** A team with no registered device cannot create the development profile the TestFlight
   archive is signed with. Connect the iPhone (Developer Mode on, trust this Mac) and run:

   ```sh
   export BUDDY_TEAM_ID=<YOUR_TEAM_ID>
   scripts/phone-signed-build.sh --register-device
   ```

   Add `--install` to put the signed development build on the phone; you need it for step 9.
   The Mac needs the same once: the first signed `scripts/release.sh` run takes `--register-device`, so this Mac is
   added to the team and its development profile (see "Mac: notarized dmg" below).
7. **First export.** With the API key from step 3 in the environment (see "iPhone: TestFlight" below), run
   `scripts/testflight.sh --export-only`. It creates the App ID and profiles and checks the exported `.ipa`.
8. **App Store Connect app record** for `com.sergeyhovakimyan.buddy.phone` (App Store Connect > Apps > **+** > New App). It needs the
   App ID that step 7 created.
9. **CloudKit Production schema.** Notarized and TestFlight builds use the **Production** CloudKit environment, which
   starts empty. Run a signed *development* build of both apps (the Mac per `cloudkit-setup.md` section 3, the phone from step
   6), start a Claude Code session, trigger a permission request and answer it from the iPhone, so the `Session`, `Approval`
   and `Decision` record types exist in Development. Then CloudKit Dashboard > container `iCloud.com.sergeyhovakimyan.buddy` >
   Schema > **Deploy Schema Changes...** to Production. Deploy again whenever a field is added.
10. **Internal testers.** TestFlight internal testers are App Store Connect users: add each colleague at App Store Connect >
   Users and Access (they accept the invite for their Apple Account email), then TestFlight > Internal Testing > create a
   group and add them. Use their Apple Account email, the same account they use for iCloud on the Mac.

## Release steps

Pick one version for both apps: `MARKETING_VERSION` in `Apps/project.yml` (or `--version X.Y.Z` on each script). Run the
script tests first: `scripts/test-release.sh` and `scripts/test-phone.sh` (they use fakes and never contact Apple).

### Mac: notarized dmg

```sh
export BUDDY_TEAM_ID=<YOUR_TEAM_ID>
export BUDDY_NOTARY_PROFILE=buddy-notary
# only if Xcode is not signed in to the developer account:
export BUDDY_ASC_KEY_PATH=<path to AuthKey_KEYID.p8> BUDDY_ASC_KEY_ID=<KEYID> BUDDY_ASC_ISSUER_ID=<ISSUER_ID>
scripts/release.sh --dry-run                # prints every command; builds and contacts nothing
scripts/release.sh --version 0.2.0 --build 2
# the first time on a fresh team: scripts/release.sh --register-device --version 0.2.0 --build 2
```

Writes `dist/Buddy-<version>.dmg` and `dist/Buddy-<version>.dmg.sha256`. `BUDDY_SIGN_IDENTITY` defaults to `Developer ID
Application`. Other flags: `--skip-notarize` (signed, not notarized), `--unsigned` (a test dmg, with no phone link),
`--out-dir`. The script checks the signatures before sending anything to Apple, and requires the notary status `Accepted`.

### iPhone: TestFlight

```sh
export BUDDY_TEAM_ID=<YOUR_TEAM_ID>
export BUDDY_ASC_KEY_PATH=<path to AuthKey_KEYID.p8> BUDDY_ASC_KEY_ID=<KEYID> BUDDY_ASC_ISSUER_ID=<ISSUER_ID>
scripts/testflight.sh --dry-run             # prints every command, secrets masked
scripts/testflight.sh --export-only         # archive, export a signed .ipa, verify it, do NOT upload
scripts/testflight.sh                       # archive, export, verify, upload that .ipa with xcrun altool
```

Run `--export-only` first on the first run (setup step 7), then upload. The default build number is the UTC time `YYYYMMDDHHMM`; it only grows, and App Store Connect
refuses a number that is not higher than the last upload of the same version (`--build N` overrides). After the upload,
processing takes a few minutes; then App Store Connect > your app > TestFlight shows the build: answer the export
compliance question if asked (the app uses no non-exempt encryption) and add the internal group. If the altool upload fails
on its flags, `--upload-with xcodebuild` uploads instead, but it signs the package again, so the uploaded file is not the
one the script verified (it warns). Last resort: upload the `.ipa` from `--export-only` with Apple's Transporter app.
Delete `dist/testflight-build` when done: Xcode's own logs in it contain your Team ID.

## Before you send it: checklist

- [ ] The sha256 file matches: `cd dist && shasum -a 256 -c Buddy-<version>.dmg.sha256`.
- [ ] Notarization is stapled and accepted: `xcrun stapler validate dist/Buddy-<version>.dmg` (the script also ran it).
- [ ] Upload the dmg to where colleagues get it (below), then download it **through that host** in a browser on a clean
      macOS user (System Settings > Users & Groups > add a user, log in as it). A browser download carries the quarantine
      flag, so Gatekeeper really checks it; a file copied locally does not.
- [ ] There: verify the checksum, drag to Applications, open. It opens without the Open Anyway step.
- [ ] First launch opens the "Set up Buddy" window with "Connect Buddy to Claude Code" still to do.
- [ ] **Review and install** shows a diff, **Confirm** writes `~/.claude/settings.json` (with a `.buddy-backup-<time>` file)
      and the step gets its check mark. Typing in an open `claude` session turns "Check it works" into "Buddy sees your
      session in <project>." and the session shows up in the menu.
- [ ] An approval end to end: Allow, Deny and Always on the Mac card; then from the iPhone (Deny from the lock screen, Allow
      with Face ID). The menu says "Phone link on". `docs/e2e-checklist.md` lists the rest, with a result column.
- [ ] Open from Downloads: **Move Buddy to Applications?** appears, moving works, and **Open Buddy at login** takes effect.
- [ ] In App Store Connect the TestFlight build is marked **Internal Only** (see "What has never been run", item 6).
- [ ] The TestFlight build installs on an iPhone of a colleague who is an internal tester.

## Where to host the dmg

For preview distribution, use a **private GitHub Release** in the Buddy repository
or a maintainer-approved shared drive. For a release:

```sh
gh release create v<version> dist/Buddy-<version>.dmg dist/Buddy-<version>.dmg.sha256 --draft --title "Buddy <version>"
```

Never make the repository or the download link public. Send colleagues the link and `docs/installing.md`.

## Version and build numbers

- `MARKETING_VERSION` (default in `Apps/project.yml`, override with `--version`) is the version people see. Raise it for
  every dmg you send, and use the same one for the Mac and the iPhone.
- `CURRENT_PROJECT_VERSION` is the build number. Mac: `--build N` (default: the value in `Apps/project.yml`); raise it for each
  release. iPhone: the UTC time by default; never go back to small numbers after using it.
- Updating a colleague's Mac is a new dmg over the old app (`installing.md`, "Update Buddy").

## What has never been run

No signed or notarized build, TestFlight upload or real-device check has run: there was no paid account when this was
written. First real run, expect and check:

1. `release.sh` signed mode: certificate lookup, archive with the Developer ID flow, that the export re-signs the embedded
   `buddy-hook` (the script's pre-notarization checks fail loudly if not), the dmg signature, `notarytool` acceptance, stapling.
   On a fresh team pass `--register-device` once, so the development-signed archive has a profile that lists this Mac.
   Two points are unverified. (a) The archive carries the development cloud entitlements and the Developer ID export is
   expected to write the Production container environment and production push (the script checks both before
   notarization). (b) The export options combine `signingStyle` `automatic` with `signingCertificate` set to
   the resolved SHA-1, but `xcodebuild -help` says `signingCertificate` is for manual signing only, so the SHA-1 may be
   ignored. Task 17 must check that both the app and the dmg are signed by the intended Developer ID certificate (the
   script only checks the authority and the team, not which certificate).
2. `testflight.sh`: that automatic signing with the API key creates the distribution certificate and App Store profile, that
   the exported `.ipa` really has `aps-environment` `production` and the Production container environment (the script checks
   it), and that `xcrun altool --upload-app` accepts the flags (fallback: `--upload-with xcodebuild`).
3. `phone-signed-build.sh`: the device list of a real iPhone (only a simulator was inspected; `--device` bypasses it) and
   `devicectl device install app`.
4. That App Store Connect accepts the upload (icon, privacy answers, export compliance) and processes it.
5. The CloudKit Production schema deploy, and the real iCloud, push and Face ID paths (`docs/e2e-checklist.md`).
6. **`testFlightInternalTestingOnly` is still honoured when uploading with altool.** It used to apply at upload time; now it
   only sits in the export options of a local `.ipa`, and altool has no matching flag. After the first upload, App Store
   Connect must show the build as Internal Only. If it does not, do not add testers: upload with `--upload-with xcodebuild`.
7. The first-run setup window ("Set up Buddy"), the Move to Applications prompt on a real download, and Open at login on a real Mac
   (`docs/e2e-checklist.md` M9 to M11).
8. That Gatekeeper opens the notarized dmg without the Open Anyway step.
