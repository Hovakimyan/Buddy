import Foundation
import Synchronization
import Testing
@testable import BuddyKit

// MARK: - Helpers

private final class TestClock: Sendable {
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

/// What a fake hook process printed (`output == nil` means it printed nothing).
private struct ClientResult: Sendable, Equatable {
    let output: String?
}

/// The client's result, or nil if it did not finish within `timeout` (an upper bound only).
private func within(_ task: Task<ClientResult, Never>, timeout: Duration = .seconds(20)) async -> ClientResult? {
    let (stream, continuation) = AsyncStream<ClientResult>.makeStream()
    Task {
        continuation.yield(await task.value)
        continuation.finish()
    }
    return await firstMatch(in: stream, timeout: timeout) { _ in true }
}

private func shortToken() -> String {
    String(UUID().uuidString.prefix(8)).lowercased()
}

/// Short on purpose: `sockaddr_un` paths are limited to 104 bytes.
private func tempSocketURL() -> URL {
    URL(fileURLWithPath: "/tmp/buddy-e\(shortToken()).sock")
}

private func json(_ value: JSONValue) -> String {
    let data = try! JSONEncoder().encode(value)
    return String(decoding: data, as: UTF8.self)
}

private func eventJSON(
    _ name: String,
    session: String = "s1",
    cwd: String? = nil,
    tool: String? = nil,
    input: JSONValue? = nil,
    agent: String? = nil
) -> String {
    var members: [String: JSONValue] = [
        "session_id": .string(session),
        "hook_event_name": .string(name),
    ]
    if let agent { members["agent_id"] = .string(agent) }
    if let cwd { members["cwd"] = .string(cwd) }
    if let tool { members["tool_name"] = .string(tool) }
    if let input { members["tool_input"] = input }
    return json(.object(members))
}

private func bash(_ command: String) -> JSONValue { .object(["command": .string(command)]) }

private func permissionJSON(session: String = "s1", command: String = "ls") -> String {
    eventJSON("PermissionRequest", session: session, tool: "Bash", input: bash(command))
}

/// An `AskUserQuestion` tool_input with one question.
private func askInput(
    question: String = "Which color?", labels: [String] = ["Red", "Blue"], multiSelect: Bool = false
) -> JSONValue {
    .object(["questions": .array([.object([
        "question": .string(question),
        "header": .string("Color"),
        "options": .array(labels.map { .object(["label": .string($0)]) }),
        "multiSelect": .bool(multiSelect),
    ])])])
}

private func askJSON(session: String = "s1", input: JSONValue = askInput(), agent: String? = nil) -> String {
    eventJSON("PreToolUse", session: session, tool: "AskUserQuestion", input: input, agent: agent)
}

/// What the relay prints for `answers` to the ask whose tool_input is `input`.
private func answerOutput(_ answers: [String: String], input: JSONValue = askInput()) -> String? {
    HookOutput.stdout(
        for: .answers(answers),
        event: HookEvent(sessionId: "s1", name: .preToolUse, toolName: "AskUserQuestion", toolInput: input))
}

/// Whether two printed outputs are the same JSON (the answer output's key order is not fixed).
private func sameJSON(_ a: String?, _ b: String?) -> Bool {
    func parse(_ text: String?) -> NSObject? {
        text.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? NSObject }
    }
    guard let a = parse(a), let b = parse(b) else { return false }
    return a.isEqual(b)
}

private func planOutput(_ choice: PlanChoice) -> String? {
    HookOutput.stdout(for: .plan(choice), event: HookEvent(sessionId: "s", name: .permissionRequest))
}

private let planText = "# Do X\n1. Edit the file\n2. Run the tests"

private func planJSON(session: String = "s1", input: JSONValue? = .object(["plan": .string(planText)])) -> String {
    eventJSON("PermissionRequest", session: session, tool: "ExitPlanMode", input: input)
}

/// Runs the blocking `HookClient` (the fake `buddy-hook`) off the cooperative pool. `ask` is the
/// relay's `--ask` flag.
private func startClient(
    _ json: String, path: URL, ask: Bool = false, waitTimeout: TimeInterval = 25
) -> Task<ClientResult, Never> {
    Task {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                let output = HookClient.run(
                    input: Data(json.utf8), socketPath: path, ask: ask, connectTimeout: 5,
                    waitTimeout: waitTimeout)
                continuation.resume(returning: ClientResult(output: output))
            }
        }
    }
}

/// Sends a non-permission event and waits until the client has delivered it.
private func send(_ json: String, path: URL) async {
    _ = await startClient(json, path: path).value
}

/// Blocking: writes raw bytes on one connection, bypassing `HookClient`'s validation. On macOS a
/// Unix-socket `connect` fails at once with ECONNREFUSED while the listener's backlog is full, so
/// that (and only that) is retried, for at most about 5 s. Returns whether the bytes were sent.
private func deliverRaw(_ bytes: Data, to path: URL) -> Bool {
    for _ in 0..<5_000 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        HookWire.configure(fd)
        let result = HookWire.withAddress(path: path.path) { connect(fd, $0, $1) }
        if result == 0 {
            guard !bytes.isEmpty else { return true }
            return bytes.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) } == bytes.count
        }
        guard errno == ECONNREFUSED else { return false }
        usleep(1_000)
    }
    return false
}

/// Blocking: connects, writes `bytes` and keeps the connection open, like a hook waiting for its
/// reply. Returns the descriptor (the caller closes it), or nil.
private func openWaiting(_ bytes: Data, to path: URL) -> Int32? {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return nil }
    HookWire.configure(fd)
    let connected = HookWire.withAddress(path: path.path) { connect(fd, $0, $1) } == 0
    guard connected, bytes.withUnsafeBytes({ write(fd, $0.baseAddress, $0.count) }) == bytes.count else {
        close(fd)
        return nil
    }
    return fd
}

/// Blocking: writes `bytes` on one connection and reads until the server closes it. Returns what the
/// server wrote (empty for no reply), or nil if it could not connect or was still silent after 5 s.
private func exchangeRaw(_ bytes: Data, to path: URL) -> Data? {
    guard let fd = openWaiting(bytes, to: path) else { return nil }
    defer { close(fd) }
    var reply = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    while true {
        var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        guard poll(&pfd, 1, 5_000) > 0 else { return nil }
        let count = read(fd, &buffer, buffer.count)
        guard count > 0 else { return reply }
        reply.append(contentsOf: buffer[0..<count])
    }
}

/// The hook JSON with the relay's `"buddy_ask": true` mark added, as one line.
private func markedAsAsk(_ json: String) -> Data {
    Data((json.dropLast() + #","buddy_ask":true}"# + "\n").utf8)
}

/// Writes raw bytes to the socket, bypassing `HookClient`'s validation.
private func sendRaw(_ bytes: Data, to path: URL) async {
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        DispatchQueue.global().async {
            _ = deliverRaw(bytes, to: path)
            continuation.resume()
        }
    }
}

private let allowOutput = HookOutput.stdout(for: .decision(.allow), event: HookEvent(sessionId: "s", name: .permissionRequest))
private let denyOutput = HookOutput.stdout(for: .decision(.deny), event: HookEvent(sessionId: "s", name: .permissionRequest))

private struct Rig {
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

    /// Waits for exactly `count` pending questions and returns them in submission order.
    func questions(count: Int) async -> [PendingQuestion] {
        await snapshot { $0.questions.count == count }?.questions ?? []
    }

    func phoneDecides(_ id: UUID, _ d: Decision, at date: Date = Date()) async throws {
        try await cloud.phoneSide.submit(decision: DecisionRecord(
            requestId: id, decision: d, decidedAt: date, source: .phone))
    }

    /// Phone decisions are applied in order, so once one for a fresh sentinel request has landed,
    /// every decision sent before it has been considered.
    func flushPhoneDecisions() async throws {
        let client = startClient(permissionJSON(session: "sentinel", command: "sentinel"), path: path)
        let sentinel = try #require(await snapshot { snapshot in
            snapshot.pending.contains { $0.sessionId == "sentinel" }
        }?.pending.first { $0.sessionId == "sentinel" })
        try await phoneDecides(sentinel.id, .deny)
        #expect(await within(client) == ClientResult(output: denyOutput))
    }
}

/// Starts an engine on a fresh short socket path, runs `body`, then always stops it and removes
/// the socket file.
private func withEngine(
    useTransport: Bool = true,
    approvalTimeout: TimeInterval = BuddyEngine.defaultApprovalTimeout,
    clock: (@Sendable () -> Date)? = nil,
    tickInterval: TimeInterval = 1,
    questionTimeout: TimeInterval = BuddyEngine.defaultQuestionTimeout,
    canAskInBuddy: @escaping @Sendable () async -> Bool = { true },
    _ body: (Rig) async throws -> Void
) async throws {
    let path = tempSocketURL()
    let cloud = InMemoryCloud()
    let engine = BuddyEngine(
        socketPath: path,
        transport: useTransport ? cloud.macSide : nil,
        approvalTimeout: approvalTimeout,
        clock: clock ?? { Date() },
        tickInterval: tickInterval,
        questionTimeout: questionTimeout,
        canAskInBuddy: canAskInBuddy)
    try await engine.start()
    do {
        try await body(Rig(engine: engine, path: path, cloud: cloud))
    } catch {
        await engine.stop()
        try? FileManager.default.removeItem(at: path)
        throw error
    }
    await engine.stop()
    try? FileManager.default.removeItem(at: path)
}

// MARK: - Suite

@Suite struct BuddyEngineTests {
    @Test func startedSessionAppearsInSnapshot() async throws {
        try await withEngine { rig in
            await send(eventJSON("SessionStart", cwd: "/Users/me/code/buddy"), path: rig.path)
            let snapshot = await rig.snapshot { !$0.sessions.isEmpty }
            let session = try #require(snapshot?.sessions.first)
            #expect(session.id == "s1")
            #expect(session.project == "buddy")
            #expect(session.state == .idle)
            #expect(snapshot?.pending == [])

            let mirrored = await firstMatch(in: rig.cloud.phoneSide.sessions()) { !$0.isEmpty }
            #expect(mirrored?.map(\.sessionId) == ["s1"])
            #expect(mirrored?.first?.project == "buddy")
        }
    }

    @Test func permissionRequestAllowedFromMac() async throws {
        try await withEngine { rig in
            let client = startClient(permissionJSON(command: "git status"), path: rig.path)
            let approval = try #require(await rig.pending(count: 1).first)
            #expect(approval.sessionId == "s1")
            #expect(approval.toolName == "Bash")
            #expect(approval.toolInput == bash("git status"))
            #expect(approval.summary.text == "git status")
            #expect(approval.expiresAt == approval.createdAt.addingTimeInterval(600))

            let waiting = await rig.snapshot { $0.sessions.first?.state == .waiting }
            #expect(waiting != nil)

            #expect(await rig.engine.decide(requestId: approval.id, .allow))
            #expect(await within(client) == ClientResult(output: allowOutput))
            #expect(await rig.engine.outcome(for: approval.id) == .decided(.allow, .mac))
            #expect(await rig.engine.decide(requestId: approval.id, .deny) == false)
            #expect(await rig.snapshot { $0.pending.isEmpty } != nil)
        }
    }

    @Test func permissionRequestDeniedFromPhone() async throws {
        try await withEngine { rig in
            let client = startClient(permissionJSON(), path: rig.path)
            let approval = try #require(await rig.pending(count: 1).first)

            let mirrored = await firstMatch(in: rig.cloud.phoneSide.approvals()) { records in
                records.contains { $0.requestId == approval.id && $0.status == .pending }
            }
            #expect(mirrored != nil)

            try await rig.phoneDecides(approval.id, .deny)
            #expect(await within(client) == ClientResult(output: denyOutput))
            #expect(await rig.engine.outcome(for: approval.id) == .decided(.deny, .phone))
        }
    }

    @Test func macAnswersFirstPhoneLateIgnored() async throws {
        try await withEngine { rig in
            let first = startClient(permissionJSON(command: "make"), path: rig.path)
            let approval = try #require(await rig.pending(count: 1).first)
            #expect(await rig.engine.decide(requestId: approval.id, .allow))
            #expect(await within(first) == ClientResult(output: allowOutput))

            // The phone's late answer must not change anything.
            try await rig.phoneDecides(approval.id, .deny)

            // Sentinel: phone decisions are applied in order, so once this later one has landed
            // the late one has already been considered.
            let second = startClient(permissionJSON(command: "make test"), path: rig.path)
            let sentinel = try #require(await rig.pending(count: 1).first)
            #expect(sentinel.id != approval.id)
            try await rig.phoneDecides(sentinel.id, .deny)
            #expect(await within(second) == ClientResult(output: denyOutput))

            #expect(await rig.engine.outcome(for: approval.id) == .decided(.allow, .mac))
            #expect(await rig.engine.outcome(for: sentinel.id) == .decided(.deny, .phone))
        }
    }

    @Test func defaultApprovalTimeoutEndsBeforeTheRelayStopsWaiting() {
        #expect(BuddyEngine.defaultApprovalTimeout == 600)
        #expect(HookClient.defaultWaitTimeout == 610)
        #expect(BuddyEngine.defaultApprovalTimeout < HookClient.defaultWaitTimeout)
    }

    @Test func timeoutPrintsNothing() async throws {
        try await withEngine(approvalTimeout: 0.5, tickInterval: 0.1) { rig in
            // Subscribe before the client starts: the stream buffers, so the short-lived
            // "one pending" snapshot cannot be missed however slowly this task gets scheduled
            // relative to the 0.5 s expiry.
            let snapshots = await rig.engine.snapshots()
            let client = startClient(permissionJSON(), path: rig.path)
            let approval = try #require(
                await firstMatch(in: snapshots) { $0.pending.count == 1 }?.pending.first)
            #expect(await within(client) == ClientResult(output: nil))
            #expect(await rig.engine.outcome(for: approval.id) == .expired)
            #expect(await rig.snapshot { $0.pending.isEmpty } != nil)
            #expect(await rig.engine.decide(requestId: approval.id, .allow) == false)
        }
    }

    @Test func macDecisionPastExpiryBeforeTickIsRejected() async throws {
        let clock = TestClock(Date(timeIntervalSince1970: 1_800_000_000))
        // The timer never fires during the test, so only `decide` itself can notice the expiry.
        try await withEngine(approvalTimeout: 10, clock: { clock.now }, tickInterval: 1_000_000) { rig in
            let client = startClient(permissionJSON(), path: rig.path)
            let approval = try #require(await rig.pending(count: 1).first)

            clock.advance(by: 11)
            #expect(await rig.engine.decide(requestId: approval.id, .allow) == false)
            #expect(await within(client) == ClientResult(output: nil))
            #expect(await rig.engine.outcome(for: approval.id) == .expired)
        }
    }

    @Test func terminalAnsweredFirstCancels() async throws {
        try await withEngine { rig in
            let client = startClient(permissionJSON(command: "rm -rf build"), path: rig.path)
            let approval = try #require(await rig.pending(count: 1).first)

            await send(
                eventJSON("PostToolUse", tool: "Bash", input: bash("rm -rf build")), path: rig.path)
            #expect(await within(client) == ClientResult(output: nil))
            #expect(await rig.engine.outcome(for: approval.id) == .cancelled)
            #expect(await rig.snapshot { $0.pending.isEmpty } != nil)
        }
    }

    @Test func postToolUseOfDifferentToolDoesNotCancel() async throws {
        try await withEngine { rig in
            let client = startClient(permissionJSON(command: "ls"), path: rig.path)
            let approval = try #require(await rig.pending(count: 1).first)

            // Other tool name. The engine updates the session only after its cancellation check,
            // so seeing the session change means the check has run.
            await send(
                eventJSON("PostToolUse", tool: "Read", input: .object(["file_path": .string("/a")])),
                path: rig.path)
            #expect(await rig.snapshot { $0.sessions.first?.lastTool == "Read" } != nil)

            // Same tool, different input.
            await send(eventJSON("PostToolUseFailure", tool: "Bash", input: bash("pwd")), path: rig.path)
            #expect(await rig.snapshot { $0.sessions.first?.lastTool == "Bash" } != nil)

            // Same tool and input but another session.
            await send(
                eventJSON("PostToolUse", session: "other", tool: "Bash", input: bash("ls")), path: rig.path)
            #expect(await rig.snapshot { $0.sessions.contains { $0.id == "other" } } != nil)

            #expect(await rig.engine.decide(requestId: approval.id, .allow))
            #expect(await within(client) == ClientResult(output: allowOutput))
        }
    }

    @Test func postToolUseDifferingOnlyInToolNameDoesNotCancel() async throws {
        try await withEngine { rig in
            let client = startClient(permissionJSON(command: "ls"), path: rig.path)
            let approval = try #require(await rig.pending(count: 1).first)

            // Same session and identical tool_input, but another tool. Only the tool name differs,
            // so the cancellation check must reject it on that alone. The engine updates the
            // session only after the check, so seeing `lastTool == "Write"` means it has run.
            await send(eventJSON("PostToolUse", tool: "Write", input: bash("ls")), path: rig.path)
            #expect(await rig.snapshot { $0.sessions.first?.lastTool == "Write" } != nil)
            #expect(await rig.pending(count: 1).map(\.id) == [approval.id])

            #expect(await rig.engine.decide(requestId: approval.id, .allow))
            #expect(await within(client) == ClientResult(output: allowOutput))
            #expect(await rig.engine.outcome(for: approval.id) == .decided(.allow, .mac))
        }
    }

    @Test func sessionEndCancelsPending() async throws {
        try await withEngine { rig in
            let first = startClient(permissionJSON(command: "a"), path: rig.path)
            let approval = try #require(await rig.pending(count: 1).first)

            await send(eventJSON("SessionEnd"), path: rig.path)
            #expect(await within(first) == ClientResult(output: nil))
            #expect(await rig.engine.outcome(for: approval.id) == .cancelled)
            #expect(await rig.snapshot { $0.pending.isEmpty && $0.sessions.isEmpty } != nil)
        }
    }

    // The person answered "no" (or Esc) at the terminal prompt: Claude Code stops the hook and sends
    // no other event. The closed connection alone must clear the card and the phone record.
    @Test func hookThatGoesAwayClearsItsApprovalAtOnce() async throws {
        try await withEngine { rig in
            let line = Data((permissionJSON(command: "rm -rf build") + "\n").utf8)
            let fd = try #require(await withCheckedContinuation { (continuation: CheckedContinuation<Int32?, Never>) in
                DispatchQueue.global().async { continuation.resume(returning: openWaiting(line, to: rig.path)) }
            })
            let approval = try #require(await rig.pending(count: 1).first)
            #expect(await firstMatch(in: rig.cloud.phoneSide.approvals()) { records in
                records.contains { $0.requestId == approval.id && $0.status == .pending }
            } != nil)

            let started = Date()
            close(fd)
            #expect(await rig.snapshot { $0.pending.isEmpty } != nil)
            #expect(Date().timeIntervalSince(started) < 1, "the card stayed up after the hook went away")
            #expect(await rig.engine.outcome(for: approval.id) == .cancelled)
            #expect(await rig.engine.decide(requestId: approval.id, .allow) == false)
            #expect(await firstMatch(in: rig.cloud.phoneSide.approvals()) { records in
                records.contains { $0.requestId == approval.id && $0.status == .resolved }
            } != nil)

            // A phone allow arriving now changes nothing, and the engine keeps working.
            try await rig.phoneDecides(approval.id, .allow)
            let next = startClient(permissionJSON(command: "ls"), path: rig.path)
            let sentinel = try #require(await rig.pending(count: 1).first)
            #expect(await rig.engine.decide(requestId: sentinel.id, .deny))
            #expect(await within(next) == ClientResult(output: denyOutput))
            #expect(await rig.engine.outcome(for: approval.id) == .cancelled)
        }
    }

    @Test func aNewerEventOfTheSessionCancelsItsOlderRequest() async throws {
        let events: [(String, String)] = [
            ("PermissionRequest", permissionJSON(command: "newer")),
            ("PreToolUse", eventJSON("PreToolUse", tool: "Bash", input: bash("other"))),
            ("UserPromptSubmit", eventJSON("UserPromptSubmit")),
            ("Stop", eventJSON("Stop")),
        ]
        for (name, json) in events {
            try await withEngine { rig in
                let older = startClient(permissionJSON(command: "older"), path: rig.path)
                let bystander = startClient(permissionJSON(session: "other", command: "older"), path: rig.path)
                let approvals = await rig.pending(count: 2)
                let stale = try #require(approvals.first { $0.sessionId == "s1" }, "\(name)")
                let kept = try #require(approvals.first { $0.sessionId == "other" }, "\(name)")

                let newer = startClient(json, path: rig.path)
                #expect(await within(older) == ClientResult(output: nil), "\(name)")
                #expect(await rig.engine.outcome(for: stale.id) == .cancelled, "\(name)")

                // The other session is untouched; a newer request is the one now waiting.
                let replaced = name == "PermissionRequest"
                let pending = await rig.snapshot { snapshot in
                    !snapshot.pending.contains { $0.id == stale.id }
                        && (!replaced || snapshot.pending.contains { $0.sessionId == "s1" })
                }?.pending ?? []
                #expect(pending.contains { $0.id == kept.id }, "\(name)")
                if replaced {
                    let fresh = try #require(pending.first { $0.sessionId == "s1" }, "\(name)")
                    #expect(fresh.summary.text == "newer")
                    #expect(await rig.engine.decide(requestId: fresh.id, .deny))
                    #expect(await within(newer) == ClientResult(output: denyOutput))
                } else {
                    #expect(await within(newer) == ClientResult(output: nil), "\(name)")
                }
                #expect(await rig.engine.decide(requestId: kept.id, .allow), "\(name)")
                #expect(await within(bystander) == ClientResult(output: allowOutput), "\(name)")
            }
        }
    }

    @Test func preToolUseOfTheSameCallKeepsItsRequest() async throws {
        // Permission requests skip the ordered event line, so the PreToolUse that came before a request
        // can be handled after it. It must not cancel the request it belongs to.
        try await withEngine { rig in
            let client = startClient(permissionJSON(command: "make"), path: rig.path)
            let approval = try #require(await rig.pending(count: 1).first)
            await send(eventJSON("PreToolUse", tool: "Bash", input: bash("make")), path: rig.path)
            #expect(await rig.snapshot { $0.sessions.first?.state == .working } != nil)
            #expect(await rig.pending(count: 1).map(\.id) == [approval.id])
            #expect(await rig.engine.decide(requestId: approval.id, .allow))
            #expect(await within(client) == ClientResult(output: allowOutput))
        }
    }

    @Test func parallelSubagentsKeepEachOthersRequests() async throws {
        // Subagents of one session run at the same time and share its session_id. One of them moving on
        // (a newer request, a PreToolUse of another call) says nothing about the other's request.
        try await withEngine { rig in
            let first = startClient(
                eventJSON("PermissionRequest", tool: "Bash", input: bash("a"), agent: "agent-1"), path: rig.path)
            let second = startClient(
                eventJSON("PermissionRequest", tool: "Bash", input: bash("b"), agent: "agent-2"), path: rig.path)
            let approvals = await rig.pending(count: 2)
            let one = try #require(approvals.first { $0.agentId == "agent-1" })
            let two = try #require(approvals.first { $0.agentId == "agent-2" })

            await send(eventJSON("PreToolUse", tool: "Read", input: bash("x"), agent: "agent-2"), path: rig.path)
            // agent-2's own older request goes; agent-1's stays.
            #expect(await within(second) == ClientResult(output: nil))
            #expect(await rig.engine.outcome(for: two.id) == .cancelled)
            #expect(await rig.pending(count: 1).map(\.id) == [one.id])

            // A request from the main conversation does not replace a subagent's either.
            let main = startClient(permissionJSON(command: "main"), path: rig.path)
            let both = await rig.pending(count: 2)
            #expect(both.contains { $0.id == one.id })
            let mainApproval = try #require(both.first { $0.agentId == nil })

            #expect(await rig.engine.decide(requestId: one.id, .allow))
            #expect(await within(first) == ClientResult(output: allowOutput))
            #expect(await rig.engine.decide(requestId: mainApproval.id, .deny))
            #expect(await within(main) == ClientResult(output: denyOutput))
        }
    }

    @Test func backgroundSubagentRequestSurvivesTheMainTurnEnding() async throws {
        // Background subagents outlive the main turn: Claude Code sends Stop (and may submit the next prompt) while
        // one of them still waits on a permission request. That request is still open in the terminal.
        try await withEngine { rig in
            let client = startClient(
                eventJSON("PermissionRequest", tool: "Bash", input: bash("a"), agent: "agent-1"), path: rig.path)
            let approval = try #require(await rig.pending(count: 1).first)
            await send(eventJSON("Stop"), path: rig.path)
            await send(eventJSON("UserPromptSubmit"), path: rig.path)
            await send(eventJSON("StopFailure"), path: rig.path)
            #expect(await rig.pending(count: 1).map(\.id) == [approval.id])
            #expect(await rig.engine.decide(requestId: approval.id, .allow))
            #expect(await within(client) == ClientResult(output: allowOutput))
        }
    }

    @Test func subagentStopCancelsOnlyThatSubagentsRequests() async throws {
        try await withEngine { rig in
            let gone = startClient(
                eventJSON("PermissionRequest", tool: "Bash", input: bash("a"), agent: "agent-1"), path: rig.path)
            let stays = startClient(
                eventJSON("PermissionRequest", tool: "Bash", input: bash("b"), agent: "agent-2"), path: rig.path)
            let approvals = await rig.pending(count: 2)
            let keep = try #require(approvals.first { $0.agentId == "agent-2" })
            let asked = startClient(askJSON(agent: "agent-1"), path: rig.path, ask: true)
            let question = try #require(await rig.questions(count: 1).first)

            await send(eventJSON("SubagentStop", agent: "agent-1"), path: rig.path)
            #expect(await within(gone) == ClientResult(output: nil))
            #expect(await within(asked) == ClientResult(output: nil))
            #expect(await rig.engine.questionOutcome(for: question.id) == .cancelled)
            #expect(await rig.pending(count: 1).map(\.id) == [keep.id])
            #expect(await rig.engine.decide(requestId: keep.id, .deny))
            #expect(await within(stays) == ClientResult(output: denyOutput))
        }
    }

    @Test func stopAndStopFailureCancelOnlyThatSession() async throws {
        try await withEngine { rig in
            for (event, session) in [("Stop", "a"), ("StopFailure", "b")] {
                let client = startClient(permissionJSON(session: session), path: rig.path)
                let bystander = startClient(permissionJSON(session: "keep-\(session)"), path: rig.path)
                let approvals = await rig.pending(count: 2)
                let keep = try #require(approvals.first { $0.sessionId == "keep-\(session)" })

                await send(eventJSON(event, session: session), path: rig.path)
                #expect(await within(client) == ClientResult(output: nil))
                #expect(await rig.engine.decide(requestId: keep.id, .deny))
                #expect(await within(bystander) == ClientResult(output: denyOutput))
                #expect(await rig.snapshot { $0.pending.isEmpty } != nil)
            }
        }
    }

    @Test func twoSessionsIndependent() async throws {
        try await withEngine { rig in
            let one = startClient(permissionJSON(session: "one", command: "x"), path: rig.path)
            let two = startClient(permissionJSON(session: "two", command: "x"), path: rig.path)
            let approvals = await rig.pending(count: 2)
            let a = try #require(approvals.first { $0.sessionId == "one" })
            let b = try #require(approvals.first { $0.sessionId == "two" })

            // Terminal answer in session one (same tool + input) must not touch session two.
            await send(eventJSON("PostToolUse", session: "one", tool: "Bash", input: bash("x")), path: rig.path)
            #expect(await within(one) == ClientResult(output: nil))
            #expect(await rig.engine.outcome(for: a.id) == .cancelled)

            let remaining = await rig.pending(count: 1)
            #expect(remaining.map(\.id) == [b.id])
            try await rig.phoneDecides(b.id, .allow)
            #expect(await within(two) == ClientResult(output: allowOutput))

            let snapshot = await rig.snapshot { $0.sessions.count == 2 && $0.pending.isEmpty }
            #expect(Set(snapshot?.sessions.map(\.id) ?? []) == ["one", "two"])
        }
    }

    @Test func questionPermissionRequestStaysInTheTerminal() async throws {
        // Questions are answered through the `--ask` PreToolUse hook, never as a permission request:
        // the hook prints nothing at once and Claude Code asks in the terminal.
        for tool in ["AskUserQuestion"] {
            try await withEngine { rig in
                let snapshots = await rig.engine.snapshots()
                let client = startClient(
                    eventJSON("PermissionRequest", session: "q", tool: tool, input: askInput()), path: rig.path)
                #expect(await within(client, timeout: .seconds(5)) == ClientResult(output: nil), "\(tool)")
                #expect(await rig.snapshot { $0.sessions.first?.state == .waiting } != nil, "\(tool)")

                // A sentinel request: once it is pending, every earlier snapshot has been seen.
                let sentinel = startClient(permissionJSON(session: "sentinel"), path: rig.path)
                let seen = Mutex<[[PendingApproval]]>([])
                _ = await firstMatch(in: snapshots) { snapshot in
                    seen.withLock { $0.append(snapshot.pending) }
                    return snapshot.pending.contains { $0.sessionId == "sentinel" }
                }
                let shown = seen.withLock { $0 }.flatMap { $0 }.filter { $0.sessionId == "q" }
                #expect(shown.isEmpty, "\(tool) was shown for approval")
                let records = await firstMatch(in: rig.cloud.phoneSide.approvals()) { !$0.isEmpty } ?? []
                #expect(records.allSatisfy { $0.sessionId == "sentinel" }, "\(tool) reached the phone")

                let approval = try #require(await rig.pending(count: 1).first)
                #expect(await rig.engine.decide(requestId: approval.id, .deny))
                #expect(await within(sentinel) == ClientResult(output: denyOutput))
            }
        }
    }

    // MARK: Questions

    @Test func askEventShowsQuestionAndAnswers() async throws {
        try await withEngine { rig in
            let client = startClient(askJSON(), path: rig.path, ask: true)
            let question = try #require(await rig.questions(count: 1).first)
            #expect(question.sessionId == "s1")
            #expect(question.agentId == nil)
            #expect(question.questions == AskQuestion.parseSet(toolInput: askInput()))
            #expect(question.expiresAt == question.createdAt.addingTimeInterval(600))
            // A question is not an approval: nothing for the approval card or the phone.
            #expect(await rig.snapshot { _ in true }?.pending == [])

            #expect(await rig.engine.answer(requestId: question.id, [.options(["Blue"])]))
            #expect(sameJSON(await within(client)?.output, answerOutput(["Which color?": "Blue"])))
            #expect(await rig.engine.questionOutcome(for: question.id) == .answered(["Which color?": "Blue"], .mac))
            #expect(await rig.engine.answer(requestId: question.id, [.options(["Red"])]) == false)
            #expect(await rig.snapshot { $0.questions.isEmpty } != nil)
        }
    }

    // The bridge reaches the engine's own question queue: the phone sees the question and its answer is applied.
    @Test func phoneSeesQuestionAndPhoneAnswerIsApplied() async throws {
        try await withEngine { rig in
            let client = startClient(askJSON(), path: rig.path, ask: true)
            let question = try #require(await rig.questions(count: 1).first)
            let mirrored = await firstMatch(in: rig.cloud.phoneSide.questions()) { records in
                records.contains { $0.requestId == question.id && $0.status == .pending }
            }
            #expect(mirrored?.first?.questions == question.questions)

            try await rig.cloud.phoneSide.submit(answer: AnswerRecord(
                requestId: question.id, responses: [["Blue"]], answeredAt: Date()))
            #expect(sameJSON(await within(client)?.output, answerOutput(["Which color?": "Blue"])))
            #expect(await rig.engine.questionOutcome(for: question.id) == .answered(["Which color?": "Blue"], .phone))
            #expect(await firstMatch(in: rig.cloud.phoneSide.questions()) { records in
                records.contains { $0.requestId == question.id && $0.status == .resolved }
            } != nil)
        }
    }

    @Test func multiSelectAnswerJoinsLabelsInOptionOrder() async throws {
        try await withEngine { rig in
            let input = askInput(question: "Which ones?", labels: ["A", "B", "C"], multiSelect: true)
            let client = startClient(askJSON(input: input), path: rig.path, ask: true)
            let question = try #require(await rig.questions(count: 1).first)
            #expect(await rig.engine.answer(requestId: question.id, [.options(["C", "A"])]))
            #expect(sameJSON(await within(client)?.output, answerOutput(["Which ones?": "A, C"], input: input)))
        }
    }

    @Test func answerValidationAppliesToMac() async throws {
        try await withEngine { rig in
            let client = startClient(askJSON(), path: rig.path, ask: true)
            let question = try #require(await rig.questions(count: 1).first)

            for invalid: [QuestionResponse] in [
                [.options(["Green"])],  // not one of the options
                [.options(["Red", "Blue"])],  // two labels for a single-select question
                [.options(["Red"]), .options(["Blue"])],  // one response too many
                [],  // none
                [.text("  ")],  // blank free text
            ] {
                #expect(await rig.engine.answer(requestId: question.id, invalid) == false, "\(invalid)")
            }
            #expect(await rig.engine.answer(requestId: UUID(), [.options(["Red"])]) == false)
            #expect(await rig.questions(count: 1).map(\.id) == [question.id])

            // Free text is the Mac's "Other...".
            #expect(await rig.engine.answer(requestId: question.id, [.text("Green")]))
            #expect(sameJSON(await within(client)?.output, answerOutput(["Which color?": "Green"])))
        }
    }

    /// An answer whose reply line would not fit `HookWire.maxReplyBytes` would reach the hook as "no reply": it is
    /// refused, so the Mac does not count it, and the question still waits.
    @Test func aMacAnswerTooLongForTheReplyIsRefused() async throws {
        try await withEngine { rig in
            let client = startClient(askJSON(), path: rig.path, ask: true)
            let question = try #require(await rig.questions(count: 1).first)
            let huge = String(repeating: "x", count: HookWire.maxReplyBytes)
            #expect(await rig.engine.answer(requestId: question.id, [.text(huge)]) == false)
            #expect(await rig.questions(count: 1).map(\.id) == [question.id])
            #expect(await rig.engine.questionOutcome(for: question.id) == nil)
            #expect(await rig.engine.answer(requestId: question.id, [.text("Green")]))
            #expect(sameJSON(await within(client)?.output, answerOutput(["Which color?": "Green"])))
        }
    }

    @Test func invalidQuestionsReturnNil() async throws {
        try await withEngine { rig in
            let malformed: [JSONValue?] = [
                askInput(labels: ["Only"]),  // one option
                .object(["questions": .array([])]),
                .object([:]),
                nil,
            ]
            for input in malformed {
                let client = startClient(
                    eventJSON("PreToolUse", tool: "AskUserQuestion", input: input), path: rig.path, ask: true)
                #expect(await within(client, timeout: .seconds(5)) == ClientResult(output: nil), "\(String(describing: input))")
            }
            // The handler is done once the client has returned, and none of them was shown.
            #expect(await rig.snapshot { _ in true }?.questions == [])
        }
    }

    @Test func askDisabledReturnsNil() async throws {
        let calls = Mutex(0)
        try await withEngine(canAskInBuddy: { calls.withLock { $0 += 1 }; return false }) { rig in
            let client = startClient(askJSON(), path: rig.path, ask: true)
            #expect(await within(client, timeout: .seconds(5)) == ClientResult(output: nil))
            #expect(await rig.snapshot { _ in true }?.questions == [])
            #expect(calls.withLock { $0 } == 1)
        }
    }

    @Test func askOnAnyOtherToolOrEventDoesNotWait() async throws {
        // A raw `buddy_ask` mark on something that is not an AskUserQuestion PreToolUse changes nothing:
        // the event is handled as it would be without it, and nothing waits.
        let asked = Mutex(0)
        try await withEngine(canAskInBuddy: { asked.withLock { $0 += 1 }; return true }) { rig in
            let approvalClient = startClient(permissionJSON(command: "older"), path: rig.path)
            let approval = try #require(await rig.pending(count: 1).first)

            let marked = [
                markedAsAsk(eventJSON("PostToolUse", tool: "AskUserQuestion", input: askInput())),
                markedAsAsk(eventJSON("PreToolUse", tool: "Read", input: .object(["file_path": .string("/a")]))),
            ]
            for line in marked {
                let reply = await withCheckedContinuation { continuation in
                    DispatchQueue.global().async { continuation.resume(returning: exchangeRaw(line, to: rig.path)) }
                }
                #expect(reply == Data())
            }
            // The PreToolUse of another call still moved the asker on, like a plain one.
            #expect(await within(approvalClient) == ClientResult(output: nil))
            #expect(await rig.engine.outcome(for: approval.id) == .cancelled)
            #expect(await rig.snapshot { $0.sessions.first?.lastTool == "Read" } != nil)
            #expect(await rig.snapshot { _ in true }?.questions == [])
            #expect(asked.withLock { $0 } == 0)
        }
    }

    @Test func releaseReturnsNil() async throws {
        try await withEngine { rig in
            let client = startClient(askJSON(), path: rig.path, ask: true)
            let question = try #require(await rig.questions(count: 1).first)
            await rig.engine.releaseQuestion(requestId: question.id)
            #expect(await within(client) == ClientResult(output: nil))
            #expect(await rig.engine.questionOutcome(for: question.id) == .released)
            #expect(await rig.snapshot { $0.questions.isEmpty } != nil)
            #expect(await rig.engine.answer(requestId: question.id, [.options(["Red"])]) == false)
        }
    }

    /// The island tells how a question it showed ended ("Answered in iPhone.", "Still waiting in the terminal."), so
    /// every snapshot carries the recent outcomes with the asking session and when each happened.
    @Test func snapshotsCarryRecentQuestionOutcomes() async throws {
        let clock = TestClock(Date(timeIntervalSince1970: 1_800_000_000))
        try await withEngine(clock: { clock.now }, tickInterval: 1_000_000) { rig in
            let first = startClient(askJSON(session: "a"), path: rig.path, ask: true)
            let answered = try #require(await rig.questions(count: 1).first)
            clock.advance(by: 3)
            try await rig.cloud.phoneSide.submit(answer: AnswerRecord(
                requestId: answered.id, responses: [["Blue"]], answeredAt: Date()))
            _ = await within(first)
            let afterAnswer = await rig.snapshot { !$0.recentQuestionOutcomes.isEmpty }
            #expect(afterAnswer?.recentQuestionOutcomes == [QuestionOutcomeRecord(
                id: answered.id, sessionId: "a", outcome: .answered(["Which color?": "Blue"], .phone),
                at: clock.now)])

            let second = startClient(askJSON(session: "b"), path: rig.path, ask: true)
            let released = try #require(await rig.snapshot { $0.questions.count == 1 }?.questions.first)
            await rig.engine.releaseQuestion(requestId: released.id)
            _ = await within(second)
            let both = await rig.snapshot { $0.recentQuestionOutcomes.count == 2 }
            #expect(both?.recentQuestionOutcomes.map(\.id) == [answered.id, released.id])
            #expect(both?.recentQuestionOutcomes.last?.outcome == .released)
            #expect(both?.recentQuestionOutcomes.last?.sessionId == "b")
        }
    }

    @Test func questionExpiresAt600s() async throws {
        #expect(BuddyEngine.defaultQuestionTimeout == 600)
        #expect(BuddyEngine.defaultQuestionTimeout < HookClient.askWaitTimeout)
        let clock = TestClock(Date(timeIntervalSince1970: 1_800_000_000))
        // The timer never fires during the test, so only `answer` itself can notice the expiry.
        try await withEngine(clock: { clock.now }, tickInterval: 1_000_000) { rig in
            let client = startClient(askJSON(), path: rig.path, ask: true)
            let question = try #require(await rig.questions(count: 1).first)
            #expect(question.expiresAt == question.createdAt.addingTimeInterval(600))

            clock.advance(by: 599)
            #expect(await rig.engine.answer(requestId: question.id, [.options(["Green"])]) == false)
            #expect(await rig.questions(count: 1).map(\.id) == [question.id])

            clock.advance(by: 1)
            #expect(await rig.engine.answer(requestId: question.id, [.options(["Red"])]) == false)
            #expect(await within(client) == ClientResult(output: nil))
            #expect(await rig.engine.questionOutcome(for: question.id) == .expired)
        }
    }

    @Test func questionTimerExpiryPrintsNothing() async throws {
        try await withEngine(tickInterval: 0.1, questionTimeout: 0.5) { rig in
            let snapshots = await rig.engine.snapshots()
            let client = startClient(askJSON(), path: rig.path, ask: true)
            let question = try #require(
                await firstMatch(in: snapshots) { $0.questions.count == 1 }?.questions.first)
            #expect(await within(client) == ClientResult(output: nil))
            #expect(await rig.engine.questionOutcome(for: question.id) == .expired)
            #expect(await rig.snapshot { $0.questions.isEmpty } != nil)
        }
    }

    @Test func plainPreToolUseForSameCallKeepsAsk() async throws {
        try await withEngine { rig in
            let client = startClient(askJSON(), path: rig.path, ask: true)
            let question = try #require(await rig.questions(count: 1).first)

            // The `*` group fires for the very same call without `--ask`. The engine updates the session
            // only after its cancellation check, so seeing the session change means the check has run.
            let plain = startClient(askJSON(), path: rig.path)
            #expect(await within(plain, timeout: .seconds(5)) == ClientResult(output: nil))
            #expect(await rig.snapshot { $0.sessions.first?.lastTool == "AskUserQuestion" } != nil)
            #expect(await rig.questions(count: 1).map(\.id) == [question.id])

            // A parallel subagent moving on, and another session ending, say nothing about this asker.
            await send(eventJSON("PreToolUse", tool: "Read", input: bash("x"), agent: "agent-1"), path: rig.path)
            #expect(await rig.snapshot { $0.sessions.first?.agents.first?.lastTool == "Read" } != nil)
            #expect(await rig.snapshot { _ in true }?.sessions.first?.lastTool == "AskUserQuestion")
            await send(eventJSON("Stop", session: "other"), path: rig.path)
            #expect(await rig.snapshot { $0.sessions.contains { $0.id == "other" } } != nil)
            // The terminal finishing another AskUserQuestion call is not this one.
            await send(
                eventJSON("PostToolUse", tool: "AskUserQuestion", input: askInput(question: "Other?")), path: rig.path)
            #expect(await rig.snapshot { $0.sessions.first?.state == .working } != nil)
            #expect(await rig.questions(count: 1).map(\.id) == [question.id])

            #expect(await rig.engine.answer(requestId: question.id, [.options(["Red"])]))
            #expect(sameJSON(await within(client)?.output, answerOutput(["Which color?": "Red"])))
        }
    }

    @Test func laterEventsOfTheAskerCancelTheAsk() async throws {
        let events: [(String, String)] = [
            ("PreToolUse of another tool", eventJSON("PreToolUse", tool: "Bash", input: bash("ls"))),
            ("PreToolUse of other questions", askJSON(input: askInput(question: "Other?"))),
            ("UserPromptSubmit", eventJSON("UserPromptSubmit")),
            ("Stop", eventJSON("Stop")),
            ("SessionEnd", eventJSON("SessionEnd")),
            ("PostToolUse of the same call", eventJSON("PostToolUse", tool: "AskUserQuestion", input: askInput())),
            ("PermissionRequest", permissionJSON(command: "newer")),
        ]
        for (name, json) in events {
            try await withEngine { rig in
                let client = startClient(askJSON(), path: rig.path, ask: true)
                let bystander = startClient(askJSON(session: "other"), path: rig.path, ask: true)
                let questions = await rig.questions(count: 2)
                let stale = try #require(questions.first { $0.sessionId == "s1" }, "\(name)")
                let kept = try #require(questions.first { $0.sessionId == "other" }, "\(name)")

                let later = startClient(json, path: rig.path)
                #expect(await within(client) == ClientResult(output: nil), "\(name)")
                #expect(await rig.engine.questionOutcome(for: stale.id) == .cancelled, "\(name)")
                #expect(await rig.snapshot { $0.questions.map(\.id) == [kept.id] } != nil, "\(name)")

                if name == "PermissionRequest" {
                    let approval = try #require(await rig.pending(count: 1).first, "\(name)")
                    #expect(await rig.engine.decide(requestId: approval.id, .deny))
                    #expect(await within(later) == ClientResult(output: denyOutput), "\(name)")
                } else {
                    #expect(await within(later) == ClientResult(output: nil), "\(name)")
                }
                #expect(await rig.engine.answer(requestId: kept.id, [.options(["Blue"])]), "\(name)")
                #expect(sameJSON(await within(bystander)?.output, answerOutput(["Which color?": "Blue"])))
            }
        }
    }

    // The person pressed Ctrl+C in the terminal: Claude Code stops the waiting hook.
    @Test func hookHangUpCancelsQuestion() async throws {
        try await withEngine { rig in
            let line = markedAsAsk(askJSON())
            let fd = try #require(await withCheckedContinuation { (continuation: CheckedContinuation<Int32?, Never>) in
                DispatchQueue.global().async { continuation.resume(returning: openWaiting(line, to: rig.path)) }
            })
            let question = try #require(await rig.questions(count: 1).first)

            let started = Date()
            close(fd)
            #expect(await rig.snapshot { $0.questions.isEmpty } != nil)
            #expect(Date().timeIntervalSince(started) < 1, "the card stayed up after the hook went away")
            #expect(await rig.engine.questionOutcome(for: question.id) == .cancelled)
            #expect(await rig.engine.answer(requestId: question.id, [.options(["Red"])]) == false)
        }
    }

    // MARK: Plans

    @Test func exitPlanModeShowsPlanCard() async throws {
        let choices: [(PlanChoice, Decision)] = [(.acceptEdits, .allow), (.askEachTime, .allow), (.change, .deny)]
        for (choice, decision) in choices {
            try await withEngine { rig in
                let client = startClient(planJSON(), path: rig.path)
                let approval = try #require(await rig.pending(count: 1).first, "\(choice)")
                #expect(approval.kind == .plan(text: planText))
                #expect(approval.toolName == "ExitPlanMode")

                #expect(await rig.engine.decidePlan(requestId: approval.id, choice), "\(choice)")
                #expect(await within(client) == ClientResult(output: planOutput(choice)), "\(choice)")
                #expect(await rig.engine.outcome(for: approval.id) == .decided(decision, .mac), "\(choice)")
                #expect(await rig.engine.decidePlan(requestId: approval.id, .change) == false, "\(choice)")
            }
        }
    }

    @Test func planWithoutPlanTextStaysInTheTerminal() async throws {
        try await withEngine { rig in
            let inputs: [JSONValue?] = [
                nil,
                .object([:]),
                .object(["plan": .string("")]),
                .object(["plan": .number(3)]),
            ]
            for input in inputs {
                let client = startClient(planJSON(input: input), path: rig.path)
                #expect(await within(client, timeout: .seconds(5)) == ClientResult(output: nil), "\(String(describing: input))")
            }
            #expect(await rig.snapshot { _ in true }?.pending == [])
        }
    }

    @Test func decideOnPlanIsRejected() async throws {
        try await withEngine { rig in
            let planClient = startClient(planJSON(session: "plan"), path: rig.path)
            let toolClient = startClient(permissionJSON(session: "tool"), path: rig.path)
            let approvals = await rig.pending(count: 2)
            let plan = try #require(approvals.first { $0.sessionId == "plan" })
            let tool = try #require(approvals.first { $0.sessionId == "tool" })
            #expect(tool.kind == .tool)

            // Each kind only takes its own answer.
            #expect(await rig.engine.decide(requestId: plan.id, .allow) == false)
            #expect(await rig.engine.decidePlan(requestId: tool.id, .acceptEdits) == false)
            #expect(await rig.engine.decidePlan(requestId: UUID(), .acceptEdits) == false)
            // A phone decision for a plan is ignored too: plans are never mirrored.
            try await rig.phoneDecides(plan.id, .allow)
            try await rig.flushPhoneDecisions()
            #expect(Set(await rig.pending(count: 2).map(\.id)) == [plan.id, tool.id])
            let records = await firstMatch(in: rig.cloud.phoneSide.approvals()) { _ in true } ?? []
            #expect(!records.contains { $0.requestId == plan.id }, "the plan reached the phone")

            #expect(await rig.engine.decidePlan(requestId: plan.id, .askEachTime))
            #expect(await within(planClient) == ClientResult(output: planOutput(.askEachTime)))
            #expect(await rig.engine.decide(requestId: tool.id, .allow))
            #expect(await within(toolClient) == ClientResult(output: allowOutput))
        }
    }

    @Test func engineWorksWithNilTransport() async throws {
        try await withEngine(useTransport: false) { rig in
            #expect(await rig.engine.hasPhoneBridge == false)
            await send(eventJSON("SessionStart", cwd: "/tmp/proj"), path: rig.path)
            #expect(await rig.snapshot { $0.sessions.first?.project == "proj" } != nil)

            let client = startClient(permissionJSON(), path: rig.path)
            let approval = try #require(await rig.pending(count: 1).first)
            #expect(await rig.engine.decide(requestId: approval.id, .allow))
            #expect(await within(client) == ClientResult(output: allowOutput))
        }
    }

    @Test func stopThenStartReusesSocketPath() async throws {
        let path = tempSocketURL()
        defer { try? FileManager.default.removeItem(at: path) }
        let engine = BuddyEngine(socketPath: path, transport: InMemoryCloud().macSide, tickInterval: 0.1)

        try await engine.start()
        await send(eventJSON("SessionStart", session: "before"), path: path)
        #expect(await firstMatch(in: await engine.snapshots()) { !$0.sessions.isEmpty } != nil)

        // A request still waiting when the engine stops is released with no decision.
        let waiting = startClient(permissionJSON(session: "before"), path: path)
        #expect(await firstMatch(in: await engine.snapshots()) { $0.pending.count == 1 } != nil)
        await engine.stop()
        #expect(await within(waiting) == ClientResult(output: nil))
        #expect(!FileManager.default.fileExists(atPath: path.path))
        await engine.stop()  // idempotent

        try await engine.start()
        await send(eventJSON("SessionStart", session: "after"), path: path)
        let snapshot = await firstMatch(in: await engine.snapshots()) { s in
            s.sessions.contains { $0.id == "after" }
        }
        #expect(snapshot?.pending == [])
        let client = startClient(permissionJSON(session: "after"), path: path)
        let approval = try #require(await firstMatch(in: await engine.snapshots()) { $0.pending.count == 1 }?.pending.first)
        #expect(await engine.decide(requestId: approval.id, .allow))
        #expect(await within(client) == ClientResult(output: allowOutput))
        await engine.stop()
        #expect(!FileManager.default.fileExists(atPath: path.path))
    }

    @Test func startFailsWhenSocketPathTooLong() async throws {
        let path = URL(fileURLWithPath: "/tmp/" + String(repeating: "x", count: 120) + ".sock")
        let engine = BuddyEngine(socketPath: path, transport: nil)
        await #expect(throws: HookSocketError.pathTooLong) { try await engine.start() }
        await engine.stop()
    }

    @Test func eventFloodKeepsEverySession() async throws {
        try await withEngine { rig in
            let count = 200
            // 200 concurrent connections overflow the listener's 64-slot backlog; HookClient
            // drops an event when that happens (socket layer, see deliverRaw), so this fake hook
            // retries the refused connect to make sure every event reaches the engine.
            let delivered = Mutex(0)
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                DispatchQueue.global().async {
                    DispatchQueue.concurrentPerform(iterations: count) { i in
                        let name = ["SessionStart", "UserPromptSubmit", "PreToolUse", "Notification"][i % 4]
                        let line = Data((eventJSON(name, session: "flood-\(i)", tool: "Bash") + "\n").utf8)
                        if deliverRaw(line, to: rig.path) { delivered.withLock { $0 += 1 } }
                    }
                    continuation.resume()
                }
            }
            #expect(delivered.withLock { $0 } == count)
            let snapshot = await rig.snapshot { $0.sessions.count == count }
            #expect(snapshot?.sessions.count == count)
            let mirrored = await firstMatch(in: rig.cloud.phoneSide.sessions()) { $0.count == count }
            #expect(mirrored?.count == count)

            // Still responsive afterwards.
            let client = startClient(permissionJSON(session: "flood-0"), path: rig.path)
            let approval = try #require(await rig.pending(count: 1).first)
            #expect(await rig.engine.decide(requestId: approval.id, .deny))
            #expect(await within(client) == ClientResult(output: denyOutput))
        }
    }

    @Test func garbageEventNeverCrashes() async throws {
        try await withEngine { rig in
            await sendRaw(Data("not json at all\n".utf8), to: rig.path)
            await sendRaw(Data(#"{"session_id":42,"hook_event_name":"Stop"}"#.utf8 + [0x0A]), to: rig.path)
            await sendRaw(Data(#"{"session_id":"g","hook_event_name":"Bogus"}"#.utf8 + [0x0A]), to: rig.path)
            await sendRaw(Data([0xFF, 0x00, 0xFE, 0x0A]), to: rig.path)
            await sendRaw(Data(), to: rig.path)

            // A permission request without a tool name is never shown for approval.
            let anonymous = startClient(eventJSON("PermissionRequest", session: "g"), path: rig.path)
            #expect(await within(anonymous) == ClientResult(output: nil))

            await send(eventJSON("SessionStart", session: "alive"), path: rig.path)
            let snapshot = await rig.snapshot { s in s.sessions.contains { $0.id == "alive" } }
            #expect(snapshot?.pending == [])
        }
    }
}
