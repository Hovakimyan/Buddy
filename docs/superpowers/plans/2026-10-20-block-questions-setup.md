# Block character, question answering, setup steps (phase A) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give Buddy its own lively character ("Block") and CC0 sounds behind a swappable character/sound layer, a full island, answering of Claude's `AskUserQuestion` on Mac and iPhone, a plan card for `ExitPlanMode`, a demo, a first-run steps window, and remove every outside asset and mention.

**Architecture:** Pure logic (hook replies, relay `--ask`, question parsing and answers, installer groups, session activity, character-state resolution, engine queues, phone records) lives in `BuddyKit` and is tested with `swift test`. The Mac app gets a character contract (`BuddyCharacter`) with Block as its first implementation, a sound layer keyed by `SoundCue`, an island state machine, cards, demo and setup window. The phone gets `Question`/`Answer` CloudKit records and a question screen behind Face ID.

**Tech Stack:** Swift 6, SwiftUI, AppKit (`NSPanel`, Carbon `RegisterEventHotKey`), AVFoundation, CloudKit, LocalAuthentication, Swift Testing, XcodeGen.

**Spec:** `docs/superpowers/specs/2026-10-20-character-questions-onboarding-design.md` (phase A = sections 3 to 9; section 13 is a later plan).

## Global Constraints

- macOS 15+, iOS 18+, Swift 6, existing layout (`Sources/BuddyKit`, `Apps/BuddyMac`, `Apps/BuddyPhone`, `Apps/Shared`). Generated project: `cd Apps && xcodegen generate`.
- Tests never touch the real `~/.claude/settings.json` or `~/Library/Application Support/Buddy`; use temporary directories, as existing tests do.
- Nothing is pushed. The Team ID is never committed.
- Every commit message ends with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
- The relay prints nothing unless a person chose. Existing approval rules stay (arming delay, "cannot allow what you cannot read", first decision wins, phone input untrusted).
- Exact JSON for allow, deny, plan and answer outputs is pinned by tests.
- Timeouts: question open in the engine 120 s; relay `--ask` wait 125 s; settings hook timeout for the ask group 130 s; other groups unchanged (5 s, PermissionRequest 120 s).
- Do not read the previous character's code, the earlier upstream project's source, or git history when writing new code; work from the spec, Apple's documentation and this plan.
- No mention of another product or its character in app strings, code, comments, file names, tests, scripts or docs written by this plan.
- Test commands:
  - Package: `swift test --filter <Suite>` (repo root); all: `swift test`.
  - Mac: `cd Apps && xcodegen generate && xcodebuild -project Buddy.xcodeproj -scheme BuddyMac -destination 'platform=macOS' -derivedDataPath build test -only-testing:BuddyMacTests/<Suite>`.
  - Phone: same with `-scheme BuddyPhone -destination 'platform=iOS Simulator,name=iPhone 18 Pro' -only-testing:BuddyPhoneTests/<Suite>`.
  - Scripts: `scripts/test-release.sh`, `scripts/test-phone.sh`.

## Review Focus

1. A forged or stale phone record: a `Decision` for a plan approval, or an `Answer` with a label not among the options, a wrong question count, or after expiry. Expected: ignored, nothing printed for it, card stays. Tests in Tasks 6 and 7.
2. The `*` PreToolUse group fires for the same `AskUserQuestion` call without `--ask`. Expected: that relay returns at once and the engine does not cancel the waiting ask for the same call. Tests in Tasks 2 and 6.
3. Malformed questions: 0 or 5 questions, 1 or 5 options, header of 13 characters, empty label, two questions with the same text. Expected: no card, the hook prints nothing. Test in Task 3.
4. The person interrupts in the terminal (the ask hook's connection closes) or the app quits while an ask waits. Expected: the card clears, the relay prints nothing, nothing crashes. Tests in Tasks 2 and 6.
5. A settings file already holding someone else's `AskUserQuestion` PreToolUse group. Expected: Buddy adds its own group and leaves theirs untouched; uninstall removes only Buddy's. Test in Task 4.

---

### Task 1: Hook replies and outputs

**Files:**
- Create: `Sources/BuddyKit/Socket/HookReply.swift`
- Modify: `Sources/BuddyKit/Socket/HookOutput.swift`, `Sources/BuddyKit/Socket/HookSocketServer.swift` (`HookWire`)
- Test: `Tests/BuddyKitTests/HookOutputTests.swift`, `Tests/BuddyKitTests/HookSocketTests.swift`

**Interfaces:**
- Produces:
  - `public enum PlanChoice: String, Codable, Sendable { case change, acceptEdits, askEachTime }`
  - `public enum HookReply: Sendable, Equatable { case decision(Decision); case plan(PlanChoice); case answers([String: String]) }`
  - `HookOutput.stdout(for reply: HookReply?, event: HookEvent) -> String?` (replaces `stdout(for: Decision?)`; update callers)
  - `HookWire.replyLine(for: HookReply) -> Data`; `HookWire.reply(fromReply: Data) -> HookReply?`; `HookWire.maxReplyBytes = 64 * 1024`
  - Wire lines: `{"decision":"allow"|"deny"}`, `{"plan":"<rawValue>"}`, `{"answers":{...string values...}}`.

- [ ] **Step 1: Write failing tests** in `HookOutputTests`:
  - `allowAndDenyUnchanged`: exact existing strings for `.decision(.allow)` / `.decision(.deny)`.
  - `planAcceptEdits`: `== #"{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow","updatedPermissions":[{"type":"setMode","mode":"acceptEdits","destination":"session"}]}}}"#`
  - `planAskEachTime`: same with `"mode":"default"`.
  - `planChange`: `== #"{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"deny","message":"The user wants to change the plan and will type the changes in the terminal.","interrupt":true}}}"#`
  - `answersEchoQuestions`: for an event whose `toolInput` is `{"questions":[Q]}`, parse the output JSON and assert `hookSpecificOutput.hookEventName == "PreToolUse"`, `permissionDecision == "allow"`, `updatedInput.questions` equals the input's `questions` value exactly, `updatedInput.answers == {"Which?":"A, B"}`.
  - `answersWithoutQuestionsPrintNothing`: event with no `questions` key → nil.
  - `nilPrintsNothing`.
  - In `HookSocketTests`: `replyRoundTrip` for each case; `oversizeOrUnknownReplyIsNoReply` (`{"decision":"maybe"}`, `{"plan":"x"}`, `{"answers":{"a":1}}`, 64 KiB + 1 bytes → nil).
- [ ] **Step 2: Run** `swift test --filter HookOutputTests` and `--filter HookSocketTests`. Expected: FAIL (missing types).
- [ ] **Step 3: Implement.** Build the answers JSON with `JSONSerialization` from `JSONValue` (keys need not be sorted; tests compare parsed JSON). Server/engine handler type becomes `(HookEvent) async -> HookReply?`; `BuddyEngine.handle` wraps today's `Decision` in `.decision`.
- [ ] **Step 4: Run** `swift test`. Expected: all PASS.
- [ ] **Step 5: Commit** `git commit -m "Hook replies for plans and answers"`.

### Task 2: Relay `--ask` and waiting asks on the socket

**Files:**
- Modify: `Sources/BuddyHook/main.swift`, `Sources/BuddyKit/Socket/HookClient.swift`, `Sources/BuddyKit/Socket/HookSocketServer.swift`, `Sources/BuddyKit/Events/HookEvent.swift`
- Test: `Tests/BuddyKitTests/HookEventTests.swift`, `Tests/BuddyKitTests/HookSocketTests.swift`, `Tests/BuddyKitTests/BuddyHookProcessTests.swift`

**Interfaces:**
- Consumes: Task 1 `HookReply`, `HookOutput.stdout(for:event:)`.
- Produces:
  - `HookEvent.isAsk: Bool` (from top-level `"buddy_ask": true`; anything else false).
  - `HookEvent.waitsForReply: Bool` = `name == .permissionRequest || isAsk`.
  - `HookClient.run(input:socketPath:ask: Bool = false, connectTimeout:waitTimeout:)`; `HookClient.askWaitTimeout: TimeInterval = 125`.
  - `buddy-hook --ask` passes `ask: true`.

- [ ] **Step 1: Write failing tests:**
  - `HookEventTests.buddyAskParsed`: `"buddy_ask":true` → `isAsk`; `"buddy_ask":"yes"` / absent → false.
  - `HookSocketTests.askWithoutFlagNeverWaits`: PreToolUse `AskUserQuestion` sent with `ask: false` returns nil within 1 s even when the handler would answer after 3 s, and the line the server received has `isAsk == false` even if stdin contained `"buddy_ask":true` (relay strips it).
  - `askFlagOnOtherToolDoesNotWait`: `ask: true` with tool `Bash` → no wait, `isAsk == false`.
  - `askRoundTrip`: `ask: true`, tool `AskUserQuestion`, handler returns `.answers(["Q":"A"])` → stdout is the Task 1 answers JSON.
  - `askClientHangUpCancelsHandler`: client closes while waiting → handler task cancelled (as for permission requests).
  - `BuddyHookProcessTests.askProcessPrintsNothingWithoutApp`: run the real binary with `--ask`, no socket → exit 0, empty stdout, under 1 s.
- [ ] **Step 2: Run** `swift test --filter HookSocketTests` etc. Expected: FAIL.
- [ ] **Step 3: Implement.** Relay decodes stdin as `JSONValue`; when `ask && name == .preToolUse && toolName == "AskUserQuestion"` set `buddy_ask` true and use `askWaitTimeout`, otherwise remove `buddy_ask` before sending. Server routes `waitsForReply` events down the existing permission path (concurrent, hang-up watcher); others stay ordered.
- [ ] **Step 4: Run** `swift test`. Expected: PASS.
- [ ] **Step 5: Commit** `"buddy-hook --ask waits for an answer"`.

### Task 3: Question model, validation and answers

**Files:**
- Create: `Sources/BuddyKit/Questions/AskQuestion.swift`, `Sources/BuddyKit/Questions/AskAnswers.swift`
- Test: `Tests/BuddyKitTests/AskQuestionTests.swift`

**Interfaces:**
- Produces:
  - `public struct AskOption: Codable, Sendable, Equatable { label: String; description: String? }`
  - `public struct AskQuestion: Codable, Sendable, Equatable { text: String; header: String; options: [AskOption]; multiSelect: Bool }`
  - `AskQuestion.parseSet(toolInput: JSONValue?) -> [AskQuestion]?` (reads `questions[].question`, `.header`, `.options[].label`, `.options[].description`, `.multiSelect`)
  - `public enum QuestionResponse: Sendable, Equatable { case options([String]); case text(String) }`
  - `AskAnswers.build(questions: [AskQuestion], responses: [QuestionResponse], allowFreeText: Bool) -> [String: String]?`

- [ ] **Step 1: Write failing tests:**
  - `validSetParses` (1 and 4 questions, descriptions optional, `multiSelect` absent → false).
  - `invalidSetsRejected`: 0 or 5 questions; 1 or 5 options; empty question text; empty label; header of 13 characters (header of exactly 12 accepted); two questions with the same text; `questions` not an array; non-bool `multiSelect`.
  - `singleSelectAnswer`: `["Format?": "Dot"]`.
  - `multiSelectJoinsInOptionOrder`: options A,B,C, response `.options(["C","A"])` → `"A, C"`.
  - `freeTextOnlyWhenAllowed`: `.text("x")` → value `"x"` with `allowFreeText: true`, nil with false; empty/whitespace text → nil.
  - `invalidResponsesRejected`: wrong response count; unknown label; empty selection; two labels on a single-select question; duplicate label.
- [ ] **Step 2: Run** `swift test --filter AskQuestionTests`. Expected: FAIL.
- [ ] **Step 3: Implement** (pure functions; no trimming of labels beyond the empty check).
- [ ] **Step 4: Run** again. Expected: PASS.
- [ ] **Step 5: Commit** `"Parse and answer AskUserQuestion"`.

### Task 4: Installer ask group and install status

**Files:**
- Modify: `Sources/BuddyKit/Installer/ClaudeSettingsInstaller.swift`
- Test: `Tests/BuddyKitTests/ClaudeSettingsInstallerTests.swift`

**Interfaces:**
- Produces:
  - `public enum HookInstallStatus: Sendable, Equatable { case notInstalled, outdated, current }`
  - `ClaudeSettingsInstaller.status(existing: Data?) -> HookInstallStatus` (outdated = some Buddy entries but no Buddy `AskUserQuestion` group with `--ask`, or a Buddy PermissionRequest timeout under 120).
  - `planInstall` also writes `{"matcher":"AskUserQuestion","hooks":[{"type":"command","command":"<hookCommand> --ask","timeout":130}]}` under `PreToolUse`; `planUninstall` removes it.

- [ ] **Step 1: Write failing tests:** `installAddsAskGroup` (exact group dictionary); `installOnOldInstallUpgrades` (old 10-event install → adds ask group, `changed == true`, second plan `changed == false`); `othersAskGroupUntouched` (a foreign `AskUserQuestion` group with command `other-tool` survives install and uninstall); `uninstallRemovesAskGroup`; `statusValues` (empty → notInstalled; old install → outdated; PermissionRequest timeout 60 → outdated; fresh install output → current; malformed → notInstalled).
- [ ] **Step 2: Run** `swift test --filter ClaudeSettingsInstallerTests`. Expected: FAIL.
- [ ] **Step 3: Implement.** Recognise Buddy's ask entry with `isBuddyCommand` on the command minus a trailing ` --ask`.
- [ ] **Step 4: Run** again. Expected: PASS.
- [ ] **Step 5: Commit** `"Installer: AskUserQuestion group and install status"`.

### Task 5: Session activity and character state

**Files:**
- Modify: `Sources/BuddyKit/Sessions/Session.swift`, `Sources/BuddyKit/Sessions/SessionStore.swift`, `Sources/BuddyKit/Phone/PhoneBridge.swift`
- Create: `Sources/BuddyKit/Character/CharacterState.swift`
- Test: `Tests/BuddyKitTests/SessionStoreTests.swift`, `Tests/BuddyKitTests/CharacterStateTests.swift`, `Tests/BuddyKitTests/PhoneBridgeTests.swift`

**Interfaces:**
- Produces:
  - `public enum SessionActivity: String, Sendable { case none, thinking, searching, rateLimited, asking }`
  - `Session` gains `activity: SessionActivity`, `recentTools: [String]` (newest last, at most 3), `toolCount: Int` (PreToolUse count since the last UserPromptSubmit). `SessionState` (phone wire) is unchanged.
  - `public enum CharacterState: String, CaseIterable, Sendable { case idle, working, thinking, searching, approval, question, error, finished, rateLimited, sleeping, dizzy }`
  - `public enum CharacterEmote: String, CaseIterable, Sendable { case love, surprised, proud, wink, yawn, happy, annoyed, listening }`
  - `CharacterState.resolve(session: Session?, approvalPending: Bool, questionPending: Bool, quietFor: TimeInterval, islandVisible: Bool) -> CharacterState` (never returns dizzy; the island sets it).
  - `public enum SessionFocus { static func focused(sessions: [Session], approvalSessionIds: [String], questionSessionIds: [String], chosen: String?) -> String? }` (first pending card's session wins, else `chosen` if live, else most recent).

- [ ] **Step 1: Write failing tests:**
  - `SessionStoreTests`: UserPromptSubmit → `.thinking`, toolCount 0; PreToolUse `Grep`/`Glob`/`WebSearch`/`WebFetch` → `.searching`; PreToolUse `Edit` → `.none`; Notification "You hit a Rate Limit" → `.rateLimited`; Notification "Continue?" → `.asking`; recentTools keeps the last 3 tool summaries.
  - `CharacterStateTests`: table of the spec 3.1 triggers: question pending → question; approval pending → approval; finished/error map; thinking/searching/rateLimited from activity; `.asking` → question; no session or idle with `quietFor >= 120` and visible → sleeping; `quietFor 119` → idle.
  - `PhoneBridgeTests.activityChangesDoNotResync`: two session lists differing only in `activity`/`recentTools` cause one publish (bridge compares mapped `SessionRecord`s).
- [ ] **Step 2: Run** the three suites. Expected: FAIL.
- [ ] **Step 3: Implement.** Searching tools set: `["Grep","Glob","WebSearch","WebFetch"]`; rate-limit match is case-insensitive `"rate limit"`; asking = trimmed message ends with `?`.
- [ ] **Step 4: Run** `swift test`. Expected: PASS.
- [ ] **Step 5: Commit** `"Session activity and character state resolution"`.

### Task 6: Engine questions and plans

**Files:**
- Create: `Sources/BuddyKit/Questions/QuestionQueue.swift`
- Modify: `Sources/BuddyKit/Approvals/ApprovalQueue.swift` (`PendingApproval.kind`), `Sources/BuddyKit/Engine/BuddyEngine.swift`
- Test: `Tests/BuddyKitTests/QuestionQueueTests.swift`, `Tests/BuddyKitTests/BuddyEngineTests.swift`, `Tests/BuddyKitTests/EndToEndDrillTests.swift`

**Interfaces:**
- Consumes: Tasks 1-3, 5.
- Produces:
  - `public enum ApprovalKind: Sendable, Equatable { case tool; case plan(text: String) }` on `PendingApproval.kind` (default `.tool`).
  - `public struct PendingQuestion: Sendable, Equatable, Identifiable { id: UUID; sessionId: String; agentId: String?; questions: [AskQuestion]; createdAt: Date; expiresAt: Date }`
  - `public enum QuestionOutcome: Sendable, Equatable { case answered([String: String], DecisionSource); case released; case expired; case cancelled }`
  - `public actor QuestionQueue` mirroring `ApprovalQueue`: `submit(_:) async -> QuestionOutcome`, `answer(requestId:_:source:) -> Bool`, `release(requestId:)`, `cancel(requestId:)`, `cancel(sessionId:)`, `cancel(sessionId:agentId:)`, `expireDue(now:)`, `pending`, `updates()`.
  - `EngineSnapshot.questions: [PendingQuestion]`.
  - `BuddyEngine.init(..., questionTimeout: TimeInterval = BuddyEngine.defaultQuestionTimeout, canAskInBuddy: @escaping @Sendable () async -> Bool = { true })`; `defaultQuestionTimeout = 120`.
  - `BuddyEngine.answer(requestId: UUID, _ responses: [QuestionResponse]) async -> Bool` (Mac; free text allowed), `releaseQuestion(requestId: UUID) async`, `decidePlan(requestId: UUID, _ choice: PlanChoice) async -> Bool`.
  - `terminalOnlyTools` becomes `["AskUserQuestion"]` (its PermissionRequest stays terminal-only).

- [ ] **Step 1: Write failing tests:**
  - `QuestionQueueTests`: resolve-once, expiry, release, cancel by session/agent.
  - `BuddyEngineTests`:
    - `askEventShowsQuestionAndAnswers`: ask event → snapshot has one question; `answer` → hook reply `.answers` with the built dictionary.
    - `invalidQuestionsReturnNil`, `askDisabledReturnsNil` (`canAskInBuddy` false → nil at once, no snapshot entry).
    - `releaseReturnsNil`, `questionExpiresAt120s` (fake clock).
    - `plainPreToolUseForSameCallKeepsAsk`: a non-ask PreToolUse with the same tool and input does not cancel; one for another tool by the same asker cancels; UserPromptSubmit/Stop/SessionEnd cancel; PostToolUse `AskUserQuestion` same input cancels.
    - `hookHangUpCancelsQuestion`.
    - `exitPlanModeShowsPlanCard`: PermissionRequest `ExitPlanMode` with `{"plan":"# Do X\n..."}` → pending approval of kind `.plan(text:)`; `decidePlan(.acceptEdits)` → reply `.plan(.acceptEdits)`; `.change` → `.plan(.change)`; missing or empty plan → nil (terminal).
    - `decideOnPlanIsRejected`: `decide(requestId:.allow)` on a plan approval → false, still pending.
    - `answerValidationAppliesToMac`: unknown label → false, question still pending.
  - `EndToEndDrillTests.askDrill`: real `buddy-hook --ask` binary, engine on a temp socket, answer from the engine → stdout matches; engine `stop()` while waiting → empty stdout, exit 0.
- [ ] **Step 2: Run** the suites. Expected: FAIL.
- [ ] **Step 3: Implement.** Plan choices are kept in an engine map keyed by request id; `.acceptEdits`/`.askEachTime` resolve the queue as allow, `.change` as deny, and the reply is built from the map. `stop()` releases questions like approvals.
- [ ] **Step 4: Run** `swift test`. Expected: PASS.
- [ ] **Step 5: Commit** `"Engine: question queue and plan approvals"`.

### Task 7: Phone records for questions and answers

**Files:**
- Modify: `Sources/BuddyKit/Phone/PhoneTransport.swift`, `Sources/BuddyKit/Phone/InMemoryCloud.swift`, `Sources/BuddyKit/Phone/PhoneBridge.swift`, `Sources/BuddyKit/Engine/BuddyEngine.swift`
- Test: `Tests/BuddyKitTests/PhoneBridgeTests.swift`

**Interfaces:**
- Produces:
  - `public struct QuestionRecord: Codable, Sendable, Equatable { requestId: UUID; sessionId: String; status: ApprovalStatus; questions: [AskQuestion]; createdAt: Date; expiresAt: Date }`
  - `public struct AnswerRecord: Codable, Sendable, Equatable { requestId: UUID; responses: [[String]]; answeredAt: Date }` (labels per question index).
  - `PhoneTransport` adds `publish(question: QuestionRecord) async throws`, `answers() -> AsyncStream<AnswerRecord>`; `PhoneClientTransport` adds `questions() -> AsyncStream<[QuestionRecord]>`, `submit(answer: AnswerRecord) async throws`. `deleteRecords(olderThan:)` covers both types.
  - `PhoneBridge` publishes questions, applies answers as `.options(labels)` with `allowFreeText: false`, source `.phone`; never publishes plan approvals and ignores phone decisions for them.

- [ ] **Step 1: Write failing tests:** `questionPublishedAndResolved` (pending → resolved/expired status mirrored); `phoneAnswerApplied`; `phoneAnswerRejected` (unknown id, after expiry, wrong count, unknown label, empty selection); `planNeverPublished`; `phoneDecisionForPlanIgnored`; `cleanupDeletesQuestionsAndAnswers`.
- [ ] **Step 2: Run** `swift test --filter PhoneBridgeTests`. Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** `swift test`. Expected: PASS.
- [ ] **Step 5: Commit** `"Phone link: question and answer records"`.

### Task 8: CloudKit records for questions and answers

**Files:**
- Modify: `Apps/Shared/CloudKitSchema.swift`, `Apps/Shared/CloudKitTransport.swift`, `docs/cloudkit-setup.md`
- Test: `Apps/BuddyMacTests/CloudKitMappingTests.swift`, `Apps/BuddyMacTests/CloudKitTransportTests.swift`

**Interfaces:**
- Consumes: Task 7 records and protocol methods.
- Produces: record types `Question`, `Answer`; encrypted fields `questions` (JSON of `[AskQuestion]`), `responses` (JSON of `[[String]]`); plain `answeredAt`; subscriptions `buddy.question.created`, `buddy.answer.created`; notification category `BUDDY_QUESTION`, alert body `"Claude is asking"`.

- [ ] **Step 1: Write failing tests:** mapping round trip for both types; encrypted fields stored as encrypted values; malformed JSON or wrong record type → nil; transport `answers()` delivers a fetched `Answer`; subscription for answer wakes the Mac (`handleNotification(subscriptionID: "buddy.answer.created") == true`).
- [ ] **Step 2: Run** Mac tests `-only-testing:BuddyMacTests/CloudKitMappingTests` and `CloudKitTransportTests`. Expected: FAIL.
- [ ] **Step 3: Implement**, following the `Approval`/`Decision` code paths. Add the two record types and indexes to `docs/cloudkit-setup.md` (development schema auto-creates; production needs deploying).
- [ ] **Step 4: Run** both suites. Expected: PASS.
- [ ] **Step 5: Commit** `"CloudKit: Question and Answer records"`.

### Task 9: iPhone question screen

**Files:**
- Create: `Apps/BuddyPhone/QuestionView.swift`
- Modify: `Apps/BuddyPhone/PhoneModel.swift`, `Apps/BuddyPhone/PhoneController.swift`, `Apps/BuddyPhone/Notifications.swift`, `Apps/BuddyPhone/SessionListView.swift`, `Apps/BuddyPhone/PhoneCloud.swift`
- Test: `Apps/BuddyPhoneTests/PhoneModelTests.swift`, `Apps/BuddyPhoneTests/NotificationRoutingTests.swift`

**Interfaces:**
- Consumes: Task 7 `PhoneClientTransport.questions()`, `submit(answer:)`; existing `Authenticating`.
- Produces: `PhoneModel.questions: [QuestionRecord]`; `PhoneModel.answer(_ id: UUID, responses: [[String]]) async throws` (authenticates with reason `"Send this answer to Claude"`; throws on failed auth, expired or unknown id); notification route `.question(UUID)`.

- [ ] **Step 1: Write failing tests:** `answerRequiresAuthentication` (fake authenticator false → no submit, throws); `answerSubmitsRecord`; `expiredQuestionNotAnswerable`; `questionNotificationRoutesToQuestion`.
- [ ] **Step 2: Run** phone tests. Expected: FAIL.
- [ ] **Step 3: Implement.** Screen: one question at a time, "i/N", radio rows or checkboxes, description under each label, "Send answer" (enabled once each question has a pick), footnote `"If you don't answer in about 2 minutes, Claude asks in the terminal."` No free text. Notification opens the app on the question; no answer buttons. Unknown record types and session states are ignored.
- [ ] **Step 4: Run** phone tests. Expected: PASS.
- [ ] **Step 5: Commit** `"iPhone: answer Claude's questions"`.

### Task 10: Character contract and director

**Files:**
- Create: `Apps/BuddyMac/Characters/BuddyCharacter.swift`, `Apps/BuddyMac/Characters/CharacterRegistry.swift`, `Apps/BuddyMac/Characters/CharacterDirector.swift`
- Test: `Apps/BuddyMacTests/CharacterDirectorTests.swift`

**Interfaces:**
- Consumes: Task 5 `CharacterState`, `CharacterEmote`.
- Produces:
  - `struct CharacterInput { state: CharacterState; emote: CharacterEmote?; emoteStartedAt: Date?; stateStartedAt: Date; hovering: Bool; boopedAt: Date?; greetingStartedAt: Date?; look: CGVector /* each in -1...1 */; size: CGFloat; reduceMotion: Bool }`
  - `@MainActor protocol BuddyCharacter { var id: String { get }; var displayName: String { get }; var soundFolder: String { get }; func accent(for state: CharacterState) -> Color; func view(_ input: CharacterInput) -> AnyView }`
  - `enum CharacterRegistry { static let all: [any BuddyCharacter]; static func current(defaults: UserDefaults) -> any BuddyCharacter }` (key `character.id`; unknown → first). Settings shows a character picker only when `all.count >= 2`.
  - `struct CharacterDirector` (pure): `mutating func hoverBegan(at: CGPoint, now: Date)`, `hoverMoved(to:now:)`, `hoverEnded(now:)`, `click(now:)`, `greet(now:)`, `screenAway(from:to:)`, `tick(now:) -> [DirectorEvent]`; `var dizzyUntil: Date?`, `var emote: (CharacterEmote, Date)?`. `enum DirectorEvent { case emote(CharacterEmote), dizzyStarted, dizzyEnded, boop, greet }`.
  - Values: long hover 1.9 s → love; love cooldown 6 s; re-arm after 40 pt movement; 3 clicks within 1.7 s → dizzy for 3.3 s then `happy`; a single click → boop + `annoyed`; greeting lasts 4 s; repeats when away ≥ 180 s.

- [ ] **Step 1: Write failing tests** for each value above (fake times), plus `noLoveWhileDizzy` and `greetOnlyAfterLongAway` (179 s → none, 180 s → greet).
- [ ] **Step 2: Run** `-only-testing:BuddyMacTests/CharacterDirectorTests`. Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run.** Expected: PASS.
- [ ] **Step 5: Commit** `"Character contract and director"`.

### Task 11: Block

**Files:**
- Create: `Apps/BuddyMac/Characters/Block/Block.swift`, `Apps/BuddyMac/Characters/Block/BlockView.swift`, `Apps/BuddyMac/Characters/Block/BlockDrawing.swift`
- Modify: `Apps/BuddyMac/Characters/CharacterRegistry.swift`
- Test: `Apps/BuddyMacTests/BlockRenderTests.swift`

**Interfaces:**
- Consumes: Task 10 contract.
- Produces: `struct Block: BuddyCharacter` with `id "block"`, `displayName "Block"`, `soundFolder "block"`, registered first in `CharacterRegistry.all`.

- [ ] **Step 1: Write failing tests** (pattern of the existing render smoke test: `ImageRenderer`, count non-transparent pixels, `BUDDY_SNAPSHOT_DIR` writes PNGs): `everyStateDraws` (each `CharacterState` at 64 pt and 12 pt draws > 0 pixels), `everyEmoteDraws`, `statesDiffer` (idle vs error images differ), `reduceMotionDraws`, `accentsDistinct` (11 different accents).
- [ ] **Step 2: Run** `-only-testing:BuddyMacTests/BlockRenderTests`. Expected: FAIL.
- [ ] **Step 3: Implement** the spec 3.3 look: rounded square with continuous corners in the state accent, soft vertical gradient, glossy band top-left plus specular dot, subtle shadow; two eyes (light rounded shape, dark pupil, catch-light) moved by `look`; per-state table and emotes of spec 3.3; Reduce Motion drops rolls/shakes/hops/bounces/particles. Drive with `TimelineView(.animation)` and `Canvas`; switches over `CharacterState`/`CharacterEmote` have no `default`.
- [ ] **Step 4: Run.** Expected: PASS. Run once with `BUDDY_SNAPSHOT_DIR` and look at the PNGs.
- [ ] **Step 5: Commit** `"Block, Buddy's own character"`.

### Task 12: Sound layer

**Files:**
- Modify: `Apps/BuddyMac/Sound/SoundTrigger.swift`, `Apps/BuddyMac/Sound/SoundPlayer.swift` (rewritten, see constraints), `Apps/BuddyMac/SettingsView.swift`, `Apps/BuddyMac/AppModel.swift`
- Test: `Apps/BuddyMacTests/SoundTriggerTests.swift`, `Apps/BuddyMacTests/SoundLibraryTests.swift`

**Interfaces:**
- Produces:
  - `enum SoundCue: String, CaseIterable, Sendable` with exactly: peek, open, close, hover, boop, annoyed, dizzy, greet, work, think, search, approval, question, approve, send, finish, error, rate, love, pop, proud, wink, yawn, sleep, tick, switch (raw value `"switch"`; case name `switchSession`).
  - `struct SoundTrigger` `mutating func cues(previous: EngineSnapshot?, current: EngineSnapshot, terminalFrontmost: Bool) -> [SoundCue]` (work, think, search, approval, question, finish, error, rate per spec 4; finish/error skipped when `terminalFrontmost`).
  - `struct SoundLibrary { static func resolve(cue: SoundCue, bundled: URL, override: URL) -> URL? }` (override first; extensions `wav`, `caf`, `m4a`); `customCount(override:) -> Int`.
  - `@MainActor final class SoundPlayer { play(_:); var isMuted: Bool; var volume: Float; func reload(); var customCount: Int }` persisted under `sound.muted` (default false) and `sound.volume` (default 0.4); pool of 3 players per cue.
  - Override folder: `~/Library/Application Support/Buddy/Sounds` (injectable in tests).
  - `terminalFrontmost`: frontmost app bundle id in `["com.apple.Terminal","com.googlecode.iterm2","com.mitchellh.ghostty","net.kovidgoyal.kitty","com.github.wez.wezterm","dev.warp.Warp-Stable","org.alacritty"]`.

- [ ] **Step 1: Write failing tests:** trigger table per cue (new approval id → approval once; question → question; SessionStart → work; UserPromptSubmit → think; searching → search; rate limit → rate; Stop → finish unless frontmost; StopFailure → error unless frontmost; repeated identical snapshots → nothing); `SoundLibraryTests`: override beats bundled, unknown names ignored, missing → nil, `customCount` counts only cue-named files.
- [ ] **Step 2: Run** both suites. Expected: FAIL.
- [ ] **Step 3: Implement.** Delete the old `SoundPlayer` body first and write it from `AVAudioPlayer` documentation. Island-reaction cues (peek, open, close, hover, love, boop, annoyed, dizzy, greet, tick, switch, pop, sleep, proud, wink, yawn, approve, send) are played by the island in later tasks. Settings: "Sounds" group with mute toggle, volume slider, "Open sounds folder", "Reload sounds", "N custom sounds in use", hint `"Drop a file named like a sound (finish.wav, approval.m4a…) in the sounds folder to replace it, then Reload."`.
- [ ] **Step 4: Run.** Expected: PASS.
- [ ] **Step 5: Commit** `"Sound cues, override folder, mute and volume"`.

### Task 13: CC0 sound set

**Files:**
- Create: `Apps/BuddyMac/Resources/sounds/block/<cue>.wav` (26 files), `Apps/BuddyMac/Resources/sounds/SOURCES.md`
- Modify: `Apps/project.yml` (bundle `sounds/block`), `scripts/test-release.sh` (sound section), `scripts/README.md`
- Test: `Apps/BuddyMacTests/SoundLibraryTests.swift` (`bundledSetComplete`)

- [ ] **Step 1: Write failing test** `bundledSetComplete`: every `SoundCue` has a bundled file in `sounds/block`, each decodes with `AVAudioFile`, is under 1.5 s, and appears in `SOURCES.md` on a line containing `CC0`.
- [ ] **Step 2: Run.** Expected: FAIL.
- [ ] **Step 3: Fetch and prepare.** Download Kenney's "Interface Sounds", "UI Audio", "Digital Audio", "Impact Sounds" (kenney.nl, CC0) into a new empty scratch directory (untrusted data rule); fall back to freesound.org CC0 only for gaps. If packs are OGG, `brew install ffmpeg` (local tool only) to convert. Pick one file per cue, trim to under 1.5 s, convert to 16-bit 48 kHz WAV, level-match by ear and by peak. `SOURCES.md`: one row per cue: file, source pack, original file name, `CC0`, URL. In `test-release.sh` replace the testing-only notice check with: every file under `Resources/sounds/` is listed in `SOURCES.md` with `CC0`.
- [ ] **Step 4: Run** the test and `scripts/test-release.sh`. Expected: PASS.
- [ ] **Step 5: Commit** `"CC0 sound set for Block"`.

### Task 14: Island machine, placement and panel

**Files:**
- Modify (rewrite): `Apps/BuddyMac/Island/IslandLogic.swift`, `Apps/BuddyMac/Island/IslandGeometry.swift`, `Apps/BuddyMac/Island/IslandWindowController.swift`
- Test: `Apps/BuddyMacTests/IslandLogicTests.swift`, `Apps/BuddyMacTests/IslandGeometryTests.swift`

**Interfaces:**
- Produces:
  - `enum IslandMode: Sendable { case hidden, compact, expanded }`
  - `enum IslandInput { case hoverBegan, hoverEnded, click, escape, interaction, ordinaryEvent, cardPending(Bool), tick }`
  - `struct IslandMachine { var mode: IslandMode; var closesAt: Date?; mutating func handle(_ input: IslandInput, now: Date) }` — values: expanded → compact after 15 s without interaction; compact → hidden after 60 s; hover-opened compact closes 0.6 s after hover ends; held while a card is pending; ordinary event reveals compact; `cardPending(true)` expands; `escape` collapses (and is reported so Task 16 can release a shown question).
  - `IslandLayout.compactExtraWidth = 160`, `expandedWidth = 640`, `questionMaxHeight = 560`; `IslandGeometry.placement(for: ScreenMetrics) -> IslandPlacement`; `chooseScreen([ScreenCandidate]) -> Int?` (notch screen first, else main).

- [ ] **Step 1: Write failing tests** for every machine transition and timer above, `countdownShownBeforeClose` (`closesAt` set), and geometry: notch screen placement, no-notch top bar, screen choice.
- [ ] **Step 2: Run** both suites. Expected: FAIL.
- [ ] **Step 3: Implement.** Delete the existing bodies of placement, `chooseScreen` and the panel set-up first and write them from AppKit documentation (`NSPanel` `.nonactivatingPanel`, a level above the menu bar, `canJoinAllSpaces`/`fullScreenAuxiliary`/`stationary`, notch test via `NSScreen.safeAreaInsets.top > 0` and `auxiliaryTopLeftArea`/`auxiliaryTopRightArea`).
- [ ] **Step 4: Run.** Expected: PASS.
- [ ] **Step 5: Commit** `"Island state machine and placement"`.

### Task 15: Island views, motion and hotkeys

**Files:**
- Create: `Apps/BuddyMac/Island/IslandOverview.swift`, `Apps/BuddyMac/Island/SessionPill.swift`, `Apps/BuddyMac/Island/StatusCards.swift`, `Apps/BuddyMac/Island/Hotkeys.swift`
- Modify: `Apps/BuddyMac/Island/IslandView.swift`, `Apps/BuddyMac/Island/ApprovalCardView.swift`, `Apps/BuddyMac/AppModel.swift`, `Apps/BuddyMac/MenuContentView.swift`
- Test: `Apps/BuddyMacTests/IslandRenderTests.swift`, `Apps/BuddyMacTests/HotkeyTests.swift`

**Interfaces:**
- Consumes: Tasks 5, 10-12, 14.
- Produces: `IslandFeed` protocol the island reads from (`snapshots`, `decide`, `decidePlan`, `answer`, `releaseQuestion`) implemented by `AppModel` (and by the demo in Task 17); `Hotkeys` registering ⌃⌥M (mute), ⌃⌥] / ⌃⌥[ (cycle focus), ⌃⌥A (pending card) with Carbon `RegisterEventHotKey`.

- [ ] **Step 1: Write failing tests:** render smoke tests for overview (focused session + 4 pills), each status card (error, finished, dizzy), approval card unchanged rules (existing assertions kept); `HotkeyTests`: key combos map to actions; focus cycling order.
- [ ] **Step 2: Run.** Expected: FAIL.
- [ ] **Step 3: Implement** spec section 5: open spring with slight overshoot, close ease-in-out about 0.34 s, shape animates width/height/corners, crossfade, glow in accent; Reduce Motion fades only. Header: mute, settings, close (hidden while a card is pending). Focused session: project, `toolCount` steps, `recentTools` scrolling in. Pills: small character at 12 pt, name, badge "!" / check / x; click focuses and plays `switch`. Copy: error `"This session stopped with an error."`, finished `"Claude is done"`, dizzy `"Whoa, too many boops!"` (3 s), `"Answered in <where>."`, `"Still waiting in the terminal."`. Character reactions from `CharacterDirector` with their cues (hover, love, boop, annoyed, dizzy, greet, peek, open, close, tick, sleep, approve).
- [ ] **Step 4: Run.** Expected: PASS. Launch the built app and check the island by eye.
- [ ] **Step 5: Commit** `"Island overview, pills, cards, motion and hotkeys"`.

### Task 16: Question card and plan card

**Files:**
- Create: `Apps/BuddyMac/Island/QuestionCardView.swift`, `Apps/BuddyMac/Island/QuestionCardModel.swift`, `Apps/BuddyMac/Island/PlanCardView.swift`, `Apps/BuddyMac/Presence.swift`
- Modify: `Apps/BuddyMac/AppModel.swift`, `Apps/BuddyMac/SettingsView.swift`
- Test: `Apps/BuddyMacTests/QuestionCardModelTests.swift`, `Apps/BuddyMacTests/PresenceTests.swift`, `Apps/BuddyMacTests/IslandRenderTests.swift`

**Interfaces:**
- Consumes: Task 6 engine API, Task 3 `QuestionResponse`.
- Produces:
  - `struct QuestionCardModel` (pure): `index`, `selections`, `otherText`, `mutating func pick(_ label: String, now: Date) -> CardAction`, `pressNumber(_ n: Int, now:)`, `next(now:)`, `openOther()`, `cancelOther()`, `responses: [QuestionResponse]?`; `enum CardAction { case none, advanced, send([QuestionResponse]) }`; picks ignored before the arming delay (`IslandLogic.armingDelay`).
  - `Presence.canAskInBuddy(enabled: Bool, screenLocked: Bool, screenAsleep: Bool, phoneLinkLive: Bool) -> Bool` (false only when disabled, or (locked or asleep) and no phone link); screen lock read from `CGSessionCopyCurrentDictionary()["CGSSessionScreenIsLocked"]`, sleep from `NSWorkspace` screen sleep/wake notifications.
  - Setting `"Answer Claude's questions in Buddy"`, key `questions.enabled`, default true.

- [ ] **Step 1: Write failing tests:** single select advances then sends after the last; multi select toggles, Send disabled until one pick; keys 1-4; "Other..." text sent as `.text`; Esc closes the field; picks inside the arming delay ignored; `Presence` truth table; render smoke tests for chips layout, list layout, plan card.
- [ ] **Step 2: Run.** Expected: FAIL.
- [ ] **Step 3: Implement** spec 6.3 and 6.5. Question card: cyan wash, `"Claude is asking"`, `"i/N"`, link `"Answer in terminal"` (calls `releaseQuestion`), header, question text, chips when no option has a description else a list, `"Other..."` field placeholder `"Type your answer"`, scrolls within 560 pt. Island Escape while a question shows calls `releaseQuestion`. Plan card: `"Claude has a plan"`, scrollable plan text, buttons `"Change plan"`, `"Go (auto-accept edits)"` (primary), `"Go (ask each time)"`, arming delay. Pass `Presence.canAskInBuddy` into the engine.
- [ ] **Step 4: Run.** Expected: PASS. Manually answer a real `AskUserQuestion` (single and multi select) in a Claude Code session using the built app with a temporary `CLAUDE_CONFIG_DIR` (never the real settings) and check the answers Claude reports; if that session cannot log in, say so in the report instead of using the real config.
- [ ] **Step 5: Commit** `"Question and plan cards on the island"`.

### Task 17: Demo mode

**Files:**
- Create: `Apps/BuddyMac/Demo/DemoFeed.swift`, `Apps/BuddyMac/Demo/DemoScript.swift`
- Modify: `Apps/BuddyMac/MenuContentView.swift`, `Apps/BuddyMac/AppModel.swift`
- Test: `Apps/BuddyMacTests/DemoScriptTests.swift`

**Interfaces:**
- Consumes: Task 15 `IslandFeed`.
- Produces: `struct DemoScript { static let steps: [(at: TimeInterval, snapshot: EngineSnapshot)] }`; `DemoFeed: IslandFeed` replaying it; decisions and answers do nothing; menu item `"Demo"`.

- [ ] **Step 1: Write failing tests:** `demoCoversEveryState` (resolving each step's focused state covers every `CharacterState` except dizzy, plus one single-select and one multi-select question and one plan); `demoDecisionsDoNothing`.
- [ ] **Step 2: Run.** Expected: FAIL.
- [ ] **Step 3: Implement** spec 7 script: tools, thinking, searching, permission `"Bash: npm test"`, question `"Which test reporter format?"` (Verbose / Dot / JSON) and a multi-select one, plan card, rate-limit notice, finished, error, sleeping. While the demo runs the real engine's snapshots are not shown; it ends by returning to them.
- [ ] **Step 4: Run.** Expected: PASS.
- [ ] **Step 5: Commit** `"Demo mode"`.

### Task 18: First-run steps window

**Files:**
- Create: `Apps/BuddyMac/Setup/SetupSteps.swift`, `Apps/BuddyMac/Setup/SetupWindow.swift`
- Modify: `Apps/BuddyMac/AppModel.swift`, `Apps/BuddyMac/SettingsView.swift` (remove the welcome card), `Apps/BuddyMac/MenuContentView.swift`, `Apps/BuddyMac/BuddyMacApp.swift`
- Delete: `FirstRunWelcome` and `Apps/BuddyMacTests/FirstRunWelcomeTests.swift` (replaced)
- Test: `Apps/BuddyMacTests/SetupStepsTests.swift`

**Interfaces:**
- Consumes: Task 4 `HookInstallStatus`, Task 17 demo.
- Produces: `enum SetupStepID { case applications, connect, openSessions, check, iPhone, openAtLogin }`; `struct SetupStep { id; done: Bool; title: String; body: String }`; `SetupSteps.make(inApplications: Bool, hookStatus: HookInstallStatus, sawEventProject: String?, cloudEnabled: Bool, openAtLogin: Bool) -> [SetupStep]`; `SetupSteps.needsAttention(...) -> Bool` (drives the menu dot and auto-open).

- [ ] **Step 1: Write failing tests:** step list order and done flags; iPhone step absent when `cloudEnabled` false; `outdated` → connect step not done with title `"Update Buddy's hooks so you can answer Claude's questions from the notch"`; openSessions done once an event was seen; exact copy of spec 8 steps 2-5 (titles and bodies).
- [ ] **Step 2: Run.** Expected: FAIL.
- [ ] **Step 3: Implement** spec 8. Step 2 button `"Review and install"` opens the existing diff and Confirm. Step 3 copy: `"Claude sessions that are already open pick up Buddy within a few seconds. If one doesn't show up in step 4, quit it (/exit) and run claude --continue to pick up where you were."` Step 4: `"Type anything in a Claude session."`, spinner, then `"Buddy sees your session in <project>"` with Block greeting; button `"Try the demo"`. Window opens on first launch and when the hooks are outdated; menu item `"Setup steps..."` with a dot while `needsAttention`.
- [ ] **Step 4: Run.** Expected: PASS.
- [ ] **Step 5: Commit** `"First-run steps window"`.

### Task 19: Everything Buddy's own

**Files:**
- Delete: the earlier character's folder under `Apps/BuddyMac/` (all), the seven old files directly under `Apps/BuddyMac/Resources/sounds/`, the earlier character's render tests, `docs/superpowers/plans/2026-10-19-buddy.md`, `docs/superpowers/plans/2026-10-20-installer.md`
- Modify (rewrite bodies): `Sources/BuddyKit/Installer/ClaudeSettingsInstaller.swift` (`backupURL`, `hooksObject`, `eventGroups`, `parse`), `Apps/BuddyMac/Install/HookCopyRefresh.swift` (`pointsAtSupportCopy`)
- Modify: `THIRD-PARTY-NOTICES.md` (delete if `SOURCES.md` suffices, and drop references), `README.md`, `Apps/README.md`, `scripts/README.md`, `docs/*.md`, `docs/superpowers/specs/*.md`, this plan's file, `Apps/project.yml`, tests with outside names in fixtures, `.taskmaster/tasks/tasks.json` via `task-master update-task --id=<id> --prompt="Replace any mention of the upstream project and its character with neutral wording; change nothing else"`
- Create: `scripts/check-names.sh`; call it from `scripts/test-release.sh`

**Interfaces:**
- `scripts/check-names.sh [path/to/Buddy.app]`: case-insensitive search for the upstream project's names, its character's name and its author's names (the six patterns live in the script) in all tracked files (`git ls-files`) and, when an app path is given, in its `Resources`, `Info.plist` files and `strings` of its executables, ignoring lines that contain the repo folder path (and printing that it does so until the folder is renamed). The script skips its own file, which holds the patterns. Exit 1 with the matches listed.

- [ ] **Step 1: Write failing checks:** run `scripts/check-names.sh` (expected FAIL with many matches); existing installer and refresh tests stay as the behaviour pins (add `backupNameFormat`: `settings.json.buddy-backup-yyyyMMdd-HHmmss` with numeric suffix on collision, if not already pinned).
- [ ] **Step 2: Rewrite** the five derived pieces listed in the old `THIRD-PARTY-NOTICES.md` table (Tasks 12 and 14 already did three; this does the installer helpers and `pointsAtSupportCopy`): delete each body and write it from the tests and Foundation documentation.
- [ ] **Step 3: Delete and scrub** the files above; rewrite remaining docs neutrally ("the repo folder" instead of its name).
- [ ] **Step 4: Run** `swift test`, Mac and phone test suites, `scripts/test-release.sh`, `scripts/test-phone.sh`, `scripts/check-names.sh dist/.../BuddyMac.app` after a Release build. Expected: all PASS, no matches.
- [ ] **Step 5: Commit** `"Make everything Buddy's own"`.

### Task 20: Final check, merge and history squash

- [ ] **Step 1:** Full runs: `swift test`; Mac and phone `xcodebuild test`; `scripts/test-release.sh`; `scripts/test-phone.sh`; build the dmg with `scripts/release.sh` and run `scripts/check-names.sh` on the built app.
- [ ] **Step 2:** Manual pass with the demo: every state, emote, reaction and card visible; sounds play; mute and volume work; setup window from a clean temporary home.
- [ ] **Step 3: Stop and ask the maintainer** before merging into `main` and before squashing. Show: branches, the commit list, and the backup bundle path to be written. Do not continue without an explicit go-ahead.
- [ ] **Step 4 (after go-ahead):** `git bundle create ~/Projects/buddy-history-before-squash-2026-10-20.bundle --all`; verify with `git bundle verify`; merge the branch into `main`; replace history with one root commit of the current tree (`git checkout --orphan fresh main && git commit` then move `main` to it); delete the merged branches; `git gc --prune=now`. Existing bundles outside the repo are left alone.
- [ ] **Step 5:** `git log --all --oneline` shows one commit; `git grep -i` over `$(git rev-list --all)` for the upstream project's and its character's names (the patterns in `scripts/check-names.sh`) finds nothing; tests still pass. Remind the maintainer to rename the folder to `buddy` when no session runs in it.
