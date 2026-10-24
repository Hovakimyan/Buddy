# scripts

The release steps in order, with the one-time Apple setup and the pre-send checklist: [`docs/releasing.md`](../docs/releasing.md).

## release.sh: Mac dmg

```sh
scripts/release.sh                 # unsigned dmg of the version in Apps/project.yml (MARKETING_VERSION)
scripts/release.sh --version 0.2.0 # another version (passed to the build as MARKETING_VERSION)
scripts/release.sh --build 7       # another build number (CURRENT_PROJECT_VERSION)
scripts/release.sh --dry-run       # print the exact commands: builds, writes, mounts nothing, never contacts Apple
scripts/release.sh --help
```

Builds `BuddyMac` in **Release** (own build folder `dist/build`), and writes `dist/Buddy-<version>.dmg` (volume
"Buddy", compressed UDZO, `BuddyMac.app` plus an `Applications` link; `buddy-hook` is embedded in
`Contents/MacOS`) and `dist/Buddy-<version>.dmg.sha256`. `dist/` is git-ignored. Other options: `--unsigned` (force
unsigned even when `BUDDY_TEAM_ID` is set), `--skip-notarize`, `--out-dir DIR`.

### Unsigned (default, works without an Apple account)

Used whenever `BUDDY_TEAM_ID` is unset (or `--unsigned`). The build is ad-hoc signed exactly like the default Xcode
build: no entitlements (so no iCloud, the phone link is off) and no hardened runtime. The dmg is **not notarized**, so
Gatekeeper blocks the first launch on another Mac. On macOS 15 a colleague opens BuddyMac once (macOS blocks it), then
goes to System Settings > Privacy & Security, clicks "Open Anyway" and confirms. Or runs
`xattr -dr com.apple.quarantine /Applications/BuddyMac.app`. The script prints this when it finishes.

### Signed and notarized (UNTESTED until a real Apple Developer account exists)

Written from Apple's documentation, with no account available; verify it for the first time in plan Task 17.
`--dry-run` shows what it would run. In both `--dry-run` and a real run, `release.sh` masks the Team ID and the optional
`BUDDY_ASC_KEY_PATH`, `BUDDY_ASC_KEY_ID` and `BUDDY_ASC_ISSUER_ID` (as `<BUDDY_TEAM_ID>`, `<BUDDY_ASC_KEY_PATH>`, ...) in every
line it prints, relayed tool output included. It uses the same masking and the same key checks as the phone scripts
(`scripts/lib/common.sh`): all three or none, a 10 character key id, a UUID issuer id, a readable non-empty key file, and a
warning when other users can read it.

| Variable | Meaning |
| --- | --- |
| `BUDDY_TEAM_ID` | Team ID (10 characters). Selects signed mode. Environment only, never committed. The script's own output, and the tool output it relays, show it as `<BUDDY_TEAM_ID>` (Xcode's own logs in `dist/build/Logs` may contain it). |
| `BUDDY_SIGN_IDENTITY` | Default `Developer ID Application`. A certificate name or prefix (not a SHA-1: the script resolves the SHA-1 itself). Resolved to exactly one valid certificate of the team (the same certificate in two keychains counts once); zero or several different matches stop the script before building. |
| `BUDDY_NOTARY_PROFILE` | `notarytool` keychain profile (`xcrun notarytool store-credentials <name>`). Required unless `--skip-notarize`. |
| `BUDDY_ASC_KEY_PATH`, `BUDDY_ASC_KEY_ID`, `BUDDY_ASC_ISSUER_ID` | Optional, all three or none: an App Store Connect API key, passed to `xcodebuild` as `-authenticationKeyPath`, `-authenticationKeyID`, `-authenticationKeyIssuerID` (for CI). |

Steps: `xcodebuild archive` (hardened runtime, `BuddyMac.cloud.entitlements`, automatic development signing with the
team; `--register-device` adds `-allowProvisioningDeviceRegistration` so a fresh team registers this Mac), then
`xcodebuild -exportArchive` with a generated `ExportOptions.plist` (method `developer-id`, automatic signing, the team,
`iCloudContainerEnvironment` `Production` and the resolved certificate's SHA-1 as `signingCertificate`; written to a temp
folder, never to git), which should re-sign with Developer ID. Unverified: `xcodebuild -help` says `signingCertificate` is "for manual signing only", so with
`signingStyle` `automatic` the SHA-1 may be ignored and Xcode may pick another Developer ID certificate for the app than the
one that signs the dmg. Plan Task 17 must check that both the app and the dmg are signed by the intended certificate
(the script's checks confirm the authority and the team, not which certificate). The post-build
phase in `Apps/project.yml` signs the embedded `buddy-hook` with hardened runtime and a secure timestamp and no
entitlements (no iCloud keys). Then the dmg is signed, the signatures are checked **before anything is sent to Apple**,
and `xcrun notarytool submit --wait --output-format json` runs; the status must be `Accepted`, otherwise the script
prints `notarytool log` and fails. Last, `xcrun stapler staple` on the dmg. It fails early when the certificate is
missing or ambiguous, the notary profile is missing, or `xcodegen` or `xcodebuild` is.

The archive carries the development values of `BuddyMac.cloud.entitlements` (`aps-environment` `development`, no
container environment), because it is development-signed and a development profile refuses production values (the same
pattern as `testflight.sh`). The Developer ID export writes container environment `Production` (export option) and
`aps-environment` `production` (distribution profile), and the script checks both on the exported app before anything is
sent to Apple. So the notarized Mac app uses the Production CloudKit environment:
deploy the schema first (`docs/cloudkit-setup.md` section 5) and pair it with a TestFlight (Production) iPhone build.
The App ID `com.sergeyhovakimyan.buddy.mac` needs iCloud (container `iCloud.com.sergeyhovakimyan.buddy`) and Push enabled in the
portal; `-allowProvisioningUpdates` then creates the development and Developer ID provisioning profiles.

`-allowProvisioningUpdates` needs credentials: either Xcode signed in to the developer account (Xcode > Settings >
Accounts), or an App Store Connect API key through the `BUDDY_ASC_*` variables above. Without a signed-in account and
without a key, `xcodebuild` fails at the archive step.

Stapling the dmg is Apple's documented flow for a downloadable dmg: Gatekeeper takes the notarization ticket from the
stapled dmg, and the ticket covers the app inside. The app copied out of the dmg has no ticket of its own, so a Mac
that is offline at the first launch relies on the dmg's. Notarizing and stapling the app itself before building the dmg
(zip it, submit, staple) is an optional extra for a fully offline first launch; the script does not do it.

Open points for the first real run: the export may or may not re-sign `buddy-hook` (the pre-notarization checks fail
loudly if it is not Developer ID signed with a secure timestamp); a fresh team has no registered Mac, so the first run
needs `--register-device` (or the Mac added in the developer portal).

Unverified until the first real run: that the Developer ID export really writes `aps-environment` `production` and the
Production container environment (Apple's documented behaviour; the script's checks fail before notarization if not).

### What the script verifies on its own output

Both modes: `codesign --verify --deep --strict` on the app; the embedded `buddy-hook` exists, is executable and
verifies; no Mach-O sits in `Contents/Resources` (a second `buddy-hook` there would be unsigned code that notarization
rejects) and every Mach-O in the bundle passes `codesign --verify --strict`; `CFBundleShortVersionString` (and `CFBundleVersion` with `--build`) match; the sha256 file matches; the dmg
mounts (`hdiutil attach -nobrowse -readonly` at a temp mount point, always detached by a trap) and holds
`BuddyMac.app` and the `Applications` link, and the app inside verifies.

Signed mode, before notarization, on the app and `buddy-hook`: authority Developer ID Application, a secure timestamp,
hardened runtime, `TeamIdentifier` equal to `BUDDY_TEAM_ID` (compared, not printed), no `get-task-allow`; on the app
an embedded provisioning profile (`Contents/embedded.provisionprofile`; without it macOS kills an app with iCloud and push entitlements at launch, while notarization would still accept it), the iCloud container, CloudKit, container-environment `Production` and `aps-environment` `production` entitlements,
and none of the iCloud keys on `buddy-hook`; the dmg's signature and authority. After notarization: `stapler validate`
and `spctl --assess` on the dmg and the app.

## test-release.sh

`scripts/test-release.sh` (a minute or two with the unsigned build on a cold cache, a few seconds with `--skip-build` for the fast checks only) tests `release.sh`: `--help`, an unknown
flag, a bad version or build number, the default version from `project.yml`, the macOS 15 wording, signed-mode early
failures (no certificate, another team's certificate, ambiguous certificates via a fake identities file, a malformed
team id, a partial API key), the signed `--dry-run` output (archive and export commands, the generated plist, that the
Team ID is never printed even inside a full identity name, and that a dry run makes no `xcrun` call, so no contact with
Apple), that the test-only `BUDDY_TEST_IDENTITIES_FILE` seam warns loudly, that the entitlement check is key-specific, the archive entitlements file (development values, no Team ID), `--register-device`, the app's sounds (every file under `Apps/BuddyMac/Resources/sounds/`, except `SOURCES.md`, is listed in `SOURCES.md` on a line
containing `CC0`; every `SoundCue` raw value has a 16-bit PCM file under 1.5 s in `sounds/block`), and the full unsigned build with the checks above re-asserted
independently (including that the app carries the sounds and `SOURCES.md`), and `check-names.sh` on the tree and on the
built app. It
writes only to a temp folder (detaching its own mount in its trap; `TMPDIR` points inside it too, so xcodebuild leaves no
`.lock` files in the real `TMPDIR`), launches and installs nothing, and uses no real
identity. `shellcheck` runs when it is installed.

## phone-signed-build.sh: signed BuddyPhone on your iPhone (for developers)

```sh
export BUDDY_TEAM_ID=<your team id>          # required, never committed
scripts/phone-signed-build.sh --dry-run      # print the exact commands; touches no device and not Apple
scripts/phone-signed-build.sh                # build for the first connected iPhone
scripts/phone-signed-build.sh --device <UDID> --install   # a specific phone, and install the app on it
```

A development build of `BuddyPhone` with the iCloud, CloudKit and push entitlements
(`BuddyPhone/BuddyPhone.cloud.entitlements`, override with `BUDDY_ENTITLEMENTS`), automatic signing with your team and
`-allowProvisioningUpdates`; it is the scripted form of "Signed build for your iPhone" in `docs/cloudkit-setup.md`
section 8. The device is `--device UDID` or, without it, the first physical, non-simulated iPhone that
`xcrun devicectl list devices` reports (a connected, paired one first; otherwise a paired one that is not connected; an
unpaired one never). The build goes to `dist/phone-build`. Afterwards it checks the
signed app (`codesign --verify --deep --strict`, an embedded provisioning profile, `TeamIdentifier` equal to your team, the
iCloud container, CloudKit and `aps-environment` entitlements, `BuddyCloudKit` true in the Info.plist, the version and build
number). `--install` then runs
`xcrun devicectl device install app --device <UDID> <app>`. Other options: `--register-device` (adds
`-allowProvisioningDeviceRegistration`: lets xcodebuild register a new device in your developer account, so it is opt-in),
`--version`, `--build`, `--out-dir`. On a fresh developer account run it with `--register-device` first: a team with no
registered device cannot create the development profile, and then neither the phone build nor the TestFlight archive works.

## testflight.sh: archive, export and upload to TestFlight

```sh
export BUDDY_TEAM_ID=<your team id>
export BUDDY_ASC_KEY_PATH=<path to AuthKey_XXXXXXXXXX.p8> BUDDY_ASC_KEY_ID=<key id> BUDDY_ASC_ISSUER_ID=<issuer id>
scripts/testflight.sh --dry-run              # print the exact commands, secrets and Team ID masked
scripts/testflight.sh --export-only          # archive + export a signed .ipa into dist/, verify it, do NOT upload
scripts/testflight.sh                        # archive, export, upload; the build number is the UTC time
scripts/testflight.sh --build 12 --version 0.2.0
scripts/testflight.sh --upload-with xcodebuild   # fallback upload path, see below
```

**Order on a fresh developer account.** Apple creates the development provisioning profile the archive is signed with only
when the team has at least one registered device; otherwise the archive fails with "Your team has no devices from which to
generate a provisioning profile". So, in this order:

1. Accept the current agreements (App Store Connect and the developer portal).
2. Connect your iPhone and run `scripts/phone-signed-build.sh --register-device` (or add the device in the developer portal).
3. Run `scripts/testflight.sh --export-only` (creates the App ID and profiles, checks the exported `.ipa`).
4. Create the app record for `com.sergeyhovakimyan.buddy.phone` in App Store Connect > Apps (it needs the App ID from step 3).
5. Deploy the CloudKit schema to Production (`docs/cloudkit-setup.md` section 5), then run `scripts/testflight.sh`, then add the
   internal testers in TestFlight.

Steps of the script: `xcodegen generate`; `xcodebuild archive` (Release, `generic/platform=iOS`, automatic signing with the team,
`BuddyPhone.cloud.entitlements`, the version and build number); checks of the archived app (bundle id, version, build number,
the app icon, `Assets.car`, signature, team, iCloud entitlements, `BuddyCloudKit` true: nothing is exported if one fails); `xcodebuild -exportArchive`
with an `ExportOptions.plist` generated into a temp folder (never into git): method `app-store-connect`, `destination` `export`
(a local `.ipa`), the team, `signingStyle` `automatic` (Xcode creates the cloud-managed distribution certificate and App Store
profile), `iCloudContainerEnvironment` `Production`, `testFlightInternalTestingOnly` (the build can only go to internal testers:
preview testers, never external or public), `manageAppVersionAndBuildNumber` `false` (your build number is the one
uploaded), `uploadSymbols`; then the exported `.ipa` is unpacked and **always** checked: signature, team, `aps-environment`
`production`, `icloud-container-environment` `Production`, no `get-task-allow`, iCloud entitlements, version, build number;
only then is it uploaded (not with `--export-only`).

**The app icon check.** On iOS, Xcode writes the icon name only inside `CFBundleIcons` > `CFBundlePrimaryIcon` >
`CFBundleIconName` of `Info.plist` (checked against a real `iphoneos` build; the top-level `CFBundleIconName` is the macOS
layout), so the archive check reads `CFBundleIcons:CFBundlePrimaryIcon:CFBundleIconName` and expects `AppIcon`, and a top-level
key does not count. `Assets.car` must be in the app too.

**Why export first, then upload the same bytes.** Uploading with the export option `destination` `upload` would sign and upload
in one step, so nothing could be checked in between. The script exports to a local `.ipa`, verifies that file, and uploads exactly
that file with `xcrun altool --upload-app -f <ipa> --api-key <id> --api-issuer <issuer> --p8-file-path <key>` (the flags are the
ones `xcrun altool --help` of this Xcode, 27.1, documents). What is uploaded is what was verified. Those altool flags have never
run against a real account, so `--upload-with xcodebuild` is the fallback: it runs the export a second time with `destination`
`upload` (documented in `xcodebuild -help`), after the same verification of the first export. The second export is signed again by Xcode, so that path verifies
the first export, not the bytes it uploads; the script prints a warning saying so, and `--help` says it too. If both fail, upload the `.ipa` from `--export-only`
with Apple's Transporter app.

**When the export or the upload fails** the script prints hints, with every secret masked: (1) no App Store Connect app record
for the bundle id ("No suitable application records were found": create it in App Store Connect > Apps, after the App ID exists;
`--export-only` first); (2) the license agreements are not accepted; (3) the API key role cannot create distribution certificates
and profiles ("Cloud signing permission error": use an Admin key); (4) the build number is not higher than the last upload of that
version; (5) the team has no registered device (`phone-signed-build.sh --register-device`).

**Logs and temp files.** Xcode writes its own logs and plists into `dist/testflight-build` (archive, `export/` with the
`xcodebuild` logs, `ExportOptions.plist`, `DistributionSummary.plist`), and those contain your Team ID. The folder is git-ignored
and the script makes it private to your user (`chmod 700`); delete it when you are done (`rm -rf dist/testflight-build`). The
scripts' own temp folder (mode 0700: the generated `ExportOptions.plist`, the unpacked `.ipa`) is deleted when the script exits.

**Build numbers.** Without `--build` the build number is the UTC time `YYYYMMDDHHMM`, which only grows (App Store Connect refuses a
number that is not higher than the previous upload of the same version). Do not go back to small numbers after using the time
scheme.

**Phone entitlements.** There is no phone release entitlements file because none is needed, not because the phone is
different. `BuddyPhone.cloud.entitlements` asks for `aps-environment` `development` and has no container-environment key, which
is right for the development-signed archive. The App Store export signs again with the distribution profile; Xcode then
writes `aps-environment` `production`, drops `get-task-allow`, and the CloudKit environment is Production (the export option
`iCloudContainerEnvironment` `Production` says so explicitly). That is Apple's documented behaviour, but it has not been seen
here, which is why the exported `.ipa` is always checked for exactly these values before it is uploaded. The Mac's
`release.sh` follows the same pattern (development values at archive, Production at the Developer ID export). TestFlight builds use the Production CloudKit environment, so
deploy the schema first (`docs/cloudkit-setup.md` section 5) and pair them with the notarized Mac build (`release.sh`).

### Variables (both scripts)

| Variable | Meaning |
| --- | --- |
| `BUDDY_TEAM_ID` | Required. Team ID (10 characters). Environment only, never committed; masked as `<BUDDY_TEAM_ID>` in all output (any letter case), including relayed `xcodebuild` output. |
| `BUDDY_ASC_KEY_PATH`, `BUDDY_ASC_KEY_ID`, `BUDDY_ASC_ISSUER_ID` | The App Store Connect API key (App Store Connect > Users and Access > Integrations; use an Admin key: other roles often cannot create the cloud-managed distribution certificate). `testflight.sh`: all three required unless `--export-only`. `phone-signed-build.sh`: all three or none (without it, Xcode must be signed in to the developer account). Passed to `xcodebuild` as `-authenticationKeyPath/-authenticationKeyID/-authenticationKeyIssuerID`. All three are masked in output. The key file is only passed by path, never read or printed; the script checks that it exists, is a readable non-empty file, and warns when other users can read it (no warning for owner-only modes such as 400 or 600). |
| `BUDDY_ENTITLEMENTS` | Entitlements file relative to `Apps/` (default `BuddyPhone/BuddyPhone.cloud.entitlements`). |

Both scripts: `--dry-run` never calls `xcodegen`, `xcodebuild` or `xcrun`, never lists devices and never contacts Apple; a
missing prerequisite (tool, key file) is shown as a warning there and is an error in a real run, before anything is built. The
shared helpers (masking, checks) live in `scripts/lib/common.sh`.

### What is verified and what is not

Verified here (no account, no device): `bash -n`, `--help`, argument errors, missing and malformed environment, the key file
checks, the exact dry-run commands, the generated `ExportOptions.plist` (valid plist, right keys), the masking of the Team ID and
the three key values, device selection from `devicectl`-shaped JSON (simulators, iPads, unavailable and unpaired devices
skipped), the order of the steps with fake tools, and that a failed verification stops before any export, upload or install: with
fakes that produce a real zipped, ad-hoc signed `.ipa` (production and bad variants), so the verification, the checks and the
upload ordering really run. `scripts/test-phone.sh`. The app icon wiring was built for both platforms (the Mac app has
`AppIcon.icns`; the iPhone app declares `AppIcon` under `CFBundleIcons` > `CFBundlePrimaryIcon`, as a real `iphoneos` build of
`BuddyPhone` shows).

NOT verified (needs a developer account, an iPhone and App Store Connect; plan Task 17): that automatic signing creates the App
ID, profiles and the cloud-managed distribution certificate with the API key; the `devicectl list devices` JSON of a real
physical iPhone (only a simulator entry could be inspected; `--device` bypasses it); `devicectl device install app`; that the
exported `.ipa` really carries `aps-environment` `production` and the Production container environment (the script checks it; use `--export-only` first);
that `xcrun altool --upload-app` with these flags works (the flags come from `xcrun altool --help`; `--upload-with xcodebuild` is the
fallback); that the upload is accepted (the App Store Connect app record for `com.sergeyhovakimyan.buddy.phone` must exist; icon, export compliance
(`ITSAppUsesNonExemptEncryption` is `false`) and privacy answers); that `testFlightInternalTestingOnly` is still honoured when the verified
`.ipa` is uploaded with altool (it used to apply at upload time; now it only sits in the export of a local `.ipa`, and altool has no
matching flag). First-run check: after the first upload, App Store Connect must show the build as **Internal Only**; if it does not, upload
with `--upload-with xcodebuild`.

## test-phone.sh

`scripts/test-phone.sh` (under a minute) tests `phone-signed-build.sh`, `testflight.sh`, `scripts/lib/common.sh` and the
app icons with **fake** `xcodegen`, `xcodebuild`, `xcrun` (devicectl, altool) and a `codesign` shim on `PATH`. Nothing
contacts Apple, no device and no account are needed, the Team ID and key values are made up, `HOME` points to a temp folder, and
everything is written to a temp folder. The fake build and archive make an ad-hoc signed stand-in app whose `Info.plist` is a copy
of the one a real `iphoneos` build of BuddyPhone produced (`scripts/testdata/BuddyPhone.Info.plist`; never invent that layout
again). The fake export makes a real zipped `.ipa` (`Payload/BuddyPhone.app`, signed again ad hoc with chosen entitlements), so
every verification step runs for real. The `codesign` shim runs the real `codesign` but reports a `TeamIdentifier`, which an ad-hoc
signature cannot carry. Good runs pass every check; negative variants fail the right check and stop before the upload: an icon
missing or only at the top level, the wrong team, `aps-environment` `development`, no container environment, `get-task-allow`, the
wrong build number, no `.ipa`, a failing unpack, plus failed archive, export and upload with their hints. It also covers the
symlink and `CDPATH` lookup of the scripts' own folder, the key file permission warning and the build number against the UTC
clock.

## check-names.sh: no outside names

`scripts/check-names.sh [path/to/BuddyMac.app]` searches, case-insensitively, for the names of the project Buddy was
cloned from, of its character and of its author (the author's surname, with or without its accent, only when no letter
comes right before it, so "braille" is not a match; the patterns are in the script):

- every tracked file (`git ls-files`): its path, and its contents (text files line by line, other files byte by byte);
- with an app: every file name in the bundle; the raw bytes of every file in it (resources, `Info.plist` files,
  executables, nested bundles, frameworks and plug-ins); every `Info.plist` again as XML; and the constants each Mach-O
  file builds in its code (arm64 `mov`/`movk` and x86_64 `mov` immediates, decoded from `otool -tv` for every
  architecture). That last pass is needed because Swift keeps a string literal of up to 15 bytes inside the
  instructions, where a byte search cannot see it.

It does not read UTF-16 or compressed text (binary `.strings` files, compressed PNG text chunks). It exits 1 and lists
every match, 0 when there is none, 2 on a usage error. While the repo folder's own name still matches, lines that
contain it are ignored, and the script says so; once the folder is renamed nothing is ignored. The script holds the
patterns and skips its own file. `test-release.sh` runs it on the tree and on the app it builds (the app check takes
about half a minute). Read-only.

## App icons

Both app icons are Block, the character, drawn by the same code as the island (`Apps/Shared/Characters/Block/`): idle,
on a night background with a soft glow. `Apps/BuddyMacTests/AppIconArtTests.swift` writes them into the asset catalogs
`Apps/BuddyPhone/Assets.xcassets` (one 1024 px universal icon, no alpha channel, as App Store Connect requires for
TestFlight) and `Apps/BuddyMac/Assets.xcassets` (the usual 16 to 1024 px macOS sizes, a rounded square with transparent
margins). The PNGs and `Contents.json` files are committed, so nobody needs to run it again. `Apps/project.yml` wires them
with `ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon`.

### Changing the app icon

Change the colours or the character's state at the top of `AppIconArtTests.swift`, then run it (it does nothing unless
asked):

```sh
cd Apps && TEST_RUNNER_BUDDY_WRITE_ICONS=1 xcodebuild -project Buddy.xcodeproj -scheme BuddyMac \
  -destination 'platform=macOS' test -only-testing:BuddyMacTests/AppIconArtTests
```

Or overwrite the PNGs by hand: the iPhone one full bleed (no rounded corners) and with **no transparency**.
