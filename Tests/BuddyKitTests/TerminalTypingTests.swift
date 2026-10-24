import Foundation
import Synchronization
import Testing
@testable import BuddyKit

/// Messages from the phone typed into the session's terminal: what the relay reports about where a session runs, and
/// when the engine types instead of going through the `Stop` hook.
@Suite struct TerminalTypingTests {
    @Test func onlyWellFormedTerminalDetailsAreKept() {
        let info = TerminalInfo(program: "iTerm.app", tty: "/dev/ttys004", tmuxPane: "%3", tmuxSocket: "/private/tmp/tmux-502/default")
        #expect(info.tty == "/dev/ttys004" && info.tmuxPane == "%3" && info.program == "iTerm.app")
        let odd = TerminalInfo(program: "iTerm.app; rm -rf ~", tty: "/dev/../etc/passwd", tmuxPane: "%3;x", tmuxSocket: "rel/path")
        #expect(odd.program == nil && odd.tty == nil && odd.tmuxPane == nil && odd.tmuxSocket == nil)
    }

    @Test func typableMeansTmuxOrAnITermOrTerminalTabWithItsTty() {
        #expect(TerminalInfo(program: "iTerm.app", tty: "/dev/ttys001").isTypable)
        #expect(TerminalInfo(program: "Apple_Terminal", tty: "/dev/ttys001").isTypable)
        #expect(TerminalInfo(program: "vscode", tty: "/dev/ttys001", tmuxPane: "%1", tmuxSocket: "/tmp/t").isTypable)
        #expect(!TerminalInfo(program: "vscode", tty: "/dev/ttys001").isTypable)
        #expect(!TerminalInfo(program: "iTerm.app").isTypable)
    }

    @Test func theRelayReportsTheTerminalOnTurnEventsAndDropsAForgedOne() throws {
        let path = URL(fileURLWithPath: "/tmp/buddy-t\(String(UUID().uuidString.prefix(6)).lowercased()).sock")
        let received = Mutex<[HookEvent]>([])
        let server = HookSocketServer(path: path) { event in
            received.withLock { $0.append(event) }
            return nil
        }
        try server.start()
        defer { server.stop() }
        let terminal = TerminalInfo(program: "iTerm.app", tty: "/dev/ttys009")
        func send(_ json: String) { _ = HookClient.run(input: Data(json.utf8), socketPath: path, terminal: terminal, connectTimeout: 2) }
        send(#"{"session_id":"s","hook_event_name":"UserPromptSubmit","prompt":"hi"}"#)
        send(#"{"session_id":"s","hook_event_name":"PreToolUse","tool_name":"Read","buddy_terminal":{"program":"iTerm.app","tty":"/dev/ttys001"}}"#)
        for _ in 0..<200 where received.withLock({ $0.count }) < 2 { usleep(10_000) }
        let events = received.withLock { $0 }
        #expect(events.first { $0.name == .userPromptSubmit }?.terminal == terminal)
        #expect(events.first { $0.name == .preToolUse }?.terminal == nil)
    }
}

@Suite struct EngineTypingTests {
    private final class Typed: Sendable {
        let texts = Mutex<[String]>([])
        let works: Bool
        init(works: Bool) { self.works = works }
    }

    private func engine(_ typed: Typed) -> (BuddyEngine, URL) {
        let path = URL(fileURLWithPath: "/tmp/buddy-y\(String(UUID().uuidString.prefix(6)).lowercased()).sock")
        let engine = BuddyEngine(socketPath: path, transport: nil, typeIntoTerminal: { _, text in
            typed.texts.withLock { $0.append(text) }
            return typed.works
        })
        return (engine, path)
    }

    private func start(_ engine: BuddyEngine, path: URL, terminal: TerminalInfo?) async throws {
        try await engine.start()
        let prompt = JSONValue.object(["session_id": .string("s1"), "hook_event_name": .string("UserPromptSubmit")])
        _ = HookClient.run(input: try JSONEncoder().encode(prompt), socketPath: path, terminal: terminal, connectTimeout: 2)
        for _ in 0..<200 {
            if await engine.snapshots().first(where: { _ in true })?.sessions.isEmpty == false { break }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private func message(_ text: String) -> MessageRecord {
        MessageRecord(messageId: UUID(), sessionId: "s1", text: text, sentAt: Date())
    }

    @Test func aMessageIsTypedIntoATypableTerminalInsteadOfWaiting() async throws {
        let typed = Typed(works: true)
        let (engine, path) = engine(typed)
        try await start(engine, path: path, terminal: TerminalInfo(program: "iTerm.app", tty: "/dev/ttys004"))
        #expect(await engine.receive(message: message("run the tests")))
        #expect(typed.texts.withLock { $0 } == ["run the tests"])
        // A finished turn does not wait: the next message is typed whenever it comes.
        let reply = HookClient.run(
            input: Data(#"{"session_id":"s1","hook_event_name":"Stop"}"#.utf8), socketPath: path, stop: true,
            connectTimeout: 2, waitTimeout: 3)
        #expect(reply == nil)
        await engine.stop()
    }

    @Test func whenTypingFailsOrTheTextHasLinesTheHookCarriesIt() async throws {
        let typed = Typed(works: false)
        let (engine, path) = engine(typed)
        try await start(engine, path: path, terminal: TerminalInfo(program: "iTerm.app", tty: "/dev/ttys004"))
        #expect(await engine.receive(message: message("one line")))
        #expect(await engine.receive(message: message("line one\nline two")))
        #expect(typed.texts.withLock { $0 } == ["one line"])  // the two-line one was never typed
        let first = HookClient.run(
            input: Data(#"{"session_id":"s1","hook_event_name":"Stop"}"#.utf8), socketPath: path, stop: true,
            connectTimeout: 2, waitTimeout: 3)
        #expect(first == HookOutput.stdout(for: .message("one line"), event: HookEvent(sessionId: "s1", name: .stop)))
        await engine.stop()
    }

    @Test func anotherTerminalNeverGetsTyping() async throws {
        let typed = Typed(works: true)
        let (engine, path) = engine(typed)
        try await start(engine, path: path, terminal: TerminalInfo(program: "vscode", tty: "/dev/ttys004"))
        #expect(await engine.receive(message: message("hello")))
        #expect(typed.texts.withLock { $0 }.isEmpty)
        await engine.stop()
    }
}
