# CloudKit setup (phone link)

Buddy mirrors sessions, pending approvals and pending questions to your iPhone through CloudKit: the **private database** of the
container `iCloud.com.sergeyhovakimyan.buddy`, custom zone `Buddy`. There is no server of ours. Project names, commands and
other sensitive text are stored only as CloudKit **encrypted values**.

The phone link is optional. Without it Buddy works exactly as before on the Mac (menu bar, island card, sounds,
Allow/Deny). The menu and Settings show `Phone link off: <reason>` when it is not running.

## 1. What you need

- A paid Apple Developer Program account (CloudKit and push entitlements are restricted), and its **Team ID**.
- The Mac signed in to iCloud (System Settings > your name). The iPhone signed in to the same Apple ID.
- Xcode signed in to the developer account (Xcode > Settings > Accounts).

Do **not** put your Team ID in the repository. It is passed on the command line (below).

## 2. Apple Developer portal (once)

1. Certificates, Identifiers & Profiles > Identifiers > register (or open) the App ID `com.sergeyhovakimyan.buddy.mac`
   and enable the **iCloud** capability, including **CloudKit**. Enable **Push Notifications** too.
2. Identifiers > iCloud Containers > create the container `iCloud.com.sergeyhovakimyan.buddy`.
3. Back on the App ID, edit iCloud and tick that container.
4. Repeat for the iPhone App ID `com.sergeyhovakimyan.buddy.phone`: enable **iCloud** with **CloudKit** and tick the same container
   `iCloud.com.sergeyhovakimyan.buddy`, and enable **Push Notifications** (see section 8).

Letting Xcode do it also works: with `-allowProvisioningUpdates` (below) automatic signing creates the App ID,
the container and the provisioning profile for you the first time.

## 3. Build a signed Mac app

The default build (`xcodebuild ... build`, no extra arguments) is **ad-hoc signed and has no iCloud entitlements**.
That is deliberate: iCloud entitlements are restricted, and an ad-hoc build that carries them is killed by macOS
at launch. So the iCloud keys live in a second file, `Apps/BuddyMac/BuddyMac.cloud.entitlements`, used only when
you pass `BUDDY_ENTITLEMENTS=...` (a build setting of `project.yml` that feeds `CODE_SIGN_ENTITLEMENTS` of the
`BuddyMac` target only, so the `buddy-hook` helper is not signed with iCloud keys):

```sh
cd Apps
xcodegen
xcodebuild -project Buddy.xcodeproj -scheme BuddyMac -destination 'platform=macOS' \
  BUDDY_ENTITLEMENTS=BuddyMac/BuddyMac.cloud.entitlements \
  DEVELOPMENT_TEAM=<YOUR_TEAM_ID> \
  CODE_SIGN_IDENTITY="Apple Development" \
  -allowProvisioningUpdates \
  -allowProvisioningDeviceRegistration \
  build
```

`BuddyMac.cloud.entitlements` holds: `com.apple.developer.icloud-container-identifiers`
(`iCloud.com.sergeyhovakimyan.buddy`), `com.apple.developer.icloud-services` (`CloudKit`) and
`com.apple.developer.aps-environment` (push; `development`, which Xcode switches to `production` for
distribution signing). Both the push environment and the CloudKit environment follow the **signing and
provisioning** (Apple Development signing talks to the Development CloudKit environment, a distribution-signed
build to Production), not the Release/Debug build configuration. A Developer ID (outside the App Store) build is
the exception: it needs `com.apple.developer.icloud-container-environment` set to `Production` in its
entitlements to use the Production environment. `scripts/release.sh` (signed mode) archives with the cloud file
(development values, as a development-signed archive needs) and exports with the `developer-id` method and the export
option `iCloudContainerEnvironment` `Production`, which writes the container environment `Production` and the
distribution profile's `aps-environment` `production`; the script checks both on the exported app. Hardened runtime is
enabled for that build only; see `scripts/README.md`. So the signed Mac app talks to
the **Production** CloudKit environment: deploy the schema first (section 5) and use a TestFlight (Production)
iPhone build with it. The app stays **not sandboxed**, and hardened runtime stays off in the default build.
Xcode adds the application and team identifiers from the provisioning profile.

Without a team (or without `-allowProvisioningUpdates` and a profile) Xcode refuses the build with
`has entitlements that require signing with a development certificate`: that is the safe failure.

Check what you built:

```sh
codesign -d --entitlements - path/to/BuddyMac.app
```

The default build lists only `com.apple.security.get-task-allow`. The signed build also lists the
`icloud-container-identifiers`, `icloud-services` and `aps-environment` keys.

## 4. First run

Launch the signed app. At start Buddy checks, in this order:

1. the process really has the iCloud/CloudKit entitlement for the container (`CKContainer` is never created
   otherwise, because it would crash an unentitled process). The Mac reads its own signature
   (`SecTaskCopyValueForEntitlement`). iOS has no public API for that, so the iPhone app reads `BuddyCloudKit` from
   its Info.plist: the "Record the CloudKit entitlement" build phase sets it to true only for a code signed build
   whose entitlements file grants CloudKit for `iCloud.com.sergeyhovakimyan.buddy`. Then:
2. `CKContainer.accountStatus() == .available`.

If both pass, the menu says `Phone link on`, the app registers for remote notifications, and the first publish
creates the `Buddy` zone and this Mac's push subscription. In the **Development** environment CloudKit creates the
record types and fields from the first saved records, so there is no schema to author by hand.

If the account check fails for a reason that can change by itself (no iCloud account yet, CloudKit temporarily
unavailable, a timeout), the Mac checks again after 10 s, 30 s, 60 s, 120 s and then every 5 minutes, and turns the
phone link on without a restart once it passes.

## 5. Schema

Created automatically in Development; deploy it to Production before using a build signed for distribution (Developer ID / App Store), which talks to the Production environment. This includes the notarized Mac dmg from `scripts/release.sh` (its Developer ID export sets the container environment to `Production`), so deploy the schema before the first signed release:

CloudKit Dashboard (https://icloud.developer.apple.com) > container `iCloud.com.sergeyhovakimyan.buddy` > Schema >
**Deploy Schema Changes...** (Development to Production). Deploy again whenever a field is added.

All records live in the zone `Buddy` of the **private** database. A record name is unique per zone across record
types, so the names are: `sessionId` for Session, `<requestId>` for Approval, `decision-<requestId>` for Decision,
`<requestId>` for Question, `answer-<requestId>` for Answer. Saving the same record again replaces it (republish is
an upsert); the phone's Decision and Answer are written once and the first one stands.

| Record type | Plain fields | Encrypted fields (`encryptedValues`) |
| --- | --- | --- |
| `Session` | `sessionId` (String), `state` (String: idle, working, waiting, finished, error), `updatedAt` (Date), `agentCount` (Int64, running subagents) | `project` (String), `lastTool` (String, optional) |
| `Approval` | `requestId` (String, UUID), `sessionId` (String), `status` (String: pending, resolved, expired), `createdAt` (Date), `expiresAt` (Date), `isTruncated` (Int(64), 0 or 1) | `tool` (String), `summary` (String) |
| `Decision` | `requestId` (String, UUID), `decision` (String: allow, deny), `decidedAt` (Date), `source` (String: mac, phone) | none |
| `Question` | `requestId` (String, UUID), `sessionId` (String), `status` (String: pending, resolved, expired), `createdAt` (Date), `expiresAt` (Date) | `questions` (Bytes: JSON of the question list, each with text, header, options and multiSelect) |
| `Answer` | `requestId` (String, UUID), `answeredAt` (Date) | `responses` (Bytes: JSON of the chosen option labels, one list per question) |

The Mac applies a Decision only if its `requestId` is currently pending and unexpired in the local queue, always
records it as a phone decision whatever `source` says, and ignores everything else. It applies an Answer only if its
`requestId` is a pending, unexpired question and the labels fit that question's options; anything else is ignored.
Records that cannot be read (malformed JSON, wrong record type, missing fields) are skipped.

Indexes: the subscriptions below need a **Queryable** index on `recordName` for `Question` and `Answer`, like
`Approval` and `Decision` (the Development schema adds it with the first record; add it in the Dashboard under
Schema > Indexes before deploying to Production). Nothing else queries by field: records are read through the zone
change feed.

### Subscriptions and pushes

Fixed subscription IDs, saved idempotently:

- `buddy.approval.created` (saved by the **phone**): `CKQuerySubscription` on `Approval`, fires on creation,
  alert push with category `BUDDY_APPROVAL` and the fixed text "Claude Code needs approval". No command, project or
  other field is ever in the push; the phone app fetches the encrypted record itself.
- `buddy.decision.created` (saved by the **Mac**): `CKQuerySubscription` on `Decision`, fires on creation,
  silent push (`shouldSendContentAvailable`). The app delegate forwards it to the transport, which fetches the zone
  changes. A subscription belongs to the device that saved it, so each device saves its own.
- `buddy.question.created` (saved by the **phone**): `CKQuerySubscription` on `Question`, fires on creation,
  alert push with category `BUDDY_QUESTION` and the fixed text "Claude is asking". No question, option or other
  content is ever in the push; the phone app fetches the encrypted record itself.
- `buddy.answer.created` (saved by the **Mac**): `CKQuerySubscription` on `Answer`, fires on creation, silent push.
  It makes the Mac fetch the zone changes (Decisions and Answers come from the same feed).

Pushes are an accelerator, not a requirement on the Mac: while at least one approval or question is pending and
unexpired the Mac also polls the zone every 4 seconds, so decisions and answers arrive even if pushes do not. The phone refreshes the zone
while its screen is open. If a subscription cannot be saved (push not configured, a missing index) the failure
is logged and records keep flowing; it is retried on a later publish or poll, at most once a minute, until it
succeeds once. Each device's subscriptions are saved independently, so one that cannot be saved yet does not hold
back the other. Known limitation: the approval subscription has no filter on `status` (a filter would need a
Queryable `status` index), so if a retried *pending* publish is replaced on the server by a *resolved* record
that is created fresh, the phone can get one spurious "Claude Code needs approval" alert for it.

### Clean-up

Every minute the Mac deletes Approval, Question, Decision and Answer records and orphaned Session records that the server last
modified more than 20 minutes ago (at most 200 per pass). Sessions the running Mac published are removed only when
the session ends.

## 6. Verify that encrypted fields stay encrypted

1. Run the signed Mac app and start a Claude Code session that asks for a permission, and one that asks you a
   question (the `AskUserQuestion` tool).
2. CloudKit Dashboard > Data > Private Database > zone `Buddy` > record type `Approval`, then `Session`,
   `Question` and (once you answered from the phone) `Answer`.
3. The records exist. `requestId`, `sessionId`, `status`, dates and `isTruncated` are readable. `tool` and
   `summary` (Approval), `project` and `lastTool` (Session), `questions` (Question) and `responses` (Answer) do
   not show their text: the Dashboard cannot decrypt them. If you can read a command, project name, question or
   answer there, stop: a field was written as a plain key (this is covered by
   `CloudKitMappingTests.sensitiveFieldsUseEncryptedValues`).
4. Turn off Wi-Fi on the Mac and trigger another permission request: the island card still works and you can
   answer it on the Mac. The records appear once the network is back (publishes retry with backoff).

## 7. Troubleshooting

| Symptom | Cause and fix |
| --- | --- |
| Menu says `Phone link off: this build is not signed with the iCloud entitlement` | You ran the default ad-hoc build. Build with the `BUDDY_ENTITLEMENTS`, `DEVELOPMENT_TEAM` and `CODE_SIGN_IDENTITY` arguments from step 3. `codesign -d --entitlements -` must list the iCloud keys. |
| `Phone link off: not signed in to iCloud` | Sign the Mac in to iCloud, then restart Buddy. |
| `Phone link off: iCloud is restricted on this Mac` | A profile or Screen Time restriction blocks iCloud. |
| `Phone link off: iCloud check failed (...)` or `temporarily unavailable` | Network or iCloud outage. Buddy checks again on its own (after 10 s, 30 s, 1 min, 2 min, then every 5 min) and turns the link on once iCloud answers. |
| The signed app is killed at launch | The entitlements and the provisioning profile disagree: the container is not ticked on the App ID, or the build was signed ad-hoc with the cloud entitlements. Rebuild with `-allowProvisioningUpdates` and a real team. |
| Phone link is on but the phone sees nothing | Check the Mac log: `log stream --predicate 'subsystem == "com.sergeyhovakimyan.buddy"'`. `notAuthenticated` is an iCloud sign-in problem, `permissionFailure` a container/profile problem. The phone must use the same Apple ID and container. |
| `subscription save failed (will retry later)` in the log, right after the very first run | Expected once in the **Development** environment: a query subscription can only be saved after its record type exists. The Mac's `Decision` and `Answer` types are created by the first decision and the first answer the phone sends, and the phone's `Approval` and `Question` types by the first approval and the first question the Mac publishes; until then the save fails and is retried about once a minute. To avoid the wait, create the record types in the Dashboard (Schema > Record Types) or send one test approval and decision. |
| `subscription save failed (will retry later)` persists | Push is not enabled for the App ID, or the Production schema lacks the record type (deploy it, step 5). If the message mentions an index, add a **Queryable** index on `recordName` for `Approval`, `Decision`, `Question` and `Answer` (Dashboard > Schema > Indexes) and deploy. Records still flow meanwhile; only the push speed-up is missing. |
| Works with an Apple Development signed build, not with a distribution-signed one | The Production schema was not deployed (step 5), or (Developer ID) `com.apple.developer.icloud-container-environment` is not set to `Production`. |

## 8. iPhone app (BuddyPhone)

The iPhone app approves requests remotely: it sees sessions and pending approvals, and sends `Decision` records
(Deny directly, Allow after Face ID / passcode). Same container, same private database, same Apple ID as the Mac.

**App ID.** `com.sergeyhovakimyan.buddy.phone` with iCloud (CloudKit, container `iCloud.com.sergeyhovakimyan.buddy`) and Push
Notifications (section 2). Automatic signing with `-allowProvisioningUpdates` creates these for you.

**Default build has no iCloud.** The simulator or ad-hoc build uses `Apps/BuddyPhone/BuddyPhone.entitlements`, which is
empty on purpose. It launches, shows `iCloud not available: this build is not signed with the iCloud entitlement` and an
empty list, and never touches CloudKit (`CKContainer` would crash an unentitled process).

**Signed build for your iPhone** (the phone connected or selected as destination; pass your Team ID, never commit it):

```sh
cd Apps
xcodegen
xcodebuild -project Buddy.xcodeproj -scheme BuddyPhone \
  -destination 'platform=iOS,id=<YOUR_IPHONE_UDID>' \
  BUDDY_ENTITLEMENTS=BuddyPhone/BuddyPhone.cloud.entitlements \
  DEVELOPMENT_TEAM=<YOUR_TEAM_ID> \
  CODE_SIGN_IDENTITY="Apple Development" \
  -allowProvisioningUpdates \
  -allowProvisioningDeviceRegistration \
  build
```

(or open `Buddy.xcodeproj` in Xcode, set the team on the BuddyPhone target and the `BUDDY_ENTITLEMENTS` build setting to
`BuddyPhone/BuddyPhone.cloud.entitlements`, then Run). `BuddyPhone.cloud.entitlements` holds the iCloud container, the
CloudKit service and `aps-environment`. The iPhone needs iOS 18 or later, the same Apple ID signed in to iCloud, and
Developer Mode on. Check with `codesign -d --entitlements - path/to/BuddyPhone.app`.

The same thing, scripted (`BUDDY_TEAM_ID` in the environment, optional `--device <UDID>` and `--install`, `--dry-run` to
preview): `scripts/phone-signed-build.sh` (see `scripts/README.md`). For TestFlight: `scripts/testflight.sh`. On a fresh
developer account run `scripts/phone-signed-build.sh --register-device` first: a team with no registered device cannot create the
development profile that the archive is signed with.

**First launch.** The app asks for notification permission (allow it), checks the entitlement and iCloud account, then
registers for remote notifications and saves its subscriptions `buddy.approval.created` and `buddy.question.created`. As on
the Mac, in the Development environment each subscription can only be saved once a record of its type exists, so it may take
the first approval or question (and up to a minute) before alerts arrive; opening the app refreshes the list meanwhile.

**Step 4: what to test on the real iPhone** (Mac running the signed BuddyMac, same Apple Account):

1. Start a Claude Code session on the Mac; it appears in the phone's session list (open the app, pull to refresh).
2. Trigger a permission request while the Mac card is not answered: a notification "Claude Code needs approval" arrives
   (no command text in it). Lock the phone, long-press the notification, tap **Deny**: the tool is blocked in the terminal
   without unlocking or opening the app.
3. Trigger another: tap **Allow** on the notification. The app opens on the request; the Allow button becomes active after a
   moment, then Face ID (or passcode) is asked, and only then the tool proceeds. Cancel Face ID once: nothing is sent.
4. Trigger a request with a very long command: the phone shows "Allow on your Mac" (Allow disabled); Deny still works.
5. Let a request expire, or answer it on the Mac first: the phone no longer lists it as pending.
6. Check that the full command is readable (scrolls) and a command containing invisible characters shows `‹U+XXXX›` markers.

**Troubleshooting (phone).**

| Symptom | Cause and fix |
| --- | --- |
| `iCloud not available: this build is not signed with the iCloud entitlement` | You ran the default build. Use the signed build above. |
| `iCloud not available: not signed in to iCloud on this iPhone` | Sign the iPhone in to iCloud, then relaunch Buddy. |
| No alerts, list works | Notifications denied in Settings, Push not enabled on the App ID, or the approval subscription not saved yet (see First launch). |
| Allow does nothing | The Allow button is disabled until a moment after the request appears, for truncated commands, and after expiry. |
