# Buddy

Buddy shows what your running Claude Code terminal sessions are doing and lets you approve or deny their permission
requests without switching to the terminal. On the Mac it is a menu-bar app with a notch island, where Block, a small
character, shows what each session is doing, and cards let you answer permission requests, Claude's questions and
its plans. Away from the Mac, an iPhone app shows the same permission requests and questions and answers them. Built by Sergey Hovakimyan.

If anything is down (the app, iCloud, the phone), Claude Code falls back to its normal terminal prompt. Buddy never
blocks Claude Code and never allows anything without a human decision.

Built by [Sergey Hovakimyan](https://github.com/Hovakimyan). [GitHub repository](https://github.com/Hovakimyan/Buddy) · [LinkedIn](https://www.linkedin.com/in/hovakimyanserg).

## Install

- **Preview testers:** [`docs/installing.md`](docs/installing.md). Download the dmg (Mac) and accept the TestFlight
  invite (iPhone). No Xcode needed.
- **Maintainers (building and sending a release):** [`docs/releasing.md`](docs/releasing.md). Apple setup, `scripts/release.sh`,
  `scripts/testflight.sh`, and what to check before sending.
- **Developers (build from source):** the next section.

**Distribution.** Preview builds are shared by the maintainer. The current TestFlight export supports internal testers; public distribution is not yet available.

**Status.** The unsigned dmg is built and checked by the scripts' tests. A signed and notarized dmg, the TestFlight upload,
the real iPhone link, the first-run setup window, the Move to Applications prompt on a real download and Open at login on
a real Mac have never run on a real Apple account or device;
[`docs/releasing.md`](docs/releasing.md) lists what to verify on the first real run.

**Marketing site.** The responsive landing page lives in [`website/dist/`](website/dist/) and has a
[private preview](https://buddy-companion.hovakimyan-serg.chatgpt.site). It uses an illustrative product demo, not
screenshots of a signed iCloud build. To view it locally, run `python3 -m http.server 8765 --directory website/dist`
from the repository root and open `http://127.0.0.1:8765/`.

## For developers: build from source

### Quick start (Mac, about 10 minutes)

This gets the menu bar app, the notch island and Allow / Deny on your Mac. No Apple Developer account is needed. The
iPhone link is optional and comes after (see "Add the iPhone" below).

1. **Install the tools** (once):
   - macOS 15 or later.
   - Xcode from the App Store. Open it once and accept the license, then check that `xcodebuild -version` works.
   - XcodeGen: `brew install xcodegen`.
   - Claude Code (`claude` works in your terminal).
2. **Get the code**:

   ```sh
   git clone <this repository's URL> buddy
   cd buddy
   ```

3. **Build the Mac app**:

   ```sh
   cd Apps
   xcodegen generate
   xcodebuild -project Buddy.xcodeproj -scheme BuddyMac -destination 'platform=macOS' -derivedDataPath build build
   ```

   It ends with `** BUILD SUCCEEDED **`. The app is `Apps/build/Build/Products/Debug/BuddyMac.app`. It is ad-hoc signed,
   which is fine on the Mac that built it. Buddy does not offer to move a build made by Xcode into Applications; it stays
   where it was built.
4. **Start it**: `open build/Build/Products/Debug/BuddyMac.app`. There is no Dock icon; look for the paw-print icon in
   the menu bar. The menu says `Phone link off: ...`. That is expected until you add the iPhone.
5. **Install the hooks** (this edits your Claude Code settings; a backup is kept): paw-print menu bar icon > **Open Settings** >
   **Install hooks…**. Read the diff, then **Confirm**. Buddy copies its `buddy-hook` to
   `~/Library/Application Support/Buddy/bin/` and adds its hook entries to `~/.claude/settings.json` (backup:
   `settings.json.buddy-backup-<time>`). Your other settings and hooks stay as they are.
6. **Start `claude`** in any terminal. Claude sessions that are already open pick up Buddy within a few seconds; if one
   does not show up, quit it (`/exit`) and run `claude --continue` to pick up where you were. The session shows up in the
   menu bar and, while it works, in the notch island.
7. **Try it**: ask Claude to do something that needs permission (for example "create a file called hello.txt here").
   The approval card opens at the notch with the tool and the command:
   - **Allow** or **Always** lets this one request run. **Deny** blocks it. The first answer wins, and the terminal prompt
     goes away.
   - Allow is disabled for a moment after the card appears, and for commands that are too long or contain unusual
     characters. Answer those in the terminal ("Allow in terminal"). Deny always works.
   - If you do nothing, or Buddy is not running, Claude Code asks in the terminal as usual.
8. **Keep it running**: Buddy must be running to answer. Turn on **Open Buddy at login** in Settings (macOS may ask you to
   allow it in System Settings > General > Login Items); otherwise start it again after a restart of the Mac (step 4).
   A downloaded copy (Downloads, a disk image) offers to move itself to `/Applications`; the installed hooks do not depend
   on where the app is. After you update the app, it refreshes its installed `buddy-hook` copy at launch by itself.

To stop using Buddy: **Open Settings > Uninstall hooks…** (see "Uninstall" below).

To send Buddy to colleagues instead, build a dmg with `scripts/release.sh` (see [`docs/releasing.md`](docs/releasing.md)).

#### Add the iPhone (optional)

You need a paid Apple Developer Program account and its Team ID, an iPhone on iOS 18 or later with Developer Mode on, and
the same Apple Account signed in to iCloud on the Mac and the iPhone. Xcode must be signed in to the developer account
(Xcode > Settings > Accounts). Never commit your Team ID; pass it on the command line.

1. Replace the Mac app with a signed build (from `Apps/`; `-allowProvisioningUpdates` lets Xcode create the App ID, the
   iCloud container and the profiles the first time, and `-allowProvisioningDeviceRegistration` adds this Mac or the
   iPhone to your team when it is new there, which a development profile needs):

   ```sh
   xcodebuild -project Buddy.xcodeproj -scheme BuddyMac -destination 'platform=macOS' -derivedDataPath build \
     BUDDY_ENTITLEMENTS=BuddyMac/BuddyMac.cloud.entitlements \
     DEVELOPMENT_TEAM=<YOUR_TEAM_ID> CODE_SIGN_IDENTITY="Apple Development" \
     -allowProvisioningUpdates -allowProvisioningDeviceRegistration build
   ```

   Quit Buddy, run it again from the same path (`open build/Build/Products/Debug/BuddyMac.app`). The menu now says
   `Phone link on`. If it still says `Phone link off: ...`, the reason is in the message; see
   [`docs/cloudkit-setup.md`](docs/cloudkit-setup.md), section 7.
2. Build and install the iPhone app on your phone (connect it, find its id with `xcrun devicectl list devices`):

   ```sh
   xcodebuild -project Buddy.xcodeproj -scheme BuddyPhone -destination 'platform=iOS,id=<YOUR_IPHONE_UDID>' \
     BUDDY_ENTITLEMENTS=BuddyPhone/BuddyPhone.cloud.entitlements \
     DEVELOPMENT_TEAM=<YOUR_TEAM_ID> CODE_SIGN_IDENTITY="Apple Development" \
     -allowProvisioningUpdates -allowProvisioningDeviceRegistration build
   ```

   Or open `Apps/Buddy.xcodeproj` in Xcode, pick the BuddyPhone scheme and your iPhone, set the team and the
   `BUDDY_ENTITLEMENTS` build setting as above, and press Run.
3. Open BuddyPhone on the iPhone and **allow notifications**. There is no pairing code: the Mac and the iPhone find each
   other through your private iCloud database. Your Mac's sessions appear in the list (pull to refresh).
4. Trigger a permission request on the Mac and leave the card unanswered. The iPhone gets "Claude Code needs approval".
   Long-press it and tap **Deny** (works from the lock screen), or tap **Allow**, which opens the app and asks for Face ID
   or your passcode first.
5. Walk through [`docs/e2e-checklist.md`](docs/e2e-checklist.md) once. It lists what software could not check (real push,
   Face ID, the notch, sounds). Until it is done, treat the phone link as unverified. The first push subscription can
   take until the first request exists, and up to a minute, before alerts arrive.

## How it works

```
Claude Code ──hook──▶ buddy-hook ──unix socket──▶ BuddyMac ──CloudKit──▶ BuddyPhone
      ▲                                              │  ▲                    │
      └──────── allow/deny JSON on stdout ◀──────────┘  └──── Decision ◀─────┘
```

Claude Code runs `buddy-hook` for its hook events. The hook forwards each event as one line of JSON to a Unix socket
owned by the Mac app and exits at once. For a permission request it then waits (up to 110 s) for a decision: the app
shows an Allow / Deny / Always card, mirrors the request to the iPhone through your private CloudKit database, and the
first decision wins. The hook prints the decision as JSON for Claude Code; for anything else (no app, timeout, an
unknown reply) it prints nothing, so Claude Code asks in the terminal. A request expires after 105 s, a few seconds
before the hook stops waiting.

The code lives in a Swift package (`BuddyKit`: events, session state, the approval queue, the socket server and client,
the engine, the phone bridge, the settings installer) plus two executables, `buddy-hook` and `buddyctl`. `Apps/` holds
the Xcode layer: `BuddyMac` (menu bar, island, the Block character, sounds), `BuddyPhone` (iOS) and `Shared/` (the
CloudKit transport). See `Apps/README.md` for the layout and `docs/superpowers/specs/2026-10-19-buddy-design.md` for the design.

## Requirements

- macOS 15 or later, Xcode with Swift 6, and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).
- Claude Code.
- For the iPhone link only: a paid Apple Developer Program account, an iPhone on iOS 18 or later with Developer Mode on,
  and the same Apple Account signed in to iCloud on both devices.

## Build

Package (hook, `buddyctl`, tests; no Xcode project needed):

```sh
swift build -c release     # builds buddy-hook and buddyctl into .build/release
swift test
```

Apps:

```sh
cd Apps
xcodegen generate          # writes Apps/Buddy.xcodeproj (git-ignored)
xcodebuild -project Buddy.xcodeproj -scheme BuddyMac -destination 'platform=macOS' build
xcodebuild -project Buddy.xcodeproj -scheme BuddyMac -destination 'platform=macOS' test
xcodebuild -project Buddy.xcodeproj -scheme BuddyPhone -destination 'platform=iOS Simulator,name=<a simulator you have>' test
```

The default builds are ad-hoc signed and have no iCloud entitlements: the Mac app works fully on its own and shows
`Phone link off: ...`; the iPhone app launches and shows why iCloud is not available.

## Install the hooks

Buddy adds its hooks to `~/.claude/settings.json`. It keeps a timestamped backup (`settings.json.buddy-backup-<time>`)
next to the file and leaves your other settings and hooks alone. The app shows the diff and waits for your confirmation;
`buddyctl` prints the diff and, only with `--apply`, writes it in the same step.

- From the app: run BuddyMac, open the paw-print menu bar icon > **Open Settings** > **Install hooks…**, read the diff, **Confirm**.
  The app first copies its `buddy-hook` to `~/Library/Application Support/Buddy/bin/buddy-hook`, so the hooks keep
  working if you move or rebuild the app.
- From the terminal, after `swift build -c release`:

  ```sh
  .build/release/buddyctl install-hooks            # dry run: prints the diff only
  .build/release/buddyctl install-hooks --apply    # prints the diff, copies buddy-hook, writes settings.json (no prompt)
  ```

Sessions that are already open pick up Buddy within a few seconds (if one does not, `/exit` it and run
`claude --continue`); the sessions appear in the island and the menu.

## Signed build and the iPhone link (CloudKit)

The phone link needs signed builds with iCloud, CloudKit and push entitlements, an App ID and container in the Apple
Developer portal, and a deployed schema for distribution-signed builds. Never commit your Team ID: pass it on the
command line. Everything is in [`docs/cloudkit-setup.md`](docs/cloudkit-setup.md): portal setup, the signed Mac build,
the schema, subscriptions, troubleshooting and the iPhone app (section 8).

## Pairing the iPhone

There is no pairing code. Sign the Mac and the iPhone in to the same Apple Account, run the signed BuddyMac (the menu says
`Phone link on`) and the signed BuddyPhone (allow notifications). Both use the private database of the container
`iCloud.com.sergeyhovakimyan.buddy`, so the phone sees the Mac's sessions and approvals. If iCloud is off or times out at launch,
the iPhone app checks again when you bring it back to the foreground. The Mac checks once at launch: restart it after
signing in to iCloud.

## Security model

- The hook socket is owner-only (mode 0600, in a 0700 directory) under `~/Library/Application Support/Buddy`.
- A decision applies only to the exact pending request id. Expired, already answered, duplicate and unknown ids are
  dropped, and a phone decision is always recorded as coming from the phone.
- No decision means no output from the hook. The hook never prints an allow on its own.
- Face ID or the device passcode gates every Allow on the iPhone, after a short arming delay, and the request is checked
  again once the prompt returns. Deny needs no authentication.
- A command too long to be shown in full cannot be allowed from the card or the iPhone; answer it in the terminal.
  Deny still works. Hidden and look-alike characters in commands are shown as `‹U+XXXX›` markers.
- The Mac card and the iPhone offer Allow only when every character of the command, as shown, is on an allowlist:
  printable ASCII, newline and tab, Latin, Greek and Cyrillic letters, common punctuation, kana, CJK, Hangul, emoji, and
  a few combining accents on a letter. Anything else (Hebrew or Arabic letters, which can reorder a line on screen
  without any control character, keycap emoji, arrows, symbols, other scripts) means Deny only; allow it in the
  terminal.
- Project names, commands and paths leave the Mac only as CloudKit encrypted values in your own private database. There
  is no server of ours and no telemetry. The notification text is fixed ("Claude Code needs approval") and never carries
  the command or project.
- The installer never changes `settings.json` without a backup. The app shows the diff and writes only after you confirm;
  `buddyctl --apply` prints the diff and writes in one step, so run it without `--apply` first to review.
- The app is not sandboxed (it writes `~/.claude/settings.json` and a socket under Application Support). Release builds are
  meant to be Developer ID signed with hardened runtime and notarized (`scripts/release.sh`, never yet run on a real
  account); the unsigned test dmg and source builds are ad-hoc signed and need Open Anyway on another Mac.
- Move to Applications copies the app only after you click **Move to Applications**. If an older Buddy is running it says so
  and quits that one first (its waiting approvals fall back to the terminal); if it does not quit within 10 seconds, nothing
  is moved. Launch at login registers Buddy only when you turn the toggle on, and macOS can ask you to approve it.

## Uninstall

1. Remove the hooks: BuddyMac paw-print menu bar icon > Open Settings > **Uninstall hooks…** > Confirm, or `.build/release/buddyctl
   uninstall-hooks --apply` (run without `--apply` first to see the diff). Only Buddy's entries are removed; a backup is kept.
2. Turn off **Open Buddy at login** in Settings, then **Quit Buddy** from the menu and delete the app (`BuddyMac.app`, in
   Applications for a downloaded copy).
3. Optionally delete `~/Library/Application Support/Buddy` (the copied hook binary and the socket). Uninstalling the
   hooks leaves that folder in place; it is harmless without hook entries.
4. Optionally remove Buddy from the iPhone (and TestFlight). The CloudKit data is in your private database. The Mac's clean-up
   (records older than about 10 minutes) only runs while the Mac app is running, so after you quit it, delete the
   records or the `Buddy` zone in the CloudKit Dashboard.

The colleague version is in [`docs/installing.md`](docs/installing.md).

## Testing

`swift test` runs the package tests, including failure drills that run the real `buddy-hook` binary against a real
engine on a temporary socket. The two `xcodebuild ... test` schemes run the app tests. Tests use temporary paths and an
in-memory fake of CloudKit; they never touch `~/.claude`, `~/Library/Application Support/Buddy` or iCloud. What software
cannot check (notch, sounds, Face ID, push, real iCloud) is in [`docs/e2e-checklist.md`](docs/e2e-checklist.md), with a
blank result column for you to fill in.

For a safe manual run, `buddyctl` and the app honour `BUDDY_SOCKET`, `BUDDY_SETTINGS` and `BUDDY_HOME` (see
`Apps/README.md`). `buddyctl` requires `BUDDY_SETTINGS` and `BUDDY_HOME` together or not at all.

## Known limitations

- Claude Code only.
- [Multi-agent roadmap](docs/multi-agent-roadmap.md) plans local Codex support first and defines how to evaluate other coding agents. The current app and dmg do not include those integrations.
- Plans (`ExitPlanMode`) are answered on the Mac only; the iPhone shows the session as waiting. Questions
  (`AskUserQuestion`) show on the Mac and the iPhone, but a typed answer ("Other...") is Mac only. A question goes
  to the terminal on **Answer in terminal** or Escape while its card shows, when it is not answered in about 2
  minutes, when "Answer Claude's questions in Buddy" is off in Settings, or when the Mac screen is locked or asleep
  and the phone link is down. It also goes there, with no card, when Buddy cannot show it: outside 1-4 questions or
  2-4 options per question, a header over 12 characters, or a blank or repeated question or option label.
- **Always** answers exactly like Allow for the current request. Buddy writes no permission rules into Claude Code.
- Pending approvals are lost when the app quits or restarts; the hooks then fall back to the terminal.
- The CloudKit link and the iPhone app are unit-tested against fakes. The real iCloud, push and Face ID paths are checked
  with the manual checklist; until that is done, treat them as unverified.
- In the CloudKit Development environment, the first push subscription can fail until the first records exist
  (`docs/cloudkit-setup.md`, section 7). The iPhone may rarely get one spurious alert for a request that was already
  answered.
- iPhone only (no iPad, Android, widgets or Live Activities), macOS 15 and iOS 18 or later.
- A downloaded unsigned test dmg is not notarized, so its first open needs System Settings > Privacy & Security > Open
  Anyway (or `xattr -dr com.apple.quarantine /Applications/BuddyMac.app`), and it has no phone link (no iCloud entitlement).
  The signed, hardened and notarized build, the TestFlight upload, the real iPhone link, the first-run setup window, the
  Move to Applications prompt on a real download and Open at login on a real Mac have never run on a real Apple account or
  device.
- Updating is a new dmg over the old app. Quit Buddy first, or open the new copy from the dmg or Downloads and accept the
  move: it then quits the older running copy for you (after you confirm).
- One Mac per Apple Account. Two Macs on the same account delete each other's older Session records, so the iPhone
  shows sessions coming and going.
- Quitting Buddy can leave session rows on the iPhone until the Mac app runs again and cleans them up. Approvals are
  hidden on the iPhone at their expiry time in any case.
- The Mac republishes a session's record to CloudKit on each of its events. That is fine for testing; the rate (and
  the iPhone's battery use) still has to be tuned against real CloudKit.
- A failed publish to CloudKit is retried for about 7 s (after 1, 2 and 4 s), then dropped until the next change.

## Artwork and licences

**Artwork.** The Block character is drawn in code (`Apps/BuddyMac/Characters/Block/`). The placeholder app icons
(`scripts/make-icons.swift`) and the menu-bar icon (the SF Symbol `pawprint`) are Buddy's own.

**Sounds.** Every bundled sound is a CC0 1.0 (public domain) file; each one's source pack and original file are listed in
[`Apps/BuddyMac/Resources/sounds/SOURCES.md`](Apps/BuddyMac/Resources/sounds/SOURCES.md).

**Code.** All of Buddy's code is its own.

**Git history.** Earlier commits still hold artwork and sounds from before Buddy had its own. The history is replaced by
a single commit of the current tree before the repository goes anywhere. Builds made from the tree (dmg, TestFlight)
contain none of them.
