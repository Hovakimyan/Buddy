# Apps

Xcode layer for Buddy. All logic lives in the `BuddyKit` Swift package (repo root `Package.swift`); this
folder only holds the app targets. The Xcode project is generated and git-ignored.

## Generate and build

```sh
brew install xcodegen          # once
cd Apps
xcodegen                       # writes Apps/Buddy.xcodeproj (git-ignored)
xcodebuild -project Buddy.xcodeproj -scheme BuddyMac -destination 'platform=macOS' build
xcodebuild -project Buddy.xcodeproj -scheme BuddyMac -destination 'platform=macOS' test
xcodebuild -project Buddy.xcodeproj -scheme BuddyPhone -destination 'platform=iOS Simulator,name=<a simulator you have>' test
open Buddy.xcodeproj           # or work in Xcode
```

Targets (`project.yml`):

- `BuddyMac`: menu-bar app (`LSUIElement`), bundle ID `com.sergeyhovakimyan.buddy.mac`, macOS 15, Swift 6 strict concurrency.
- `BuddyHook`: the `buddy-hook` relay (same sources as the SwiftPM executable), built with the app.
- `BuddyPhone`: the iPhone approver, bundle ID `com.sergeyhovakimyan.buddy.phone`, iOS 18, Swift 6 strict concurrency (see "iPhone app" below).
- `BuddyPhoneTests`: unit tests for the phone model, notification routing, the approval screen's rules and the launch selection. Like
  `BuddyMacTests` they are **not hosted**: they compile `BuddyPhone/*` (minus `BuddyPhoneApp.swift`), `Shared/*` and `SharedTests/*`.
- `BuddyMacTests`: unit tests for `AppModel`, the CloudKit mappings and transport. They are **not hosted** by the app: they compile `BuddyMac/*`
  and `Shared/*` (minus `BuddyMacApp.swift`) directly, so running tests never launches the app or opens the real socket.
  Everything the tests touch is in temp directories.

## Embedded hook binary

The build copies `buddy-hook` to `BuddyMac.app/Contents/MacOS/buddy-hook` (a post-build script phase in
`project.yml`, ad-hoc or identity signed like the app). In `Contents/MacOS`, not `Resources`, so it is signed as
code. The `BuddyHook` dependency has `embed: false`: without it XcodeGen also adds "BuddyHook in Resources", a second, unsigned
copy in `Contents/Resources` that notarization would reject. `scripts/release.sh` and `scripts/test-release.sh` fail when any
Mach-O sits in `Contents/Resources` or any Mach-O in the bundle does not pass `codesign --verify`.

"Install hooks" in Settings first copies it to `~/Library/Application Support/Buddy/bin/buddy-hook`
(mode 0755, staged then moved into place, via `HookBinaryInstaller` in BuddyKit, shared with `buddyctl`) and only
then patches `~/.claude/settings.json` (backup kept next to it). Claude Code runs the copy in Application Support,
not the one inside the app bundle, so the app can be moved or rebuilt without breaking the hooks.

## Downloaded-app polish

`BuddyMac/Install/` holds the small pieces that make a downloaded `.app` work without developer knowledge. Each decision is
pure or takes injected locations and is unit-tested; the AppKit parts (the alert, the relaunch) are thin glue.

- **Hook copy refresh** (`HookCopyRefresh`): at launch, when the settings file has Buddy's hooks, they run
  `Application Support/Buddy/bin/buddy-hook`, no other Buddy is running, and the bundled `buddy-hook` differs from that copy, it
  is re-copied (staged, atomic). It never edits `settings.json`, never installs hooks that are not installed, and Settings
  shows a one-line result (including why it skipped).
- **Setup steps** (`Setup/SetupSteps`, `Setup/SetupWindow`): a window listing what to do after installing (move to
  Applications, connect to Claude Code, open sessions pick it up, check it works, optional iPhone in CloudKit builds, open
  at login), each with a check once done. It opens on the first launch (`UserDefaults` `setup.windowShown`, set when the
  window actually appears), whenever the hooks are outdated, and from the menu's "Setup steps…" (a dot while a required
  step is left). The project of the first hook event is remembered (`setup.seenEventProject`) so "Check it works" stays
  done. It installs nothing itself: "Review and install" shows the same diff and Confirm as Settings.
- **Launch at login** (`LaunchAtLogin`): a Settings toggle over `SMAppService.mainApp` behind the `LoginItemService` protocol,
  showing the status macOS reports (enabled, needs approval in System Settings, not found) and any error. The model's test
  initializers default to an inert login item; only the app passes `SystemLoginItem`.
- **Move to Applications** (`MoveToApplications`, `LaunchCoordinator`): from outside `/Applications` and `~/Applications`
  (Downloads, a disk image, an AppTranslocation path) Buddy offers once per launch to copy itself to `/Applications` and
  reopen from there. It is skipped when any `BUDDY_*` variable is set, under tests, and for Xcode builds (`DerivedData`,
  `Build/Products`). A translocated app is judged by its original location (`Translocation`). If another Buddy (same bundle id)
  is running, the alert says it will be quit; accepting quits it and waits up to 10 s, and if it stays the move is abandoned. The
  copy is staged and loses `com.apple.quarantine` (the running app already passed Gatekeeper), then a helper opens it only after
  this process has exited, so the new instance finds the socket free (and does nothing if the process never exits). Declining or
  a failure keeps the app running.
- **Overrides:** with any `BUDDY_*` variable set (`LaunchEnvironment`) the login item and the setup memory are inert (in
  memory only), so a safe manual run registers and consumes nothing real. With `BUDDY_HOME` set the user's sounds folder is
  `$BUDDY_HOME/Sounds`, so such a run never reads the real one. The model's test initializers are inert by default too.

`LaunchCoordinator` runs the move offer and the setup window once from the menu bar label (the one view that exists at launch), the move offer
first, so an instance that moves itself leaves the setup window for the copy. The setup window's first step offers the same move again.

## Signing and the phone link (CloudKit)

There is no Apple Developer team in the repository, so the default build is "to run locally": `CODE_SIGN_IDENTITY: "-"`
(ad-hoc) and an empty `DEVELOPMENT_TEAM`. The app is deliberately **not sandboxed** (it writes
`~/.claude/settings.json` and a socket under Application Support; an internal tool, never for the App Store) and hardened
runtime is off.

The default build has **no iCloud entitlements** (`BuddyMac/BuddyMac.entitlements` is empty on purpose): iCloud is
a restricted entitlement and macOS kills an ad-hoc app that carries it. The app checks its own entitlements at
launch, and without them runs Mac-only with `Phone link off: ...` in the menu and Settings. Nothing else changes.

To get the phone link, build a signed app and opt in to the second entitlements file (never hardcode the team):

```sh
xcodebuild -project Buddy.xcodeproj -scheme BuddyMac -destination 'platform=macOS' \
  BUDDY_ENTITLEMENTS=BuddyMac/BuddyMac.cloud.entitlements \
  DEVELOPMENT_TEAM=<YOUR_TEAM_ID> CODE_SIGN_IDENTITY="Apple Development" \
  -allowProvisioningUpdates build
```

`BuddyMac.cloud.entitlements` carries the container `iCloud.com.sergeyhovakimyan.buddy`, the CloudKit service and
`aps-environment` (push). Portal setup, schema deployment, field table and troubleshooting:
[`docs/cloudkit-setup.md`](../docs/cloudkit-setup.md).

To package a dmg for colleagues (unsigned by default; signed and notarized once an account exists) use
[`scripts/release.sh`](../scripts/README.md); the whole release flow is in [`docs/releasing.md`](../docs/releasing.md).

`Shared/` holds what both apps use: the CloudKit transport (CloudKit + Foundation only, no AppKit/UIKit), the iCloud
entitlement and account checks (`CloudAvailability.swift`), the hidden-character sanitizer `DisplayText` and the
Allow arming delay `Arming`. Tests of `Shared/` code live in `SharedTests/` and run in both test targets. Tests run the
transport against an in-memory fake database; nothing in the test suite creates a `CKContainer`.

## iPhone app (BuddyPhone)

Session list (pending approvals on top, then sessions with state, last tool and time) and an approval screen that shows
the tool, the whole command (scrollable, hidden/bidi/lookalike characters shown as `‹U+XXXX›` markers, the same sanitizer
as the Mac card), an expiry countdown, **Deny** and **Allow**. Rules, enforced in `PhoneModel` and unit-tested:

- Allow is disabled for the first 0.7 s after the request appears on screen (stray-tap guard, same as the Mac); after
  that it needs a tap and then Face ID / device passcode (`LAContext .deviceOwnerAuthentication`) **every time**. Deny
  needs no authentication and is never delayed. After the Face ID prompt returns, the request is checked again: if it
  expired, was answered, became too long to read in full, or was republished with a different tool or text, nothing is
  sent.
- A command flagged `isTruncated` cannot be allowed here ("Allow on your Mac"); Deny works.
- An expired, resolved or already answered request is never offered; expiry is re-checked against the clock on every
  read and again after the Face ID prompt returns. A decision names exactly the displayed request id.
- Notification category `BUDDY_APPROVAL` (registered at launch): **Deny** runs in the background (no `.foreground`, no
  unlock needed): the app is woken, takes the request id from the push (the CloudKit record name), fetches the Approval,
  checks it is still pending and unexpired, then submits the Decision. The app holds a background-task assertion until the
  Deny has gone out, polling for the request with a pause that grows from 0.1 s to 1 s. If the Deny cannot be sent it posts
  a generic local notification, "Could not deny — answer on your Mac" (nothing of the command). **Allow** opens the app on that request
  (`.foreground`, `.authenticationRequired`) and the Face ID flow runs there. The push text is generic; it never carries the
  command or project.

Entitlements follow the Mac's pattern. The default build (simulator or ad-hoc) has **empty** entitlements
(`BuddyPhone/BuddyPhone.entitlements`) and runs with the status `iCloud not available: this build is not signed with the iCloud
entitlement` and an empty list. A signed device build opts in with
`BUDDY_ENTITLEMENTS=BuddyPhone/BuddyPhone.cloud.entitlements` (iCloud/CloudKit container `iCloud.com.sergeyhovakimyan.buddy`, push);
see `docs/cloudkit-setup.md` section 8. At launch the app uses CloudKit only when the process really has the entitlement and
the iCloud account is available (checked against a 3 s deadline); otherwise it shows the reason. A timeout or a
temporarily unavailable account is checked again each time the app returns to the foreground; "not signed in",
"restricted" and "no entitlement" are final until the app is relaunched.

`BuddyKit` builds for iOS: the hook socket, engine and installer files are `#if os(macOS)`.

## Safe local runs

The app honours the same overrides as `buddyctl`, so a trial run does not touch your real Claude setup. Like `buddyctl`, it needs
`BUDDY_SETTINGS` and `BUDDY_HOME` both or neither: with only one, install and uninstall refuse and the menu says why.

```sh
open -n --env BUDDY_SOCKET=/tmp/buddy-try.sock \
        --env BUDDY_SETTINGS=/tmp/buddy-try/settings.json \
        --env BUDDY_HOME=/tmp/buddy-try/home \
        path/to/BuddyMac.app
```

Without them it listens on `~/Library/Application Support/Buddy/buddy.sock` and reads (never writes, until you
confirm an install) `~/.claude/settings.json`.

## Island

`BuddyMac/Island/` is the notch overlay: a borderless, non-activating panel above the menu bar (at the notch when
the screen has one, a centred bar at the top otherwise). It never takes focus, so a permission request is answered
without leaving the terminal. It is hidden when every session is idle (no panel at all), peeks (clicks pass through)
when a session works, waits, finishes or fails, and opens with the approval card when a request is pending.
`IslandLogic`, `IslandGeometry` and `SoundTrigger` are pure and unit-tested; the panel code is thin glue.
Allow and Always both allow only the current request. A command too long to show in full cannot be allowed from the
card ("Allow in terminal"); the terminal prompt answers it. The same goes for a command with any character outside the
allowlist (`DisplayText.isPlainReadable`, in `Shared/`: keycap emoji, Hebrew, Arabic, arrows, symbols, rare scripts ...),
whose rendered width has not been measured or which can reorder the line; the iPhone uses the same rule ("Allow on
your Mac"). Deny always works.

The bar shows the character, **Block** (`Shared/Characters/Block/`, drawn in code; the iPhone app shows it too). The sounds
(`BuddyMac/Resources/sounds/block/`) are CC0 files, each listed with its source in `BuddyMac/Resources/sounds/SOURCES.md`.
The notch placement and screen choice (`IslandGeometry.swift`), the panel set-up (`IslandWindowController.swift`) and the
sound player (`SoundPlayer.swift`) are Buddy's own code, like everything else here.

Render snapshots: run the tests with the variable in xcodebuild's environment (the `TEST_RUNNER_` prefix passes it on to the
tests) to also write PNGs of the character, the bar and the cards:

```sh
TEST_RUNNER_BUDDY_SNAPSHOT_DIR=/some/dir xcodebuild -project Buddy.xcodeproj -scheme BuddyMac -destination 'platform=macOS' test
```

## Not done yet

- The iPhone app has only run in the simulator (no iCloud, no push, no Face ID hardware); the real-device check is Step 4 in
  `docs/cloudkit-setup.md` section 8.
- The CloudKit link is implemented and unit-tested but not yet run against real iCloud (needs a signed build; see
  the manual check in `docs/cloudkit-setup.md`).
- Hardened runtime and notarization are written into `scripts/release.sh` but have never run with a real Apple account; the
  default build has neither. The setup window and the move prompt have not been seen on a real downloaded copy.
