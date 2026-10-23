import Foundation
import Synchronization
import Testing
@testable import BuddyKit

// Socket paths must stay under the 104-byte sockaddr_un limit, so these tests use short paths
// under /tmp instead of FileManager.temporaryDirectory.

private func shortToken() -> String {
    String(UUID().uuidString.prefix(8)).lowercased()
}

private func tempSocketURL() -> URL {
    URL(fileURLWithPath: "/tmp/buddy-\(shortToken()).sock")
}

private func eventJSON(_ name: String, session: String = "s1") -> String {
    #"{"session_id":"\#(session)","hook_event_name":"\#(name)","tool_name":"Bash","tool_input":{"command":"ls"}}"#
}

/// Records events observed by a server handler, without sleeping or polling.
private final class Recorder: Sendable {
    let events: AsyncStream<HookEvent>
    private let continuation: AsyncStream<HookEvent>.Continuation

    init() {
        (events, continuation) = AsyncStream.makeStream()
    }

    func record(_ event: HookEvent) { continuation.yield(event) }

    func next() async -> HookEvent? {
        for await event in events { return event }
        return nil
    }
}

extension Recorder {
    /// The next `count` events, or however many arrived when `timeout` (an upper bound only)
    /// passes first.
    func collect(count: Int, timeout: Duration) async -> [HookEvent] {
        let seen = EventBox()
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                for await event in self.events {
                    if seen.append(event) >= count { return }
                }
            }
            group.addTask { try? await Task.sleep(for: timeout) }
            await group.next()
            group.cancelAll()
        }
        return seen.all
    }
}

private final class EventBox: Sendable {
    private let events = Mutex<[HookEvent]>([])
    func append(_ event: HookEvent) -> Int { events.withLock { $0.append(event); return $0.count } }
    var all: [HookEvent] { events.withLock { $0 } }
}

/// Runs `body(index)` on `count` real threads that all start at the same moment.
private final class ThreadLauncher: Sendable {
    private let count: Int
    private let body: @Sendable (Int) -> Void
    private let ready = DispatchSemaphore(value: 0)
    private let go = DispatchSemaphore(value: 0)
    private let done = DispatchGroup()

    init(count: Int, body: @escaping @Sendable (Int) -> Void) {
        self.count = count
        self.body = body
    }

    func start() {
        for index in 0..<count {
            done.enter()
            let thread = Thread { [self] in
                ready.signal()
                go.wait()
                body(index)
                done.leave()
            }
            thread.stackSize = 256 * 1024
            thread.start()
        }
        for _ in 0..<count { ready.wait() }
        for _ in 0..<count { go.signal() }
    }

    func waitUntilDone() { done.wait() }
}

/// Runs `HookClient.run` on a plain thread and times only the call itself, so scheduler hops
/// under load do not count against the client's own latency.
private func timedClient(_ json: String, path: URL) async -> (output: String?, elapsed: TimeInterval) {
    await withCheckedContinuation { continuation in
        DispatchQueue.global().async {
            let start = HookWire.now()
            let output = HookClient.run(input: Data(json.utf8), socketPath: path)
            let elapsed = TimeInterval(HookWire.now() - start) / 1_000_000_000
            continuation.resume(returning: (output, elapsed))
        }
    }
}

/// A handler can suspend on this until the test opens it.
private final class Gate: Sendable {
    private let stream: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation

    init() {
        (stream, continuation) = AsyncStream.makeStream()
    }

    func wait() async { for await _ in stream {} }
    func open() { continuation.finish() }

    /// True if the gate opened within `timeout` (an upper bound only).
    func opened(within timeout: Duration) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                await self.wait()
                return !Task.isCancelled
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
    }
}

private func expectedOutput(_ decision: Decision) -> String? {
    HookOutput.stdout(
        for: .decision(decision), event: HookEvent(sessionId: "s1", name: .permissionRequest, toolName: "Bash"))
}

private func withServer(
    handler: @escaping @Sendable (HookEvent) async -> HookReply?,
    _ body: (URL) async throws -> Void
) async throws {
    let path = tempSocketURL()
    let server = HookSocketServer(path: path, handler: handler)
    try server.start()
    defer {
        server.stop()
        try? FileManager.default.removeItem(at: path)
    }
    try await body(path)
}

/// `HookClient.run` blocks, so keep it off the cooperative pool that runs the server handler.
private func runClient(
    _ json: String, path: URL, ask: Bool = false, connectTimeout: TimeInterval = 0.3,
    waitTimeout: TimeInterval = 110
) async -> String? {
    await runClient(
        Data(json.utf8), path: path, ask: ask, connectTimeout: connectTimeout, waitTimeout: waitTimeout)
}

private func runClient(
    _ input: Data, path: URL, ask: Bool = false, connectTimeout: TimeInterval = 0.3,
    waitTimeout: TimeInterval = 110
) async -> String? {
    await withCheckedContinuation { continuation in
        DispatchQueue.global().async {
            continuation.resume(returning: HookClient.run(
                input: input, socketPath: path, ask: ask, connectTimeout: connectTimeout,
                waitTimeout: waitTimeout))
        }
    }
}

/// A PreToolUse for `tool`, with `extra` JSON members appended at the top level.
private func preToolUseJSON(tool: String, extra: String = "", session: String = "s1") -> String {
    let questions = #"[{"question":"Q","header":"H","multiSelect":false,"options":[{"label":"A","description":"a"},{"label":"B","description":"b"}]}]"#
    return #"{"session_id":"\#(session)","hook_event_name":"PreToolUse","tool_name":"\#(tool)","tool_input":{"questions":\#(questions)}\#(extra)}"#
}

/// Connects with plain POSIX calls, writes `bytes` (stopping at the first write error), then reads
/// whatever the server sends until it closes. Every blocking call has a timeout so a regression
/// fails the test instead of hanging it.
private func rawExchange(path: URL, bytes: Data) async -> Data {
    await withCheckedContinuation { continuation in
        DispatchQueue.global().async {
            continuation.resume(returning: rawExchangeSync(path: path, bytes: bytes))
        }
    }
}

private func rawExchangeSync(path: URL, bytes: Data) -> Data {
    rawExchangeResult(path: path, bytes: bytes).reply
}

/// Like `rawExchange`, but also reports whether the server let us write every byte: a server that
/// closes early makes a write fail.
private func rawExchangeReportingWrite(path: URL, bytes: Data) async -> (reply: Data, wroteAll: Bool) {
    await withCheckedContinuation { continuation in
        DispatchQueue.global().async {
            continuation.resume(returning: rawExchangeResult(path: path, bytes: bytes))
        }
    }
}

private func rawExchangeResult(path: URL, bytes: Data) -> (reply: Data, wroteAll: Bool) {
    let none = (reply: Data(), wroteAll: false)
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return none }
    defer { close(fd) }
    var one: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
    var timeout = timeval(tv_sec: 5, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let pathBytes = Array(path.path.utf8)
    withUnsafeMutableBytes(of: &addr.sun_path) { raw in
        raw.copyBytes(from: pathBytes)
        raw[pathBytes.count] = 0
    }
    let connected = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    guard connected == 0 else { return none }

    let wroteAll = bytes.withUnsafeBytes { raw -> Bool in
        var offset = 0
        while offset < raw.count {
            let n = write(fd, raw.baseAddress! + offset, raw.count - offset)
            if n <= 0 { return false }
            offset += n
        }
        return true
    }

    shutdown(fd, SHUT_WR)  // like a client that sent its bytes and exited
    var received = Data()
    var buffer = [UInt8](repeating: 0, count: 1024)
    while true {
        let n = read(fd, &buffer, buffer.count)
        if n <= 0 { break }
        received.append(contentsOf: buffer[0..<n])
    }
    return (received, wroteAll)
}

private enum WireTestSupport {
    static func connect(_ fd: Int32, to path: URL) -> Bool {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.path.utf8)
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: pathBytes)
            raw[pathBytes.count] = 0
        }
        return withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        } == 0
    }
}

private func mode(of url: URL) -> mode_t? {
    var st = stat()
    guard stat(url.path, &st) == 0 else { return nil }
    return st.st_mode & 0o7777
}

@Suite struct HookSocketTests {
    @Test func permissionRequestRoundTripAllow() async throws {
        let recorder = Recorder()
        try await withServer(handler: { event in
            recorder.record(event)
            return .decision(.allow)
        }) { path in
            let out = await runClient(eventJSON("PermissionRequest"), path: path)
            #expect(out == expectedOutput(.allow))
            let seen = await recorder.next()
            #expect(seen?.name == .permissionRequest)
            #expect(seen?.sessionId == "s1")
            #expect(seen?.toolName == "Bash")
        }
    }

    @Test func permissionRequestRoundTripDeny() async throws {
        try await withServer(handler: { _ in .decision(.deny) }) { path in
            let out = await runClient(eventJSON("PermissionRequest"), path: path)
            #expect(out == expectedOutput(.deny))
        }
    }

    @Test func handlerNilMeansClientReturnsNil() async throws {
        try await withServer(handler: { _ in nil }) { path in
            let out = await runClient(eventJSON("PermissionRequest"), path: path)
            #expect(out == nil)
        }
    }

    @Test func serverRepliesToRawClientWithDecisionLine() async throws {
        try await withServer(handler: { _ in .decision(.allow) }) { path in
            let reply = await rawExchange(path: path, bytes: Data((eventJSON("PermissionRequest") + "\n").utf8))
            #expect(String(decoding: reply, as: UTF8.self) == "{\"decision\":\"allow\"}\n")
        }
    }

    @Test func nonPermissionEventDeliveredWithoutWaiting() async throws {
        let recorder = Recorder()
        let gate = Gate()
        try await withServer(handler: { event in
            recorder.record(event)
            await gate.wait()  // the handler stays busy; the client must not wait for it
            return .decision(.allow)
        }) { path in
            let out = await runClient(eventJSON("PostToolUse"), path: path, waitTimeout: 30)
            #expect(out == nil)
            let seen = await recorder.next()
            #expect(seen?.name == .postToolUse)
            gate.open()
        }
    }

    @Test func nonPermissionClientDoesNotWaitForAnyReply() async throws {
        // A server that accepts, reads the line, then neither replies nor closes: a client that
        // waited for a reply would sit out its whole waitTimeout.
        let path = tempSocketURL()
        let listener = try RawListener(path: path)
        defer { try? FileManager.default.removeItem(at: path) }
        let held = Task.detached { listener.acceptAndHold(for: 10) }
        let start = Date()
        let out = await runClient(eventJSON("PostToolUse"), path: path, waitTimeout: 30)
        let elapsed = Date().timeIntervalSince(start)
        listener.release()
        await held.value
        #expect(out == nil)
        #expect(elapsed < 1)
    }

    @Test func nonPermissionEventNeverGetsAReply() async throws {
        try await withServer(handler: { _ in .decision(.allow) }) { path in
            let reply = await rawExchange(path: path, bytes: Data((eventJSON("Stop") + "\n").utf8))
            #expect(reply.isEmpty)
        }
    }

    @Test func socketFileModeIs0600AndDirIs0700() throws {
        let dir = URL(fileURLWithPath: "/tmp/buddy-d-\(shortToken())")
        let path = dir.appendingPathComponent("b.sock")
        let server = HookSocketServer(path: path, handler: { _ in nil })
        try server.start()
        defer {
            server.stop()
            try? FileManager.default.removeItem(at: dir)
        }
        #expect(mode(of: path) == 0o600)
        #expect(mode(of: dir) == 0o700)
    }

    @Test func preExistingParentDirModeIsLeftAlone() throws {
        let dir = URL(fileURLWithPath: "/tmp/buddy-d-\(shortToken())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)
        chmod(dir.path, 0o755)
        let path = dir.appendingPathComponent("b.sock")
        let server = HookSocketServer(path: path, handler: { _ in nil })
        try server.start()
        defer {
            server.stop()
            try? FileManager.default.removeItem(at: dir)
        }
        #expect(mode(of: dir) == 0o755)
        #expect(mode(of: path) == 0o600)
    }

    @Test func staleSocketFileIsReplaced() async throws {
        let path = tempSocketURL()
        // Leave a dead socket file behind, as a crashed app would: bound, but nobody listening.
        do { _ = try RawListener(path: path) }
        #expect(FileManager.default.fileExists(atPath: path.path))
        #expect(await runClient(eventJSON("PermissionRequest"), path: path) == nil)

        let server = HookSocketServer(path: path, handler: { _ in .decision(.allow) })
        try server.start()
        defer {
            server.stop()
            try? FileManager.default.removeItem(at: path)
        }
        let out = await runClient(eventJSON("PermissionRequest"), path: path)
        #expect(out == expectedOutput(.allow))
    }

    @Test func regularFileAtPathIsNeverDeleted() throws {
        let path = tempSocketURL()
        try Data("precious".utf8).write(to: path)
        defer { try? FileManager.default.removeItem(at: path) }
        let server = HookSocketServer(path: path, handler: { _ in nil })
        #expect(throws: HookSocketError.notASocket) { try server.start() }
        #expect(try Data(contentsOf: path) == Data("precious".utf8))

        // A symlink is not a socket either, and its target must survive.
        let target = tempSocketURL()
        try Data("target".utf8).write(to: target)
        let link = tempSocketURL()
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        defer {
            try? FileManager.default.removeItem(at: link)
            try? FileManager.default.removeItem(at: target)
        }
        let linked = HookSocketServer(path: link, handler: { _ in nil })
        #expect(throws: HookSocketError.notASocket) { try linked.start() }
        #expect(try Data(contentsOf: target) == Data("target".utf8))
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)) == target.path)
    }

    @Test func secondServerOnLivePathThrowsAndFirstKeepsServing() async throws {
        try await withServer(handler: { _ in .decision(.allow) }) { path in
            let second = HookSocketServer(path: path, handler: { _ in .decision(.deny) })
            #expect(throws: HookSocketError.addressInUse) { try second.start() }
            second.stop()  // never started: must not touch the first server's socket file

            #expect(FileManager.default.fileExists(atPath: path.path))
            let out = await runClient(eventJSON("PermissionRequest"), path: path)
            #expect(out == expectedOutput(.allow))
        }
    }

    @Test func stopRemovesSocketFileAndClientThenGetsNil() async throws {
        let path = tempSocketURL()
        let server = HookSocketServer(path: path, handler: { _ in .decision(.allow) })
        try server.start()
        #expect(FileManager.default.fileExists(atPath: path.path))
        server.stop()
        #expect(!FileManager.default.fileExists(atPath: path.path))
        let out = await runClient(eventJSON("PermissionRequest"), path: path)
        #expect(out == nil)
        server.stop()  // idempotent
    }

    @Test func noServerReturnsNilWithin300ms() async {
        // No socket file at all: ENOENT must return at once, never go through the refused-retry.
        let path = tempSocketURL()
        let (out, elapsed) = await timedClient(eventJSON("PermissionRequest"), path: path)
        #expect(out == nil)
        #expect(elapsed < 0.3)
    }

    @Test func staleSocketFileReturnsNilWithin300ms() async throws {
        // A dead socket file refuses every connect, so the client retries; that costs at most
        // ~150 ms and must still end well inside the 300 ms connect budget.
        let path = tempSocketURL()
        do { _ = try RawListener(path: path) }
        defer { try? FileManager.default.removeItem(at: path) }
        #expect(FileManager.default.fileExists(atPath: path.path))
        let (out, elapsed) = await timedClient(eventJSON("PermissionRequest"), path: path)
        #expect(out == nil)
        #expect(elapsed < 0.3)
    }

    @Test func burstOf200SimultaneousEventsAllArrive() async throws {
        // More simultaneous hooks than the listen backlog: the kernel refuses the overflow
        // outright, so the production client has to retry or events are lost.
        let total = 200
        let recorder = Recorder()
        try await withServer(handler: { event in
            recorder.record(event)
            return nil
        }) { path in
            let launcher = ThreadLauncher(count: total) { index in
                _ = HookClient.run(
                    input: Data(eventJSON("PostToolUse", session: "burst-\(index)").utf8),
                    socketPath: path)
            }
            launcher.start()
            let seen = await recorder.collect(count: total, timeout: .seconds(20))
            launcher.waitUntilDone()
            #expect(Set(seen.map(\.sessionId)).count == total)
            #expect(seen.count == total)
        }
    }

    @Test func nonPermissionEventsAreDeliveredInSendOrder() async throws {
        let total = 50
        let recorder = Recorder()
        try await withServer(handler: { event in
            recorder.record(event)
            return nil
        }) { path in
            // One client thread, each run() returns only after its event was sent.
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                Thread.detachNewThread {
                    for index in 0..<total {
                        _ = HookClient.run(
                            input: Data(eventJSON("PostToolUse", session: "seq-\(index)").utf8),
                            socketPath: path)
                    }
                    continuation.resume()
                }
            }
            let seen = await recorder.collect(count: total, timeout: .seconds(20))
            #expect(seen.map(\.sessionId) == (0..<total).map { "seq-\($0)" })
        }
    }

    @Test func malformedConnectionDoesNotHoldBackLaterEvents() async throws {
        let recorder = Recorder()
        try await withServer(handler: { event in
            recorder.record(event)
            return nil
        }) { path in
            // Each rejected connection still has to release its place in the delivery order.
            _ = await rawExchange(path: path, bytes: Data("not json\n".utf8))
            _ = await rawExchange(path: path, bytes: Data())
            _ = await runClient(eventJSON("Stop", session: "after-garbage"), path: path)
            let seen = await recorder.collect(count: 1, timeout: .seconds(20))
            #expect(seen.map(\.sessionId) == ["after-garbage"])
        }
    }

    @Test func permissionRequestIsNotBlockedBySlowNonPermissionHandler() async throws {
        let recorder = Recorder()
        let gate = Gate()
        try await withServer(handler: { event in
            if event.name == .permissionRequest { return .decision(.allow) }
            recorder.record(event)
            await gate.wait()  // the serial non-permission consumer is now stuck
            return nil
        }) { path in
            _ = await runClient(eventJSON("PostToolUse"), path: path)
            _ = await recorder.next()
            let out = await runClient(eventJSON("PermissionRequest"), path: path)
            #expect(out == expectedOutput(.allow))
            gate.open()
        }
    }

    @Test func serverNeverRepliesReturnsNilAfterWaitTimeout() async throws {
        let gate = Gate()
        try await withServer(handler: { _ in
            await gate.wait()
            return .decision(.allow)
        }) { path in
            let start = Date()
            let out = await runClient(eventJSON("PermissionRequest"), path: path, waitTimeout: 0.5)
            let elapsed = Date().timeIntervalSince(start)
            #expect(out == nil)
            #expect(elapsed >= 0.4)
            #expect(elapsed < 3)
            gate.open()
        }
    }

    // Claude Code shows its own prompt while the hook waits; answering "no" there stops the hook and
    // sends no other event. The closed connection is the only sign, so it must end the wait.
    @Test func clientHangingUpCancelsTheWaitingHandler() async throws {
        let recorder = Recorder()
        let cancelled = Gate()
        try await withServer(handler: { event in
            recorder.record(event)
            await withTaskCancellationHandler {
                await Gate().wait()  // a human who never answers
            } onCancel: {
                cancelled.open()
            }
            return .decision(.allow)  // must never be written: the cancelled reply is dropped
        }) { path in
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            #expect(WireTestSupport.connect(fd, to: path))
            let line = Array((eventJSON("PermissionRequest") + "\n").utf8)
            #expect(write(fd, line, line.count) == line.count)
            #expect(await recorder.next()?.name == .permissionRequest)

            let started = Date()
            close(fd)
            #expect(await cancelled.opened(within: .seconds(20)))
            #expect(Date().timeIntervalSince(started) < 1)
        }
    }

    @Test func aHalfClosedClientStillGetsTheDecision() async throws {
        // `shutdown(SHUT_WR)` means "sent everything, still listening": not a hang-up.
        try await withServer(handler: { _ in
            try? await Task.sleep(for: .milliseconds(400))
            return Task.isCancelled ? nil : .decision(.deny)
        }) { path in
            let reply = await rawExchange(path: path, bytes: Data((eventJSON("PermissionRequest") + "\n").utf8))
            #expect(String(decoding: reply, as: UTF8.self) == "{\"decision\":\"deny\"}\n")
        }
    }

    @Test func manyWaitingRequestsAreAllAnswered() async throws {
        // Each waiting request has its own watcher; none of them may hold up the others.
        try await withServer(handler: { event in
            try? await Task.sleep(for: .milliseconds(200))
            return event.sessionId.hasSuffix("0") ? .decision(.deny) : .decision(.allow)
        }) { path in
            let outputs = await withTaskGroup(of: (String, String?).self) { group in
                for index in 0..<20 {
                    let session = "wait-\(index)"
                    group.addTask { (session, await runClient(eventJSON("PermissionRequest", session: session), path: path)) }
                }
                var all: [String: String?] = [:]
                for await (session, output) in group { all[session] = output }
                return all
            }
            #expect(outputs.count == 20)
            for (session, output) in outputs {
                #expect(output == expectedOutput(session.hasSuffix("0") ? .deny : .allow), "\(session)")
            }
        }
    }

    @Test func oversizedLineIsRejectedAndServerSurvives() async throws {
        let recorder = Recorder()
        try await withServer(handler: { event in
            recorder.record(event)
            return .decision(.allow)
        }) { path in
            // Valid JSON apart from its size, so only the size check can reject it.
            let padding = String(repeating: "a", count: 5 * 1024 * 1024)
            let huge = #"{"session_id":"big","hook_event_name":"PermissionRequest","pad":"\#(padding)"}"# + "\n"
            let reply = await rawExchange(path: path, bytes: Data(huge.utf8))
            #expect(reply.isEmpty)

            let out = await runClient(eventJSON("PermissionRequest", session: "after"), path: path)
            #expect(out == expectedOutput(.allow))
            // The oversized event never reached the handler: the first event seen is the later one.
            let seen = await recorder.next()
            #expect(seen?.sessionId == "after")
        }
    }

    @Test func serverStopsReadingAtItsOwnCapWithoutANewline() async throws {
        let recorder = Recorder()
        try await withServer(handler: { event in
            recorder.record(event)
            return .decision(.allow)
        }) { path in
            // 8 MiB and never a newline: HookEvent.parse is never reached, so only the server's
            // 4 MiB + 1 read cap can cut this off. If the server read until EOF instead, every
            // byte would be accepted and `wroteAll` would be true.
            let blob = Data(repeating: UInt8(ascii: "a"), count: 8 * 1024 * 1024)
            let result = await rawExchangeReportingWrite(path: path, bytes: blob)
            #expect(result.reply.isEmpty)
            #expect(!result.wroteAll, "server kept reading past its cap")

            let out = await runClient(eventJSON("PermissionRequest", session: "after"), path: path)
            #expect(out == expectedOutput(.allow))
            let seen = await recorder.next()
            #expect(seen?.sessionId == "after")
        }
    }

    @Test func garbageLineIsIgnoredAndServerSurvives() async throws {
        let recorder = Recorder()
        try await withServer(handler: { event in
            recorder.record(event)
            return .decision(.allow)
        }) { path in
            let garbage = Data([0xFF, 0xFE, 0x00, 0x01, 0x7B, 0x22, 0x80, 0x0A])
            #expect(await rawExchange(path: path, bytes: garbage).isEmpty)
            #expect(await rawExchange(path: path, bytes: Data("not json at all".utf8)).isEmpty)
            #expect(await rawExchange(path: path, bytes: Data("{\"session_id\":1}\n".utf8)).isEmpty)
            #expect(await rawExchange(path: path, bytes: Data()).isEmpty)

            let out = await runClient(eventJSON("PermissionRequest", session: "after"), path: path)
            #expect(out == expectedOutput(.allow))
            let seen = await recorder.next()
            #expect(seen?.sessionId == "after")
        }
    }

    @Test func stalledClientDoesNotBlockOtherConnections() async throws {
        try await withServer(handler: { _ in .decision(.allow) }) { path in
            // Connects and says nothing; the server must keep serving others meanwhile.
            let stalled = socket(AF_UNIX, SOCK_STREAM, 0)
            defer { close(stalled) }
            let connected = WireTestSupport.connect(stalled, to: path)
            #expect(connected)
            let out = await runClient(eventJSON("PermissionRequest"), path: path)
            #expect(out == expectedOutput(.allow))
        }
    }

    @Test func silentConnectionDelaysLaterEventsByAtMostTheFirstByteDeadline() async throws {
        let recorder = Recorder()
        try await withServer(handler: { event in
            recorder.record(event)
            return nil
        }) { path in
            // Connects and never writes: it holds the head of the delivery line until the server
            // gives up on it. The hook client writes right after connecting, so that must be fast
            // (about HookWire.firstByteTimeout), not the full 5 s request deadline.
            let silent = socket(AF_UNIX, SOCK_STREAM, 0)
            defer { close(silent) }
            #expect(WireTestSupport.connect(silent, to: path))

            let started = Date()
            _ = await runClient(eventJSON("Stop", session: "behind-silent"), path: path)
            let seen = await recorder.collect(count: 1, timeout: .seconds(20))
            let elapsed = Date().timeIntervalSince(started)
            #expect(seen.map(\.sessionId) == ["behind-silent"])
            #expect(elapsed >= HookWire.firstByteTimeout - 0.1)
            #expect(elapsed < 3, "a silent client held up later events for \(elapsed) s")
        }
    }

    @Test func permissionRequestIsAnsweredAtOnceWhileASilentConnectionIsOpen() async throws {
        try await withServer(handler: { _ in .decision(.deny) }) { path in
            let silent = socket(AF_UNIX, SOCK_STREAM, 0)
            defer { close(silent) }
            #expect(WireTestSupport.connect(silent, to: path))
            let started = Date()
            let out = await runClient(eventJSON("PermissionRequest"), path: path)
            #expect(out == expectedOutput(.deny))
            #expect(Date().timeIntervalSince(started) < HookWire.firstByteTimeout)
        }
    }

    @Test func clientThatWritesJustWithinTheFirstByteDeadlineIsStillServed() async throws {
        let recorder = Recorder()
        try await withServer(handler: { event in
            recorder.record(event)
            return nil
        }) { path in
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            defer { close(fd) }
            #expect(WireTestSupport.connect(fd, to: path))
            try await Task.sleep(for: .seconds(HookWire.firstByteTimeout / 2))
            let line = Array((eventJSON("Stop", session: "slow-start") + "\n").utf8)
            #expect(write(fd, line, line.count) == line.count)
            let seen = await recorder.collect(count: 1, timeout: .seconds(20))
            #expect(seen.map(\.sessionId) == ["slow-start"])
        }
    }

    @Test func clientIgnoresGarbageReplies() async throws {
        for reply in ["garbage\n", "{\"decision\":\"maybe\"}\n", "{\"decision\":\"ALLOW\"}\n", "{\"decision\":1}\n", "\n"] {
            let path = tempSocketURL()
            let listener = try RawListener(path: path)
            defer { try? FileManager.default.removeItem(at: path) }
            let serverSide = Task.detached { listener.acceptAndReply(Data(reply.utf8)) }
            let out = await runClient(eventJSON("PermissionRequest"), path: path)
            await serverSide.value
            #expect(out == nil, "reply \(reply.debugDescription) must not count as a decision")
        }
    }

    @Test func clientAcceptsExactAllowAndDenyReplies() async throws {
        for (reply, expected) in [("{\"decision\":\"allow\"}\n", Decision.allow), ("{\"decision\":\"deny\"}\n", .deny)] {
            let path = tempSocketURL()
            let listener = try RawListener(path: path)
            defer { try? FileManager.default.removeItem(at: path) }
            let serverSide = Task.detached { listener.acceptAndReply(Data(reply.utf8)) }
            let out = await runClient(eventJSON("PermissionRequest"), path: path)
            await serverSide.value
            #expect(out == expectedOutput(expected))
        }
    }

    @Test func unparseablePayloadReturnsNilWithoutConnecting() async throws {
        let path = tempSocketURL()
        let listener = try RawListener(path: path)
        defer { try? FileManager.default.removeItem(at: path) }
        for payload in [Data(), Data("garbage".utf8), Data([0xFF, 0x00, 0xFE]), Data("{\"session_id\":\"s\"}".utf8)] {
            #expect(await runClient(payload, path: path) == nil)
        }
        #expect(!listener.hasPendingConnection())
    }

    @Test func tooLongSocketPathFailsCleanly() async throws {
        let path = URL(fileURLWithPath: "/tmp/" + String(repeating: "x", count: 200) + ".sock")
        let server = HookSocketServer(path: path, handler: { _ in nil })
        #expect(throws: HookSocketError.pathTooLong) { try server.start() }
        server.stop()
        #expect(await runClient(eventJSON("PermissionRequest"), path: path) == nil)
    }

    @Test func replyRoundTrip() {
        let replies: [HookReply] = [
            .decision(.allow), .decision(.deny),
            .plan(.change), .plan(.acceptEdits), .plan(.askEachTime),
            .answers(["Which?": "A, B", "Other": "Say \"hi\"\nnow"]), .answers([:]),
        ]
        for reply in replies {
            let line = HookWire.replyLine(for: reply)
            #expect(line.last == 0x0A)
            #expect(!line.dropLast().contains(0x0A), "\(reply) must stay on one line")
            #expect(HookWire.reply(fromReply: line.dropLast()) == reply)
        }
        #expect(String(decoding: HookWire.replyLine(for: .decision(.allow)), as: UTF8.self) == "{\"decision\":\"allow\"}\n")
        #expect(String(decoding: HookWire.replyLine(for: .plan(.acceptEdits)), as: UTF8.self) == "{\"plan\":\"acceptEdits\"}\n")
    }

    @Test func oversizeOrUnknownReplyIsNoReply() {
        for text in [
            #"{"decision":"maybe"}"#, #"{"plan":"x"}"#, #"{"answers":{"a":1}}"#, #"{"answers":["a"]}"#,
            #"{"decision":"allow","plan":"change"}"#, "{}", "garbage", "",
        ] {
            #expect(HookWire.reply(fromReply: Data(text.utf8)) == nil, "\(text)")
        }
        let padding = String(repeating: "x", count: HookWire.maxReplyBytes)
        let oversize = Data(#"{"answers":{"a":"\#(padding)"}}"#.utf8)
        #expect(oversize.count > HookWire.maxReplyBytes)
        #expect(HookWire.reply(fromReply: oversize) == nil)
        // The same shape just inside the limit is accepted.
        let fitting = String(repeating: "x", count: HookWire.maxReplyBytes - 20)
        let inside = Data(#"{"answers":{"a":"\#(fitting)"}}"#.utf8)
        #expect(inside.count == HookWire.maxReplyBytes)
        #expect(HookWire.reply(fromReply: inside) == .answers(["a": fitting]))
        #expect(HookWire.maxReplyBytes == 64 * 1024)
    }

    // MARK: ask (AskUserQuestion answered through the relay)

    @Test func askWithoutFlagNeverWaits() async throws {
        let recorder = Recorder()
        try await withServer(handler: { event in
            recorder.record(event)
            try? await Task.sleep(for: .seconds(3))
            return .answers(["Q": "A"])
        }) { path in
            // Stdin carries the flag itself (a forged or stale payload); the relay strips it.
            let json = preToolUseJSON(tool: "AskUserQuestion", extra: #","buddy_ask":true"#)
            let (out, elapsed) = await timedClient(json, path: path)
            #expect(out == nil)
            #expect(elapsed < 1)
            let seen = await recorder.next()
            #expect(seen?.name == .preToolUse)
            #expect(seen?.toolName == "AskUserQuestion")
            #expect(seen?.isAsk == false)
        }
    }

    @Test func askFlagOnOtherToolDoesNotWait() async throws {
        let recorder = Recorder()
        try await withServer(handler: { event in
            recorder.record(event)
            try? await Task.sleep(for: .seconds(3))
            return .answers(["Q": "A"])
        }) { path in
            let json = preToolUseJSON(tool: "Bash", extra: #","buddy_ask":true"#)
            let started = Date()
            let out = await runClient(json, path: path, ask: true)
            #expect(out == nil)
            #expect(Date().timeIntervalSince(started) < 1)
            let seen = await recorder.next()
            #expect(seen?.toolName == "Bash")
            #expect(seen?.isAsk == false)
        }
    }

    @Test func escapedBuddyAskKeyIsStrippedFromANonAsk() async throws {
        let recorder = Recorder()
        try await withServer(handler: { event in
            recorder.record(event)
            try? await Task.sleep(for: .seconds(3))
            return .answers(["Q": "A"])
        }) { path in
            // `\u0062uddy_ask` is the key `buddy_ask`: the raw bytes never contain that text.
            let json = preToolUseJSON(tool: "AskUserQuestion", extra: #","\u0062uddy_ask":true"#)
            #expect(HookEvent.parse(Data(json.utf8))?.isAsk == true)
            let started = Date()
            let out = await runClient(json, path: path)
            #expect(out == nil)
            #expect(Date().timeIntervalSince(started) < 1)
            #expect(await recorder.next()?.isAsk == false)
        }
    }

    @Test func askFlagOnAnotherEventDoesNotWait() async throws {
        try await withServer(handler: { _ in
            try? await Task.sleep(for: .seconds(3))
            return .answers(["Q": "A"])
        }) { path in
            let json = #"{"session_id":"s1","hook_event_name":"PostToolUse","tool_name":"AskUserQuestion"}"#
            let started = Date()
            #expect(await runClient(json, path: path, ask: true) == nil)
            #expect(Date().timeIntervalSince(started) < 1)
        }
    }

    @Test func askRoundTrip() async throws {
        let recorder = Recorder()
        try await withServer(handler: { event in
            recorder.record(event)
            return .answers(["Q": "A"])
        }) { path in
            let json = preToolUseJSON(tool: "AskUserQuestion")
            let out = await runClient(json, path: path, ask: true)
            let event = try #require(HookEvent.parse(Data(json.utf8)))
            // Compared as JSON values: the output's key order is not fixed.
            let expected = try #require(HookOutput.stdout(for: .answers(["Q": "A"]), event: event))
            let printed = try #require(out)
            let actualObject = try JSONSerialization.jsonObject(with: Data(printed.utf8)) as? NSDictionary
            let expectedObject = try JSONSerialization.jsonObject(with: Data(expected.utf8)) as? NSDictionary
            #expect(actualObject != nil && actualObject == expectedObject)
            let seen = await recorder.next()
            #expect(seen?.isAsk == true)
            #expect(seen?.toolInput == event.toolInput)
            #expect(seen?.waitsForReply == true)
        }
    }

    @Test func askRelayKeepsTheOriginalLineForOtherEvents() async throws {
        // Without the flag and without a stray `buddy_ask`, the payload goes through byte for byte.
        let received = Mutex<Data?>(nil)
        let path = tempSocketURL()
        let listener = try RawListener(path: path)
        defer { try? FileManager.default.removeItem(at: path) }
        let json = preToolUseJSON(tool: "Bash")
        async let out = runClient(json, path: path)
        listener.acceptAndCapture { line in received.withLock { $0 = line } }
        _ = await out
        #expect(received.withLock { $0 } == Data((json + "\n").utf8))
    }

    @Test func askDeliversTheFlagAsATopLevelBoolean() async throws {
        let received = Mutex<Data?>(nil)
        let path = tempSocketURL()
        let listener = try RawListener(path: path)
        defer { try? FileManager.default.removeItem(at: path) }
        async let out = runClient(preToolUseJSON(tool: "AskUserQuestion", extra: #","buddy_ask":"yes""#), path: path, ask: true, waitTimeout: 0.5)
        listener.acceptAndCapture { line in received.withLock { $0 = line } }
        _ = await out
        let line = try #require(received.withLock { $0 })
        let object = try #require(try JSONSerialization.jsonObject(with: line) as? [String: Any])
        #expect(object["buddy_ask"] as? Bool == true)
        #expect(object["tool_name"] as? String == "AskUserQuestion")
    }

    @Test func askClientHangUpCancelsHandler() async throws {
        let recorder = Recorder()
        let cancelled = Gate()
        try await withServer(handler: { event in
            recorder.record(event)
            await withTaskCancellationHandler {
                await Gate().wait()  // a person who never answers
            } onCancel: {
                cancelled.open()
            }
            return .answers(["Q": "A"])  // must never be written: the cancelled reply is dropped
        }) { path in
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            #expect(WireTestSupport.connect(fd, to: path))
            let line = Array((preToolUseJSON(tool: "AskUserQuestion", extra: #","buddy_ask":true"#) + "\n").utf8)
            #expect(write(fd, line, line.count) == line.count)
            #expect(await recorder.next()?.isAsk == true)

            let started = Date()
            close(fd)
            #expect(await cancelled.opened(within: .seconds(20)))
            #expect(Date().timeIntervalSince(started) < 1)
        }
    }

    @Test func askWaitTimeoutsDefaultTo125ForAnAskAnd110ForAPermissionRequest() {
        #expect(HookClient.askWaitTimeout == 125)
        #expect(HookClient.defaultWaitTimeout == 110)
    }

    @Test func multilineStdinPayloadStillRoundTrips() async throws {
        try await withServer(handler: { _ in .decision(.deny) }) { path in
            let pretty = "{\n  \"session_id\": \"s1\",\n  \"hook_event_name\": \"PermissionRequest\"\n}\n"
            let out = await runClient(pretty, path: path)
            #expect(out == expectedOutput(.deny))
        }
    }
}

/// A bare listening socket the test fully controls: used to fake replies and to observe whether
/// anything connected.
private final class RawListener: @unchecked Sendable {
    private let fd: Int32

    init(path: URL) throws {
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.path.utf8)
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: pathBytes)
            raw[pathBytes.count] = 0
        }
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, listen(fd, 4) == 0 else {
            close(fd)
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    deinit { close(fd) }

    func hasPendingConnection() -> Bool {
        var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        return poll(&p, 1, 0) > 0
    }

    private let releaseSignal = DispatchSemaphore(value: 0)

    /// Accepts one connection, reads the request line, then keeps the connection open without
    /// replying until `release()` (or `seconds` as an upper bound).
    func acceptAndHold(for seconds: TimeInterval) {
        let conn = accept(fd, nil, nil)
        guard conn >= 0 else { return }
        defer { close(conn) }
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(conn, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var byte: UInt8 = 0
        while read(conn, &byte, 1) == 1, byte != 0x0A {}
        _ = releaseSignal.wait(timeout: .now() + seconds)
    }

    func release() { releaseSignal.signal() }

    /// Accepts one connection and hands the request line (with its newline) to `capture`, then closes.
    func acceptAndCapture(_ capture: (Data) -> Void) {
        let conn = accept(fd, nil, nil)
        guard conn >= 0 else { return }
        defer { close(conn) }
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(conn, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var line = Data()
        var byte: UInt8 = 0
        while read(conn, &byte, 1) == 1 {
            line.append(byte)
            if byte == 0x0A { break }
        }
        capture(line)
    }

    /// Accepts one connection, reads the request line, writes `reply`, closes.
    func acceptAndReply(_ reply: Data) {
        let conn = accept(fd, nil, nil)
        guard conn >= 0 else { return }
        defer { close(conn) }
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(conn, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var byte: UInt8 = 0
        while read(conn, &byte, 1) == 1, byte != 0x0A {}
        reply.withUnsafeBytes { _ = write(conn, $0.baseAddress, $0.count) }
    }
}
