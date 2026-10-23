# Buddy — design spec

> **Note (2026-10-20, Task 18 of the earlier installer plan):** the earlier character and the upstream project's sounds
> this spec reuses were **replaced**: the upstream project's asset licence reserves them, so they could not go into builds
> for colleagues. The island now shows Buddy's own abstract status orb (`Apps/BuddyMac/Orb/`) and plays sounds synthesized
> by `scripts/make-sounds.swift`; code derived from the upstream project's MIT source is listed in a third-party notice.
> The text below is the original design and is kept as written, with the upstream project and its character named
> neutrally.
>
> **Update (2026-10-20):** at the maintainer's request the earlier character and the upstream sounds are **back** for
> testing only, until Buddy's own character and sounds replace them; the orb and the synthesized sounds were removed again.
>
> **Update (2026-10-21):** Buddy's own character (Block) and a CC0 sound set replaced them
> (`docs/superpowers/specs/2026-10-20-character-questions-onboarding-design.md`), the derived code was rewritten, and the
> third-party notice is gone.

Working name: **Buddy**. Internal-use clone of the part of an upstream open-source notch app we need. Reuses its character and sounds (internal use only, not for distribution).

## 1. Goal and success criteria

Know what my running Claude Code terminal sessions are doing, and approve or deny their permission requests, without switching to the terminal. On the Mac that means a notch island with the character. When away from the Mac, it means my iPhone.

Success:
1. A Claude Code session started in any terminal shows up on the Mac island within 1 s, with live state (idle, working, waiting for me, finished, error).
2. A permission request shows an Allow / Deny / Always card on the Mac. Clicking it answers Claude Code with no terminal interaction.
3. The same request reaches my iPhone as an actionable notification. Allow (behind Face ID) or Deny from the phone answers Claude Code.
4. If anything is down (app, CloudKit, phone), Claude Code falls back to its normal terminal prompt. Claude Code is never blocked and nothing is ever allowed without a human decision.

## 2. Scope

In:
- Claude Code only.
- macOS 15+ menu-bar app with notch island (top bar on Macs without a notch).
- The upstream character (SwiftUI drawing code ported from the upstream project) and its sounds.
- iOS 18+ app: session list, approval screen, notification actions.
- Mac to iPhone link through the user's private CloudKit database.

Out (YAGNI): other agents, chat, dictation, integrations, plan usage, wardrobe, roaming desktop character, widgets, Siri, Android, Live Activities / Dynamic Island, terminal jump, `AskUserQuestion` answering (v1 shows the question and falls back to the terminal; can be added later).

## 3. Decisions (from brainstorming)

| Topic | Decision |
|---|---|
| Phone | iPhone, native SwiftUI app |
| Apple account | Paid Apple Developer Program account available |
| Mac to phone link | CloudKit private database, same Apple Account on both devices, no server |
| Native stack | Swift 6, SwiftUI, one shared Swift package |

Rejected: relay server + APNs (more infra and auth work), Tailscale/LAN (no wake-up push).
Because Live Activities are out of scope, no Cloudflare Worker / APNs key is needed (the upstream project needs one only for Live Activity pushes).

## 4. Architecture

```
Claude Code ──hook──▶ buddy-hook ──unix socket──▶ BuddyMac ──CloudKit──▶ BuddyPhone
      ▲                                              │  ▲                    │
      └──────── allow/deny JSON on stdout ◀──────────┘  └──── Decision ◀─────┘
```

### 4.1 `buddy-hook` (relay)
- Registered in `~/.claude/settings.json` for: `SessionStart`, `UserPromptSubmit`, `PreToolUse`, `PostToolUse`, `Notification`, `Stop`, `SessionEnd`, `PermissionRequest`.
- Reads the hook JSON from stdin, forwards it as newline-terminated JSON to the Mac app's Unix socket (`~/Library/Application Support/Buddy/buddy.sock`, mode 0600, owner-only).
- For every event except `PermissionRequest`: forward and exit 0 immediately, printing nothing.
- For `PermissionRequest`: forward, then block until the app replies with a decision or a timeout expires (default 110 s, kept under the hook timeout configured in settings).
  - On `allow` / `always` print `{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}`.
  - On `deny` print the same with `"behavior":"deny"` (plus a short `message`).
  - On anything else (no app, timeout, unknown value, socket error) print nothing and exit 0, so Claude Code asks in the terminal exactly as without Buddy.
  - Rule carried over from the upstream project: nothing that allows is printed without a decision a human clicked.
- Implemented as a single dependency-free script (Python 3 or compiled Swift tool; decided in the plan after checking what ships with macOS 15+).

### 4.2 `BuddyKit` (Swift package, no UI)
- `HookEvent` — typed parse of the hook payload (session id, cwd, tool name, tool input, event name). Unknown or malformed input is dropped, never crashes.
- `SessionStore` — state machine per session: `idle → working → waiting → finished | error`. `finished` shows for 5 s then returns to idle. Sessions are removed on `SessionEnd` or after N minutes (default 30) without events.
- `ApprovalQueue` — pending approvals keyed by `requestId` (UUID assigned by the app). Resolves exactly once (first decision wins). Cancels on timeout, on terminal answer (next `PostToolUse` for that session) and on session end. Stale or duplicate decisions are rejected.
- `ToolSummary` — short, display-safe summary of a tool call (tool name, trimmed command or path). Flags commands too long to show in full (`isTruncated`).
- Protocols `PhoneTransport` (publish sessions and approvals, observe decisions) with a CloudKit implementation in `BuddyMac` and an in-memory fake for tests.

### 4.3 `BuddyMac` (menu-bar app)
- Socket server on the path above; feeds `SessionStore` and `ApprovalQueue`.
- Island window: notch overlay (or top bar on non-notch Macs), hidden when idle, peeks on events. The character drawn with ported SwiftUI Canvas code. Shows per-session row (project from cwd, state, last tool) and the approval card (Allow / Deny / Always). Sounds from the ported `.wav` files (`approval`, `finish`, `error`, etc.).
- "Always" in v1 answers exactly like Allow for the current request. Writing a persistent permission rule into Claude Code is out of scope (matching the upstream project, where "always still answers a plain allow"). The Mac may remember the choice locally per tool and project, but only as a UI convenience, never to auto-allow a later request.
- Hook installer: backs up `~/.claude/settings.json`, merges Buddy's hooks, shows a diff before writing, supports uninstall.
- Phone publisher (4.5).

### 4.4 `BuddyPhone` (iOS app)
- Session list with live state.
- Approval screen showing tool and summary. Allow requires Face ID / passcode; Deny does not. If the command is flagged `isTruncated`, Allow is disabled with "Allow on your Mac".
- Actionable notification (category with Allow / Deny actions) for a new pending approval. Allow from a notification also requires authentication, so it opens the app to the approval screen. Deny can be applied directly.
- Registers for CloudKit subscription pushes.

### 4.5 CloudKit link
- Container in the user's private database. Record types:
  - `Session` (`sessionId`, `state`, `updatedAt`; encrypted: `project`, `lastTool`).
  - `Approval` (`requestId`, `sessionId`, `status` = pending/resolved/expired, `createdAt`, `expiresAt`; encrypted: `tool`, `summary`; `isTruncated`).
  - `Decision` (`requestId`, `decision` = allow/deny, `decidedAt`, `source`).
- Sensitive fields use CloudKit encrypted values, so Apple and the container only hold ciphertext for project names and commands.
- Mac writes `Session` / `Approval`. Phone writes `Decision`. A `CKQuerySubscription` on `Approval` (create) triggers the phone notification; a subscription on `Decision` (create) wakes the Mac.
- Mac applies a decision only if `requestId` is currently pending in the local `ApprovalQueue` and not expired. Everything else is ignored. Decisions are idempotent.
- Old `Approval` / `Decision` / stale `Session` records are deleted by the Mac (TTL cleanup).

## 5. Approval flow (authoritative)

1. Claude Code fires `PermissionRequest`. `buddy-hook` forwards it and blocks.
2. `BuddyMac` assigns `requestId`, enqueues, plays the approval sound, shows the card, and publishes `Approval(pending)`.
3. CloudKit pushes to the phone, which shows the notification.
4. The first decision wins, from the Mac card or the phone `Decision`. The app resolves the queue entry, writes `Approval(resolved)`, tells the hook, which prints the JSON. The card clears on both devices.
5. Fallbacks, all resulting in a silent hook and a terminal prompt:
   - timeout reached, app not running, socket error;
   - CloudKit unavailable (Mac card still works; phone path is skipped);
   - terminal answered first (next `PostToolUse` for the session cancels the entry; card clears);
   - session ended.

## 6. Security and privacy

- Socket is owner-only (0600) under the user's Application Support directory.
- A decision applies only to the exact pending `requestId`; expired, resolved or unknown IDs are dropped.
- No decision means no output from the hook. The hook never prints an allow on its own.
- Face ID / passcode gates every Allow on the phone.
- Project names, commands and paths leave the Mac only as CloudKit encrypted values in the user's own private database. There is no third-party server and no telemetry.
- Installer never overwrites `settings.json` without a backup and a shown diff.

## 7. Error handling

- Malformed hook JSON: ignore the event, log locally.
- App not running: hook exits 0 silently within a short connect timeout (≤ 300 ms) so sessions are not slowed.
- Unreachable CloudKit: queue publishes and retry with backoff; Mac-only operation continues.
- App restart with pending approvals: pending entries are lost; hooks time out and fall back to the terminal.

## 8. Testing

- `BuddyKit` unit tests via `swift test` (no Xcode needed): event parsing, state machine transitions, approval resolve-once, timeout, stale/duplicate rejection, `ToolSummary` truncation.
- Socket server tested with a fake hook client process, including the 300 ms no-app path and the PermissionRequest round trip.
- Hook output tests assert the exact JSON for allow, deny and silence.
- `PhoneTransport` tested with the in-memory fake; CloudKit implementation covered by a manual checklist on a real Mac and iPhone (it needs entitlements and a signed build).
- End-to-end manual checklist for the four success criteria in section 1.
- Installer tested against fixture `settings.json` files (empty, existing hooks, malformed).

## 9. Build order (becomes the task list)

1. Repo setup and `BuddyKit` core (models, event parser, session state machine, approval queue). Pure Swift, buildable with command line tools only.
2. `buddy-hook` and socket server with blocking approval, timeout and fallback.
3. Hook installer (backup, merge, diff, uninstall).
4. `BuddyMac` UI: menu bar, island, character port, sounds, approval card.
5. CloudKit layer: schema, Mac publisher and decision subscriber.
6. `BuddyPhone`: session list, approval screen, Face ID, notification actions.
7. End-to-end hardening: failure drills, README and setup guide.

Steps 1 to 3 do not need Xcode. Steps 4 to 6 need Xcode installed and signed in to the paid Apple Developer account (not present on this machine at the time of writing).

## 10. Open items to settle in the plan

- Hook relay implementation language (Python 3 vs a small Swift executable) given macOS 15+ ships no Python by default.
- Bundle IDs, CloudKit container ID and team ID.
- Final product name.
- Exact default timeouts (hook, session reaping) after checking Claude Code's hook timeout setting.
