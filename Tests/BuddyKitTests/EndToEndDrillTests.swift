import Foundation
import Synchronization
import Testing
@testable import BuddyKit

// Headless failure drills for docs/e2e-checklist.md: the real `buddy-hook` executable talking to a
// real `BuddyEngine` on a temporary socket, with `InMemoryCloud` as the phone link. Nothing here
// reads or writes the user's Claude settings or Application Support directory (the hook process
// gets `BUDDY_SOCKET` and an otherwise empty environment).
//
// Each drill names the checklist row it backs. Waits are bounded: hook processes are killed after
// 60 s (`HookProcess.start`) and stream waits give up after 20 s, so a regression fails instead
// of hanging.
//
// Finer-grained behaviour (backlog bursts, ordering, queue invariants, ...) is covered in
// HookSocketTests, BuddyEngineTests, PhoneBridgeTests and ApprovalQueueTests using the in-process
// `HookClient`; these drills add the real process boundary. "App not running" (checklist row F7)
// is pinned by BuddyHookProcessTests.printsNothingAndExitsZeroWhenNoServer.

// MARK: - Helpers

private final class DrillClock: Sendable {
    private let value: Mutex<Date>
    init(_ start: Date) { value = Mutex(start) }
    var now: Date { value.withLock { $0 } }
    func advance(by seconds: TimeInterval) { value.withLock { $0 = $0.addingTimeInterval(seconds) } }
}

/// First element of `stream` matching `predicate`, or nil after `timeout` (an upper bound only).
private func firstMatch<T: Sendable>(
    in stream: AsyncStream<T>,
    timeout: Duration = .seconds(20),
    where predicate: @escaping @Sendable (T) -> Bool
) async -> T? {
    await withTaskGroup(of: T?.self) { group in
        group.addTask {
            for await value in stream where predicate(value) { return value }
            return nil
        }
        group.addTask {
            try? await Task.sleep(for: timeout)
            return nil
        }
        let first = await group.next() ?? nil
        group.cancelAll()
        return first
    }
}

private func json(_ value: JSONValue) -> String {
    String(decoding: try! JSONEncoder().encode(value), as: UTF8.self)
}

private func eventJSON(_ name: String, session: String, tool: String? = nil, command: String? = nil) -> Data {
    var members: [String: JSONValue] = [
        "session_id": .string(session),
        "hook_event_name": .string(name),
    ]
    if let tool { members["tool_name"] = .string(tool) }
    if let command { members["tool_input"] = .object(["command": .string(command)]) }
    return Data(json(.object(members)).utf8)
}

private func permission(session: String = "s1", command: String = "ls") -> Data {
    eventJSON("PermissionRequest", session: session, tool: "Bash", command: command)
}

private let allowOutput = HookOutput.stdout(for: .decision(.allow), event: HookEvent(sessionId: "s", name: .permissionRequest))!
private let denyOutput = HookOutput.stdout(for: .decision(.deny), event: HookEvent(sessionId: "s", name: .permissionRequest))!

/// The hook's stdout with the trailing newline `print` adds removed; "" means it printed nothing.
private func printed(_ result: HookProcess.Result) -> String {
    result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
}

/// A hook that finished without printing anything and with exit status 0, well before its own
/// 610 s reply wait (the 10 s bound also absorbs process start-up on a loaded machine).
private func expectSilent(_ result: HookProcess.Result, sourceLocation: SourceLocation = #_sourceLocation) {
    #expect(!result.killed, "hook was still waiting", sourceLocation: sourceLocation)
    #expect(result.status == 0, sourceLocation: sourceLocation)
    #expect(printed(result).isEmpty, "hook printed \(result.stdout)", sourceLocation: sourceLocation)
    #expect(result.elapsed < 10, sourceLocation: sourceLocation)
}

private struct DrillRig {
    let engine: BuddyEngine
    let path: URL
    let cloud: InMemoryCloud

    func snapshot(where predicate: @escaping @Sendable (EngineSnapshot) -> Bool) async -> EngineSnapshot? {
        await firstMatch(in: await engine.snapshots(), where: predicate)
    }

    /// Waits for exactly `count` pending approvals and returns them in submission order.
    func pending(count: Int) async -> [PendingApproval] {
        await snapshot { $0.pending.count == count }?.pending ?? []
    }

    func hook(_ stdin: Data) -> Task<HookProcess.Result, Never> {
        HookProcess.start(stdin: stdin, socket: path)
    }

    func phoneDecides(_ id: UUID, _ d: Decision, at date: Date = Date()) async throws {
        try await cloud.phoneSide.submit(decision: DecisionRecord(
            requestId: id, decision: d, decidedAt: date, source: .phone))
    }

    /// The phone link applies decisions in order, so once a decision for a fresh sentinel request
    /// (answered by a real hook process) has landed, everything sent before it has been considered.
    func flushPhoneDecisions() async throws {
        let before = await snapshot { _ in true }?.pending.map(\.id) ?? []
        let sentinel = hook(permission(session: "sentinel", command: "sentinel"))
        let fresh = await snapshot { snapshot in
            snapshot.pending.contains { $0.summary.text == "sentinel" && !before.contains($0.id) }
        }?.pending.first { $0.summary.text == "sentinel" }
        let id = try #require(fresh?.id)
        try await phoneDecides(id, .deny)
        let result = await sentinel.value
        #expect(printed(result) == denyOutput)
    }
}

/// Starts an engine on a fresh short socket path (in-memory phone link), runs `body`, then always
/// stops it and removes the socket file.
private func withDrillEngine(
    approvalTimeout: TimeInterval = BuddyEngine.defaultApprovalTimeout,
    clock: (@Sendable () -> Date)? = nil,
    tickInterval: TimeInterval = 1,
    _ body: (DrillRig) async throws -> Void
) async throws {
    let path = HookProcess.tempSocketURL()
    let cloud = InMemoryCloud()
    let engine = BuddyEngine(
        socketPath: path,
        transport: cloud.macSide,
        approvalTimeout: approvalTimeout,
        clock: clock ?? { Date() },
        tickInterval: tickInterval)
    try await engine.start()
    do {
        try await body(DrillRig(engine: engine, path: path, cloud: cloud))
    } catch {
        await engine.stop()
        try? FileManager.default.removeItem(at: path)
        throw error
    }
    await engine.stop()
    try? FileManager.default.removeItem(at: path)
}

// MARK: - Drills

@Suite struct EndToEndDrillTests {
    /// Checklist F1 (quit the app mid-approval).
    @Test func engineStoppedMidApprovalLeavesHookSilent() async throws {
        try await withDrillEngine { rig in
            let hook = rig.hook(permission(command: "make deploy"))
            let approval = try #require(await rig.pending(count: 1).first)

            await rig.engine.stop()  // what quitting the app does

            expectSilent(await hook.value)
            #expect(await rig.engine.outcome(for: approval.id) == .cancelled)
            // Nothing can be decided any more, from the Mac or from the phone.
            #expect(await rig.engine.decide(requestId: approval.id, .allow) == false)
            // And a hook started now finds no app at all: still silent.
            expectSilent(await rig.hook(permission(command: "make deploy")).value)
        }
    }

    /// Checklist F4 (terminal answers first).
    @Test func terminalAnsweringFirstCancelsApprovalAndRejectsLateDecisions() async throws {
        try await withDrillEngine { rig in
            let waiting = rig.hook(permission(command: "rm -rf build"))
            let approval = try #require(await rig.pending(count: 1).first)

            // Claude Code ran the tool after the user said yes in the terminal.
            let terminal = await rig.hook(
                eventJSON("PostToolUse", session: "s1", tool: "Bash", command: "rm -rf build")).value
            expectSilent(terminal)

            expectSilent(await waiting.value)
            #expect(await rig.engine.outcome(for: approval.id) == .cancelled)
            #expect(await rig.pending(count: 0).isEmpty)

            // Late answers, Mac and phone, change nothing.
            #expect(await rig.engine.decide(requestId: approval.id, .allow) == false)
            try await rig.phoneDecides(approval.id, .allow)
            try await rig.flushPhoneDecisions()
            #expect(await rig.engine.outcome(for: approval.id) == .cancelled)
        }
    }

    /// Checklist F5 (two simultaneous sessions).
    @Test func interleavedRequestsFromTwoSessionsEachGetTheirOwnDecision() async throws {
        try await withDrillEngine { rig in
            let a1 = rig.hook(permission(session: "session-a", command: "a1"))
            let b1 = rig.hook(permission(session: "session-b", command: "b1"))
            let approvals = await rig.pending(count: 2)
            let byCommand = Dictionary(uniqueKeysWithValues: approvals.map { ($0.summary.text, $0) })
            let pa1 = try #require(byCommand["a1"])
            let pb1 = try #require(byCommand["b1"])
            #expect(pa1.sessionId == "session-a")
            #expect(pb1.sessionId == "session-b")

            // Answered in the opposite order, from both devices.
            #expect(await rig.engine.decide(requestId: pb1.id, .deny))
            #expect(printed(await b1.value) == denyOutput)
            // a1 is still waiting; the answer to its neighbour did not touch it.
            #expect(await rig.pending(count: 1).map(\.id) == [pa1.id])
            try await rig.phoneDecides(pa1.id, .allow)
            #expect(printed(await a1.value) == allowOutput)

            // The next request of session a is a new card of its own.
            let a2 = rig.hook(permission(session: "session-a", command: "a2"))
            let pa2 = try #require(await rig.pending(count: 1).first)
            #expect(pa2.summary.text == "a2")
            #expect(await rig.engine.decide(requestId: pa2.id, .deny))
            #expect(printed(await a2.value) == denyOutput)

            #expect(await rig.engine.outcome(for: pa1.id) == .decided(.allow, .phone))
            #expect(await rig.engine.outcome(for: pb1.id) == .decided(.deny, .mac))
            #expect(await rig.engine.outcome(for: pa2.id) == .decided(.deny, .mac))
        }
    }

    /// Checklist F11 (answer "no" in the terminal): Claude Code stops the waiting hook and sends no
    /// other event. Here the harness kills the real hook process instead.
    @Test func hookStoppedWhileWaitingClearsTheCardAndThePhoneRecord() async throws {
        try await withDrillEngine { rig in
            let hook = HookProcess.start(stdin: permission(command: "rm -rf build"), socket: rig.path, bound: 3)
            let approval = try #require(await rig.pending(count: 1).first)

            let result = await hook.value
            #expect(result.killed)
            #expect(printed(result).isEmpty)
            let stopped = Date()
            #expect(await rig.pending(count: 0).isEmpty)
            #expect(Date().timeIntervalSince(stopped) < 1, "the card outlived its hook")
            #expect(await rig.engine.outcome(for: approval.id) == .cancelled)
            #expect(await firstMatch(in: rig.cloud.phoneSide.approvals()) { records in
                records.contains { $0.requestId == approval.id && $0.status == .resolved }
            } != nil)

            // Late answers change nothing.
            #expect(await rig.engine.decide(requestId: approval.id, .allow) == false)
            try await rig.phoneDecides(approval.id, .allow)
            try await rig.flushPhoneDecisions()
            #expect(await rig.engine.outcome(for: approval.id) == .cancelled)
        }
    }

    /// Checklist F6 (decision after expiry): the timer has fired and the hook has given up.
    @Test func decisionAfterTimerExpiryIsRejectedAndHookIsSilent() async throws {
        try await withDrillEngine(approvalTimeout: 0.5, tickInterval: 0.1) { rig in
            let hook = rig.hook(permission(command: "late"))
            let approval = try #require(await rig.pending(count: 1).first)

            expectSilent(await hook.value)
            #expect(await rig.engine.outcome(for: approval.id) == .expired)

            #expect(await rig.engine.decide(requestId: approval.id, .allow) == false)
            try await rig.phoneDecides(approval.id, .allow)
            try await rig.flushPhoneDecisions()
            #expect(await rig.engine.outcome(for: approval.id) == .expired)
        }
    }

    /// Checklist F6 (decision after expiry): the click lands after `expiresAt` but before the
    /// expiry timer has run (system sleep, starved timer). The hook must still print nothing.
    @Test func decisionPastExpiryBeforeTimerFiresIsRejectedAndHookIsSilent() async throws {
        let clock = DrillClock(Date(timeIntervalSince1970: 1_800_000_000))
        try await withDrillEngine(approvalTimeout: 10, clock: { clock.now }, tickInterval: 1_000_000) { rig in
            let hook = rig.hook(permission(command: "late"))
            let approval = try #require(await rig.pending(count: 1).first)

            clock.advance(by: 11)
            #expect(await rig.engine.decide(requestId: approval.id, .allow) == false)

            expectSilent(await hook.value)
            #expect(await rig.engine.outcome(for: approval.id) == .expired)
        }
    }

    /// Checklist F2/F3 (phone and Mac both answer): the first decision wins.
    @Test func phoneDenyWinsOverLaterMacAllow() async throws {
        try await withDrillEngine { rig in
            let hook = rig.hook(permission(command: "git push --force"))
            let approval = try #require(await rig.pending(count: 1).first)

            try await rig.phoneDecides(approval.id, .deny)
            #expect(printed(await hook.value) == denyOutput)

            #expect(await rig.engine.decide(requestId: approval.id, .allow) == false)
            #expect(await rig.engine.outcome(for: approval.id) == .decided(.deny, .phone))
        }
    }

    /// Checklist F8 (truncated command): the phone cannot allow it, but can deny it.
    @Test func phoneAllowOnTruncatedApprovalIsIgnoredButDenyWorks() async throws {
        try await withDrillEngine { rig in
            let longCommand = "echo " + String(repeating: "x", count: ToolSummary.defaultMaxLength + 100)
            let hook = rig.hook(permission(command: longCommand))
            let approval = try #require(await rig.pending(count: 1).first)
            #expect(approval.summary.isTruncated)

            try await rig.phoneDecides(approval.id, .allow)
            try await rig.flushPhoneDecisions()
            // Still waiting for a human, and nothing was printed.
            #expect(await rig.pending(count: 1).map(\.id) == [approval.id])

            try await rig.phoneDecides(approval.id, .deny)
            #expect(printed(await hook.value) == denyOutput)
            #expect(await rig.engine.outcome(for: approval.id) == .decided(.deny, .phone))
        }
    }

    /// Questions: a real `buddy-hook --ask` waits for the answer given in Buddy and prints it; when the
    /// app quits while it waits it prints nothing and exits 0.
    @Test func askDrill() async throws {
        let input: JSONValue = .object(["questions": .array([.object([
            "question": .string("Which database?"),
            "header": .string("Database"),
            "options": .array([.object(["label": .string("Postgres")]), .object(["label": .string("SQLite")])]),
            "multiSelect": .bool(false),
        ])])])
        let stdin = Data(json(.object([
            "session_id": .string("s1"),
            "hook_event_name": .string("PreToolUse"),
            "tool_name": .string("AskUserQuestion"),
            "tool_input": input,
        ])).utf8)
        let expected = try #require(HookOutput.stdout(
            for: .answers(["Which database?": "SQLite"]),
            event: HookEvent(sessionId: "s1", name: .preToolUse, toolName: "AskUserQuestion", toolInput: input)))

        try await withDrillEngine { rig in
            let hook = HookProcess.start(stdin: stdin, socket: rig.path, arguments: ["--ask"])
            let question = try #require(await rig.snapshot { $0.questions.count == 1 }?.questions.first)
            #expect(await rig.engine.answer(requestId: question.id, [.options(["SQLite"])]))
            let result = await hook.value
            #expect(!result.killed)
            #expect(result.status == 0)
            // Same JSON (the answer output's key order is not fixed).
            let parsed = { (text: String) in try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? NSObject }
            #expect(parsed(printed(result)).map { $0.isEqual(parsed(expected)) } == true, "printed \(result.stdout)")

            let waiting = HookProcess.start(stdin: stdin, socket: rig.path, arguments: ["--ask"])
            let second = try #require(await rig.snapshot { $0.questions.count == 1 }?.questions.first)
            await rig.engine.stop()  // what quitting the app does
            expectSilent(await waiting.value)
            #expect(await rig.engine.questionOutcome(for: second.id) == .cancelled)
            #expect(await rig.engine.answer(requestId: second.id, [.options(["SQLite"])]) == false)
        }
    }

    /// Checklist F10 (hook must never break Claude Code): garbage or oversized stdin, with a live
    /// app listening. Exit 0, no output, nothing reaches the app, and the next request still works.
    @Test func garbageAndOversizedStdinNeverPrintOrFailAndDoNotDisturbTheApp() async throws {
        try await withDrillEngine { rig in
            let big = String(repeating: "a", count: 5 * 1024 * 1024)
            let inputs: [(String, Data)] = [
                ("not json", Data("this is not json".utf8)),
                ("binary", Data([0xFF, 0xFE, 0x00, 0x01, 0x7B, 0x22, 0x80, 0x0A])),
                ("wrong types", Data(#"{"session_id":1,"hook_event_name":2}"#.utf8)),
                ("oversized junk", Data(big.utf8)),
                ("oversized permission request", Data(
                    #"{"session_id":"big","hook_event_name":"PermissionRequest","tool_name":"Bash","pad":"\#(big)"}"#.utf8)),
            ]
            for (label, input) in inputs {
                let result = await rig.hook(input).value
                #expect(!result.killed, "\(label): hook hung")
                #expect(result.status == 0, "\(label)")
                #expect(printed(result).isEmpty, "\(label): printed \(result.stdout)")
                #expect(result.elapsed < 10, "\(label)")
            }
            // None of it created a session or an approval.
            #expect(await rig.pending(count: 0).isEmpty)
            #expect(await rig.snapshot { $0.sessions.isEmpty } != nil)

            let hook = rig.hook(permission(command: "after the garbage"))
            let approval = try #require(await rig.pending(count: 1).first)
            #expect(await rig.engine.decide(requestId: approval.id, .allow))
            #expect(printed(await hook.value) == allowOutput)
        }
    }
}
