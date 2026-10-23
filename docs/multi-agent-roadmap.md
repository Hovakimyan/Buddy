# Multi-agent roadmap

Buddy currently integrates with Claude Code. This document plans local Codex support and sets a repeatable process for adding other coding agents. It is a plan, not a statement that these integrations ship in the current app or dmg.

## Goal and support levels

Keep one Mac menu-bar app, island, approval queue and optional iPhone companion. An agent adapter supplies events and, where its interface permits, returns a human decision. Support is reported per capability instead of calling an agent simply "supported":

| Level | User-visible result |
| --- | --- |
| Observe | Sessions, project, working/waiting/finished state and recent tool activity appear in Buddy. |
| Approve on Mac | Buddy can show the complete request and return Allow or Deny. If Buddy is unavailable or the request cannot be safely displayed, the agent's own approval flow remains available. |
| Approve on iPhone | The same request is mirrored to the phone; the Mac validates the first decision and relays it to the waiting agent. This needs the existing signed CloudKit builds and real-device validation. |
| Agent-specific interactions | Questions, plans, permission modes and other workflows are enabled only when the agent exposes a documented, testable protocol for them. |

The first target is **locally running Codex**, starting with Observe and Approve on Mac. Codex Cloud or remote sessions need a separate transport and are outside this first milestone. The existing Claude integration must keep working throughout.

## Current architecture and seams

- `Sources/BuddyKit/Events/HookEvent.swift` parses Claude's hook JSON directly into the event type used by the engine.
- `Sources/BuddyKit/Socket/HookClient.swift`, `HookSocketServer.swift` and `HookOutput.swift` carry one event over a local Unix socket and return Claude-shaped hook output.
- `Sources/BuddyKit/Engine/BuddyEngine.swift` owns sessions, approvals, questions and the phone bridge.
- `Sources/BuddyKit/Installer/ClaudeSettingsInstaller.swift`, `Sources/BuddyCtl/main.swift` and `Apps/BuddyMac/AppModel.swift` install into `~/.claude/settings.json` and present the reviewable diff.
- `Apps/BuddyMac` and `Apps/BuddyPhone` consume engine snapshots and CloudKit records. Their layout and most decision handling can be shared.

These boundaries suggest a provider adapter at the hook input/output edge, rather than a second engine or a second phone app.

## Codex facts to verify against the installed version

The [OpenAI Docs hook reference](https://learn.chatgpt.com/docs/hooks) documents `SessionStart`, `UserPromptSubmit`, `PreToolUse`, `PermissionRequest`, `PostToolUse`, `Stop` and `SessionEnd`, among other events. Each command hook receives JSON on stdin. `PermissionRequest` can return `allow`, `deny`, or no decision so Codex uses its normal approval prompt. It runs only when Codex is about to ask for approval. Codex hook configuration can live in `~/.codex/hooks.json` or `~/.codex/config.toml`; non-managed hooks require review and trust. Hook coverage has exceptions, so it is not a complete record of every action.

Codex's event names overlap with Claude's, but payloads and response rules differ. In particular, Codex's `PermissionRequest` output does not currently support Claude-style `updatedPermissions` or `interrupt`. A Codex approval must never be encoded by blindly reusing `HookOutput.stdout`. Codex tool names and inputs also need their own display mapping; unknown inputs must be shown in full or made Deny-only. Confirm behavior in both the local Codex CLI and the local Codex app before claiming either surface works.

## Implementation sequence

### 1. Make the provider explicit in BuddyKit

1. Add an `AgentProvider` identity (`claudeCode`, `codex`) and a normalized event type that the engine accepts. Keep the raw provider session ID alongside a namespaced Buddy ID such as `codex:<id>` so simultaneous agents cannot collide in the session store or CloudKit record names. Validate length and allowed characters after namespacing.
2. Keep Claude's existing parser and output encoder as a Claude adapter. Add a Codex parser and output encoder. Each adapter maps its documented events to normalized session changes and approval requests; neither invents events the provider does not emit.
3. Route the decision back through the adapter that created the request. An approval record must carry provider, original request identity, exact displayed tool/input and expiry. Never return a decision for a different or expired request.
4. Add optional provider and capabilities fields to session snapshots and phone records. Handle old records that lack them as Claude sessions. Review CloudKit schema/index changes before a signed release and deploy any new Production schema before TestFlight or notarized builds use it.
5. Show the provider name on Mac and phone session rows and approval cards, including when Claude and Codex sessions run at once. Rename Claude-only setup text where the screen now covers both agents.

### 2. Add Codex's local hook relay

1. Add a Codex command entry point, or a `--provider codex` mode on the existing helper, that reads one Codex hook payload and sends a normalized event to Buddy's owner-only socket. Preserve the existing Claude helper command and wire behavior for installed users.
2. Subscribe to Codex lifecycle events for Observe. Map `SessionStart`/`SessionEnd`, user prompts, tool starts/completions and `Stop` into Buddy states. Explicitly test resume, interruption, multiple turns and concurrent Claude/Codex sessions. Treat tool hooks as partial observation because the documented coverage has exceptions.
3. For `PermissionRequest`, wait for the exact Buddy approval. Encode only Codex's documented Allow/Deny output. Unsafe or truncated text must never be allowed from Buddy; Deny may remain available. On disconnect, timeout, parse error, missing app or unknown decision, produce no decision so Codex keeps its normal prompt. Check the installed Codex version's hook timeout and cancellation behavior with a live local session.
4. Keep Codex questions, plan changes and "Always" unavailable until a documented provider-specific flow is implemented. Do not label an approval as persistent when it only approves one request.

### 3. Add a separate, reversible Codex installer

1. Present a Codex-specific install/update/uninstall diff in Settings and `buddyctl`. Preserve unrelated Codex config and hooks; back up files before writes, as the Claude installer does. Decide between `hooks.json` and inline TOML after testing how the installed Codex version merges active config layers.
2. Install the relay to Buddy's stable support directory and point Codex to that copy, so moving or upgrading the app does not break hooks. Refresh the helper on app update.
3. Explain Codex's hook trust review in setup. A config edit alone is not proof that Codex will run the hook. Show separate status for Claude and Codex, and allow each to be uninstalled independently.
4. Provide test-path overrides for Codex config and Buddy home so installer tests never edit the user's real `~/.codex` or `~/.claude` files.

### 4. Verify, then enable phone approvals

- Unit tests: decode real representative Codex payloads; encode exact Codex Allow/Deny/no-decision outputs; reject malformed, oversized, stale, duplicate and mismatched requests; verify namespace isolation and Claude regression cases.
- Process tests: run the helper against a temporary socket, including no app, late reply, terminal decision first, hook cancellation and two providers at once. Confirm no response is ever interpreted as Allow.
- Live local tests: install hooks in a test Codex configuration, start CLI and app sessions, check the island, approve and deny in Buddy, answer in Codex, quit Buddy mid-request, then uninstall. Record which surface and Codex version were tested.
- Phone tests: only after Mac decisions work, use a signed Mac/phone pair to run the existing real-device checklist with Codex requests. Verify the phone cannot approve a request whose full text was not safely displayed.
- Release gate: all Claude tests and manual flows still pass; docs state exact supported Codex surfaces and capability levels; a new dmg is built and verified. Previously built dmg files remain Claude-only.

## Future agents

Candidates to investigate include Cursor, Gemini CLI, OpenCode and Aider. This is an investigation list, not a claim that any candidate exposes the hooks Buddy needs. Evaluate one agent at a time using this checklist:

1. **Documented local interface:** Can it emit stable session/tool lifecycle events? Can it pause at a real approval and accept an explicit Allow/Deny response? Is there a supported configuration or extension mechanism?
2. **Safe fallback:** If Buddy is absent, slow or crashes, does the agent return to its own human prompt without running the action? Can Buddy correlate and cancel the exact pending request?
3. **Information quality:** Does the request include enough tool/input detail to show exactly what will run? If not, support Observe only, or Deny-only for that request type.
4. **Distribution:** Does the interface work in the user's actual local app/CLI, and can installation be reviewed, backed up, updated and reversed without overwriting other configuration?
5. **Scope and cost:** Estimate adapter code, compatibility maintenance and real-device test effort. Defer agents whose approval interface is undocumented or whose workflow cannot preserve Buddy's fail-safe behavior.

For each candidate, record a dated source link, tested version/surface, capability matrix and a go/no-go decision in this document or a linked adapter note. Prefer a documented event/approval API over scraping terminal output, process titles or private app files. A provider without an approval API may still qualify for Observe, clearly labeled as such.

## Suggested milestones

| Milestone | Done when |
| --- | --- |
| A. Provider model | Claude tests remain green; two providers can coexist without ID collisions in engine snapshots and fake CloudKit. |
| B. Codex Observe | Local Codex sessions and tool activity appear with a Codex label; missing events do not create false "waiting" states. |
| C. Codex Mac approval | Allow, Deny and fallback pass automated and live CLI/app checks; no unsupported persistence or plan behavior is shown. |
| D. Codex install and release | Reviewable install/uninstall, trust instructions, setup UI, regression suite and verified dmg are complete. |
| E. Codex iPhone approval | Signed real-device checklist passes for Codex and Claude on the same account. |
| F. Next agent decision | At least one candidate has a documented capability matrix and a go/no-go decision. |
