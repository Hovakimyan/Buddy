import Foundation
import Synchronization
import Testing
@testable import BuddyKit

/// Messages from the phone: a finished turn (`buddy-hook --stop`) hands over a queued message, or waits for one until
/// it comes, the Mac is used, the terminal takes over, or 10 minutes pass.

private final class StepClock: Sendable {
    private let value: Mutex<Date>
    init(_ start: Date) { value = Mutex(start) }
    var now: Date { value.withLock { $0 } }
    func advance(by seconds: TimeInterval) { value.withLock { $0 = $0.addingTimeInterval(seconds) } }
}

private func firstMatch<T: Sendable>(
    in stream: AsyncStream<T>, timeout: Duration = .seconds(20), where predicate: @escaping @Sendable (T) -> Bool
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

private func event(_ name: String, session: String = "s1", extra: [String: JSONValue] = [:]) -> String {
    var members: [String: JSONValue] = ["session_id": .string(session), "hook_event_name": .string(name)]
    for (key, value) in extra { members[key] = value }
    return String(decoding: try! JSONEncoder().encode(JSONValue.object(members)), as: UTF8.self)
}

/// Runs the blocking relay off the cooperative pool and returns what it printed.
private func relay(_ json: String, path: URL, stop: Bool = false, waitTimeout: TimeInterval = 25) -> Task<String?, Never> {
    Task {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(returning: HookClient.run(
                    input: Data(json.utf8), socketPath: path, stop: stop, connectTimeout: 5, waitTimeout: waitTimeout))
            }
        }
    }
}

/// The relay's result, or `.some(.some("timeout"))` if it is still waiting after `timeout`.
private func result(of task: Task<String?, Never>, timeout: Duration = .seconds(20)) async -> String?? {
    let (stream, continuation) = AsyncStream<String?>.makeStream()
    Task {
        continuation.yield(await task.value)
        continuation.finish()
    }
    return await firstMatch(in: stream, timeout: timeout) { _ in true }
}

private let stopEvent = HookEvent(sessionId: "s1", name: .stop)

private func output(_ text: String) -> String? { HookOutput.stdout(for: .message(text), event: stopEvent) }

private struct Rig {
    let engine: BuddyEngine
    let path: URL
    let cloud: InMemoryCloud

    func session(where predicate: @escaping @Sendable (Session) -> Bool) async -> Session? {
        await firstMatch(in: await engine.snapshots()) { $0.sessions.contains(where: predicate) }?
            .sessions.first(where: predicate)
    }

    func phoneSends(_ text: String, session: String = "s1", sentAt: Date = Date(), id: UUID = UUID()) async throws {
        try await cloud.phoneSide.submit(message: MessageRecord(messageId: id, sessionId: session, text: text, sentAt: sentAt))
    }

    func started(_ session: String = "s1") async {
        _ = await relay(event("SessionStart", session: session), path: path).value
        _ = await self.session { $0.id == session }
    }
}

private func withEngine(
    clock: (@Sendable () -> Date)? = nil, tickInterval: TimeInterval = 1, _ body: (Rig) async throws -> Void
) async throws {
    let path = URL(fileURLWithPath: "/tmp/buddy-m\(String(UUID().uuidString.prefix(8)).lowercased()).sock")
    let cloud = InMemoryCloud()
    let engine = BuddyEngine(socketPath: path, transport: cloud.macSide, clock: clock ?? { Date() }, tickInterval: tickInterval)
    try await engine.start()
    defer { try? FileManager.default.removeItem(at: path) }
    do {
        try await body(Rig(engine: engine, path: path, cloud: cloud))
    } catch {
        await engine.stop()
        throw error
    }
    await engine.stop()
}

@Suite struct PhoneMessageTests {
    @Test func aQueuedMessageIsHandedToTheNextFinishedTurn() async throws {
        try await withEngine { rig in
            await rig.started()
            try await rig.phoneSends("Now run the tests")
            #expect(await rig.session { $0.queuedMessages == 1 } != nil)

            let reply = await result(of: relay(event("Stop"), path: rig.path, stop: true))
            #expect(reply == .some(output("Now run the tests")))
            #expect(await rig.session { $0.id == "s1" && $0.queuedMessages == 0 } != nil)
        }
    }

    @Test func theMessageReachesClaudeAsTheReasonToCarryOn() throws {
        let printed = try #require(output("Run the tests"))
        let object = try #require(try JSONSerialization.jsonObject(with: Data(printed.utf8)) as? [String: String])
        #expect(object["decision"] == "block")
        #expect(object["reason"] == HookOutput.messagePreamble + "\n\nRun the tests")
        // Never on another event: there a "block" means something else.
        #expect(HookOutput.stdout(for: .message("x"), event: HookEvent(sessionId: "s1", name: .preToolUse)) == nil)
    }

    @Test func aFinishedTurnWaitsUntilAMessageArrives() async throws {
        try await withEngine { rig in
            await rig.started()
            let waiting = relay(event("Stop"), path: rig.path, stop: true)
            #expect(await rig.session { $0.awaitingMessage } != nil)

            try await rig.phoneSends("  Add a README  \n")
            #expect(await result(of: waiting) == .some(output("Add a README")))
            #expect(await rig.session { $0.id == "s1" && !$0.awaitingMessage } != nil)
        }
    }

    @Test func usingTheMacEndsAWaitingTurn() async throws {
        try await withEngine { rig in
            await rig.started()
            let waiting = relay(event("Stop"), path: rig.path, stop: true)
            #expect(await rig.session { $0.awaitingMessage } != nil)
            await rig.engine.releaseWaitingTurns()
            #expect(await result(of: waiting) == .some(nil))
        }
    }

    @Test func aPromptTypedInTheTerminalEndsAHeldTurn() async throws {
        try await withEngine { rig in
            await rig.started()
            let waiting = relay(event("Stop"), path: rig.path, stop: true)
            #expect(await rig.session { $0.awaitingMessage } != nil)
            _ = await relay(event("UserPromptSubmit"), path: rig.path).value
            #expect(await result(of: waiting) == .some(nil))
        }
    }

    @Test func escInTheTerminalEndsTheHold() async throws {
        try await withEngine { rig in
            await rig.started()
            // The relay gives up (as when Claude Code cancels the hook): its connection closes.
            let waiting = relay(event("Stop"), path: rig.path, stop: true, waitTimeout: 1)
            #expect(await rig.session { $0.awaitingMessage } != nil)
            #expect(await result(of: waiting) == .some(nil))
            #expect(await rig.session { $0.id == "s1" && !$0.awaitingMessage } != nil)
            // A message now waits for the next turn instead of going nowhere.
            try await rig.phoneSends("later")
            #expect(await rig.session { $0.queuedMessages == 1 } != nil)
        }
    }

    @Test func aWaitingTurnEndsAfterTenMinutes() async throws {
        let clock = StepClock(Date(timeIntervalSince1970: 1_800_000_000))
        try await withEngine(clock: { clock.now }, tickInterval: 0.05) { rig in
            await rig.started()
            let waiting = relay(event("Stop"), path: rig.path, stop: true)
            #expect(await rig.session { $0.awaitingMessage } != nil)
            clock.advance(by: BuddyEngine.stopHoldTimeout - 1)
            #expect(await result(of: waiting, timeout: .milliseconds(300)) == nil)  // still waiting
            clock.advance(by: 1)
            #expect(await result(of: waiting) == .some(nil))
        }
    }

    @Test func untrustedMessagesAreTakenOnlyWhenTheyFit() async throws {
        try await withEngine { rig in
            await rig.started()
            let engine = rig.engine
            func message(_ text: String, session: String = "s1", sentAt: Date = Date(), id: UUID = UUID()) -> MessageRecord {
                MessageRecord(messageId: id, sessionId: session, text: text, sentAt: sentAt)
            }
            #expect(await engine.receive(message: message("hi", sentAt: Date() - BuddyEngine.messageMaxAge - 5)) == false)
            #expect(await engine.receive(message: message(" \n\t ")) == false)
            #expect(await engine.receive(message: message(String(repeating: "a", count: MessageRecord.maxLength + 1))) == false)
            let id = UUID()
            #expect(await engine.receive(message: message("once", id: id)) == true)
            #expect(await engine.receive(message: message("once", id: id)) == false)  // a replay
            for n in 1..<BuddyEngine.maxQueuedMessages { #expect(await engine.receive(message: message("m\(n)"))) }
            #expect(await engine.receive(message: message("one too many")) == false)
        }
    }

    @Test func aMessageLeavesTheCloudOnlyOnceClaudeHasIt() async throws {
        try await withEngine { rig in
            await rig.started()
            try await rig.phoneSends("hello")
            #expect(await rig.session { $0.queuedMessages == 1 } != nil)
            // Queued in memory only: a Mac that restarted now would find it again.
            let kept = await firstMatch(in: rig.cloud.macSide.messages(), timeout: .milliseconds(300)) { _ in true }
            #expect(kept?.text == "hello")

            #expect(await result(of: relay(event("Stop"), path: rig.path, stop: true)) == .some(output("hello")))
            try await Task.sleep(for: .milliseconds(100))
            let replay = await firstMatch(in: rig.cloud.macSide.messages(), timeout: .milliseconds(300)) { _ in true }
            #expect(replay == nil)
        }
    }

    @Test func aMessageForASessionNotSeenYetWaitsForItsFirstEvent() async throws {
        try await withEngine { rig in
            // As after a restart: the message is there before the session's next event.
            try await rig.phoneSends("pick up where you left off", session: "later")
            try await Task.sleep(for: .milliseconds(100))
            await rig.started("later")
            #expect(await rig.session { $0.id == "later" && $0.queuedMessages == 1 } != nil)
            let reply = await result(of: relay(event("Stop", session: "later"), path: rig.path, stop: true))
            #expect(reply == .some(HookOutput.stdout(
                for: .message("pick up where you left off"), event: HookEvent(sessionId: "later", name: .stop))))
        }
    }

    @Test func messageTextKeepsLinesAndDropsControlCharacters() {
        #expect(BuddyEngine.cleaned("  a\u{0}b\u{202E}c\n\td \u{7}") == "abc\n\td")
        #expect(BuddyEngine.cleaned("\u{200B}") == nil)
    }

    @Test func onlyTheStopFlagOnAStopMakesTheRelayWait() async throws {
        try await withEngine { rig in
            await rig.started()
            // `--stop` on another event, and a payload that claims the mark itself: neither waits.
            let other = relay(event("PreToolUse", extra: ["tool_name": .string("Read")]), path: rig.path, stop: true)
            #expect(await result(of: other, timeout: .seconds(5)) == .some(nil))
            let forged = relay(event("Stop", extra: ["buddy_stop": .bool(true)]), path: rig.path)
            #expect(await result(of: forged, timeout: .seconds(5)) == .some(nil))
            #expect(await rig.session { $0.id == "s1" && !$0.awaitingMessage } != nil)
        }
    }

    @Test func theWireCarriesAMessageReply() {
        let line = HookWire.replyLine(for: .message("Line one\nLine \"two\""))
        #expect(HookWire.reply(fromReply: line.dropLast()) == .message("Line one\nLine \"two\""))
        #expect(HookWire.reply(fromReply: Data(#"{"message":"a","decision":"allow"}"#.utf8)) == nil)
        #expect(HookWire.reply(fromReply: Data(#"{"message":7}"#.utf8)) == nil)
    }

    @Test func theStopMarkIsParsedLikeTheAskMark() {
        #expect(HookEvent.parse(Data(event("Stop", extra: ["buddy_stop": .bool(true)]).utf8))?.isStopWait == true)
        #expect(HookEvent.parse(Data(event("Stop", extra: ["buddy_stop": .string("true")]).utf8))?.isStopWait == false)
        #expect(HookEvent.parse(Data(event("Stop").utf8))?.waitsForReply == false)
    }
}
