#if os(macOS)
import Dispatch
import Foundation
import Synchronization

public enum HookSocketError: Error, Sendable, Equatable {
    case pathTooLong
    case alreadyStarted
    /// Something that is not a socket (a regular file, symlink, ...) already sits at the path.
    case notASocket
    /// A live server is already listening at the path.
    case addressInUse
    case system(String, errno: Int32)
}

/// Wire format shared by `HookSocketServer` and `HookClient`.
///
/// One connection carries one newline-terminated JSON line (the hook payload, at most
/// `HookEvent.maxPayloadSize` bytes before the newline). For an event that `waitsForReply` (a
/// `PermissionRequest`, or an `AskUserQuestion` call the relay marked with `buddy_ask`) the server
/// answers with one reply line (`{"decision":"allow"|"deny"}`, `{"plan":"<choice>"}` or
/// `{"answers":{...}}`); in every other case it closes silently. After its line the client only
/// reads; if it closes the connection instead, the server stops waiting for a reply
/// (`PermissionConnection`).
enum HookWire {
    /// The most a server reads from one connection: a maximal payload plus its newline.
    static let maxRequestBytes = HookEvent.maxPayloadSize + 1
    /// How long a client may take to deliver its request line before the server gives up on it.
    static let requestReadTimeout: TimeInterval = 5
    /// How long a connection may stay completely silent. The hook client writes its request
    /// immediately after connecting, so a connection that sends nothing for this long is not a
    /// hook; giving up on it early keeps it from holding back later events (see `OrderedEvents`).
    static let firstByteTimeout: TimeInterval = 1
    /// Replies are small (answers can carry a few free-text values); anything longer is garbage.
    static let maxReplyBytes = 64 * 1024

    /// One reply line. Exactly one key is set: `decision`, `plan` or `answers`.
    private struct Reply: Decodable {
        let decision: String?
        let plan: String?
        let answers: [String: String]?
    }

    static func replyLine(for reply: HookReply) -> Data {
        let object: [String: Any]
        switch reply {
        case .decision(let decision): object = ["decision": decision.rawValue]
        case .plan(let choice): object = ["plan": choice.rawValue]
        case .answers(let answers): object = ["answers": answers]
        }
        var line = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
        line.append(0x0A)
        return line
    }

    /// Only the exact shapes `replyLine` writes count: `allow`/`deny`, a known plan choice, or an
    /// object of strings. Anything else, or anything longer than `maxReplyBytes`, is "no reply".
    static func reply(fromReply data: Data) -> HookReply? {
        guard data.count <= maxReplyBytes,
              let reply = try? JSONDecoder().decode(Reply.self, from: data)
        else { return nil }
        switch (reply.decision, reply.plan, reply.answers) {
        case (let raw?, nil, nil): return Decision(rawValue: raw).map(HookReply.decision)
        case (nil, let raw?, nil): return PlanChoice(rawValue: raw).map(HookReply.plan)
        case (nil, nil, let answers?): return .answers(answers)
        default: return nil
        }
    }

    /// Builds a `sockaddr_un` for `path` and hands it to `body`. Returns nil when the path does
    /// not fit `sun_path` (104 bytes on macOS) or contains a NUL.
    static func withAddress<R>(
        path: String, _ body: (UnsafePointer<sockaddr>, socklen_t) -> R
    ) -> R? {
        var addr = sockaddr_un()
        let bytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        guard !bytes.isEmpty, bytes.count < capacity, !bytes.contains(0) else { return nil }
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        let length = socklen_t(MemoryLayout<sockaddr_un>.size)
        addr.sun_len = UInt8(length)
        return withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0, length) }
        }
    }

    /// Marks `fd` close-on-exec and immune to SIGPIPE.
    static func configure(_ fd: Int32) {
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
    }

    static func now() -> UInt64 { DispatchTime.now().uptimeNanoseconds }

    /// Milliseconds left until `deadline` (a `now()` value), rounded up, never negative.
    static func millisecondsLeft(until deadline: UInt64) -> Int32 {
        let current = now()
        guard deadline > current else { return 0 }
        let ms = (deadline - current + 999_999) / 1_000_000
        return Int32(min(ms, UInt64(Int32.max)))
    }

    /// Polls `fd` for `events`, retrying on EINTR, until `deadline`. True if it became ready.
    static func wait(fd: Int32, events: Int16, until deadline: UInt64) -> Bool {
        while true {
            var p = pollfd(fd: fd, events: events, revents: 0)
            let n = poll(&p, 1, millisecondsLeft(until: deadline))
            if n > 0 { return true }
            if n == 0 { return false }
            if errno != EINTR { return false }
        }
    }

    /// True once the other end of the Unix stream socket `fd` is gone (closed, or its process exited or
    /// was killed). A half-close (`shutdown(SHUT_WR)`, "I sent everything, still listening") is NOT
    /// this: it only ends our reading side. Polling for POLLOUT alone reports POLLHUP only when this
    /// socket can no longer send, which tells the two apart without reading or writing anything.
    static func peerHasClosed(_ fd: Int32) -> Bool {
        var p = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        while poll(&p, 1, 0) < 0 {
            if errno != EINTR { return false }
        }
        return p.revents & Int16(POLLHUP | POLLERR) != 0
    }
}

/// One waiting connection (a `PermissionRequest` or an ask) while its handler waits for a human.
///
/// The hook client writes its request line and then only waits for the reply, so the connection
/// closing means nobody is waiting any more: Claude Code shows its own prompt at the same time and
/// stops the hook once the person answers there (a "no" or Esc is followed by no other event). A
/// watcher thread notices that hang-up and cancels the handler's task, so the approval leaves the
/// queue (and the card and the phone) at once instead of when it expires. A cancelled handler's
/// reply is never written.
///
/// The watcher thread owns the connection: it writes the reply and closes the descriptor, so the
/// descriptor is never closed while it is still being polled.
private final class PermissionConnection: Sendable {
    private struct State {
        /// The handler finished or the client hung up; whichever came first decides what happens.
        var done = false
        var reply: HookReply?
    }

    /// How often a half-closed connection is checked for the client going away entirely.
    static let halfClosedCheckInterval: Int32 = 100  // ms

    private let connection: Int32
    private let wakeRead: Int32
    private let wakeWrite: Int32
    private let state = Mutex(State())

    /// Nil when no wake pipe can be made; the caller then serves the connection without a watcher.
    init?(connection: Int32) {
        var wake: [Int32] = [-1, -1]
        guard pipe(&wake) == 0 else { return nil }
        _ = fcntl(wake[0], F_SETFD, FD_CLOEXEC)
        _ = fcntl(wake[1], F_SETFD, FD_CLOEXEC)
        _ = fcntl(wake[1], F_SETNOSIGPIPE, 1)
        self.connection = connection
        self.wakeRead = wake[0]
        self.wakeWrite = wake[1]
    }

    /// Called by the handler's task with its result. A no-op once the client has hung up.
    func finish(with reply: HookReply?) {
        state.withLock { state in
            guard !state.done else { return }
            state.done = true
            state.reply = reply
            var byte: UInt8 = 1
            _ = write(wakeWrite, &byte, 1)
        }
    }

    /// Runs on the watcher thread until the handler finishes or the client hangs up, then replies
    /// (only in the first case) and closes everything.
    func watch(cancelling task: Task<Void, Never>) {
        let hungUp = waitForHangUp()
        let reply: HookReply? = state.withLock { state in
            if hungUp, !state.done {
                state.done = true  // claims the outcome: a later `finish` writes nothing
                return nil
            }
            return state.reply
        }
        // `done` is set, so `finish` no longer touches the pipe.
        close(wakeRead)
        close(wakeWrite)
        if hungUp {
            task.cancel()
        } else if let reply {
            HookSocketServer.writeAll(HookWire.replyLine(for: reply), to: connection)
        }
        close(connection)
    }

    /// True when the client went away, false when the handler finished first.
    private func waitForHangUp() -> Bool {
        var halfClosed = false
        var scratch = [UInt8](repeating: 0, count: 512)
        while true {
            var fds = [
                pollfd(fd: wakeRead, events: Int16(POLLIN), revents: 0),
                pollfd(fd: connection, events: Int16(POLLIN), revents: 0),
            ]
            // After a half-close the connection always reads as EOF, so it is only checked on a timer.
            let ready = poll(&fds, halfClosed ? 1 : 2, halfClosed ? Self.halfClosedCheckInterval : -1)
            if ready < 0 {
                if errno == EINTR { continue }
                return waitForFinish()  // cannot watch: behave as if there were no watcher
            }
            if fds[0].revents != 0 { return false }
            if HookWire.peerHasClosed(connection) { return true }
            guard !halfClosed, fds[1].revents != 0 else { continue }
            let n = recv(connection, &scratch, scratch.count, MSG_DONTWAIT)
            if n == 0 {
                halfClosed = true  // the client finished writing; it may still be waiting for the reply
            } else if n < 0, errno != EINTR, errno != EAGAIN {
                return true  // the connection failed: there is no one to answer
            }
            // n > 0: stray bytes after the request line are ignored.
        }
    }

    private func waitForFinish() -> Bool {
        var byte: UInt8 = 0
        while read(wakeRead, &byte, 1) < 0, errno == EINTR {}
        return false
    }
}

/// Reorder buffer in front of the single consumer: connections reserve a slot in accept order,
/// finish their reads in any order, and events leave in slot order.
private final class OrderedEvents: Sendable {
    private struct State {
        var issued = 0
        var next = 0
        var done: [Int: HookEvent?] = [:]
    }

    private let continuation: AsyncStream<HookEvent>.Continuation
    private let state = Mutex(State())

    init(_ continuation: AsyncStream<HookEvent>.Continuation) {
        self.continuation = continuation
    }

    func reserve() -> Int {
        state.withLock { state in
            defer { state.issued += 1 }
            return state.issued
        }
    }

    /// Marks `slot` finished (`event == nil`: nothing to deliver for it) and releases every event
    /// that is now at the head of the line. Must be called exactly once per reserved slot.
    func complete(_ slot: Int, _ event: HookEvent?) {
        state.withLock { state in
            state.done[slot] = .some(event)
            while let entry = state.done.removeValue(forKey: state.next) {
                if let event = entry { continuation.yield(event) }
                state.next += 1
            }
        }
    }

    func finish() { continuation.finish() }
}

/// Accepts hook connections on a Unix domain socket and forwards each event to `handler`.
///
/// The accept loop runs on its own thread and each connection is read on a GCD queue, so neither
/// can be starved by (or starve) the Swift concurrency pool; only `handler` runs in a `Task`.
///
/// Ordering: non-permission events are handed to `handler` one at a time, in connection-accept
/// order (which is connect order, so a client that sends event A and only then connects for event
/// B is seen in that order), by a single consumer task. Connections are read concurrently, so a
/// reorder buffer (`OrderedEvents`) holds back an event until every earlier-accepted connection
/// has finished its read. The one cost: an earlier connection that stalls delays later
/// non-permission events until its read times out (`firstByteTimeout`, 1 s, if it never sends a
/// byte; `requestReadTimeout`, 5 s, if it stalls mid-request). A
/// `PermissionRequest` gets its own task (it waits for a human) and is never held back or queued
/// behind the consumer, plus a thread that watches its connection and cancels that task when the
/// hook goes away.
public final class HookSocketServer: Sendable {
    /// `$BUDDY_SOCKET` when set, otherwise `~/Library/Application Support/Buddy/buddy.sock`.
    public static func defaultSocketPath(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        if let override = environment["BUDDY_SOCKET"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        return FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Buddy/buddy.sock")
    }

    private struct Running {
        let wakeWriteFD: Int32
        let wakeReadFD: Int32
        let finished: DispatchSemaphore
        /// Ends the ordered event stream, and with it the consumer task.
        let events: OrderedEvents
    }

    private let path: URL
    private let handler: @Sendable (HookEvent) async -> HookReply?
    private let state = Mutex<Running?>(nil)

    public init(path: URL, handler: @escaping @Sendable (HookEvent) async -> HookReply?) {
        self.path = path
        self.handler = handler
    }

    deinit { stop() }

    /// Creates the parent directory (mode 0700, only if it did not exist), replaces a dead
    /// socket file (never a regular file or a live server: those throw), binds, sets mode 0600 and starts accepting. Throws instead of crashing on any
    /// failure, including a path that is too long for `sockaddr_un`.
    public func start() throws {
        try state.withLock { running in
            guard running == nil else { throw HookSocketError.alreadyStarted }
            running = try self.bindAndServe()
        }
    }

    /// Stops accepting, closes the listener and removes the socket file. Safe to call repeatedly.
    public func stop() {
        guard let running = state.withLock({ running -> Running? in
            defer { running = nil }
            return running
        }) else { return }
        var byte: UInt8 = 1
        _ = write(running.wakeWriteFD, &byte, 1)
        running.finished.wait()  // the accept thread closes the listener and unlinks the file
        close(running.wakeWriteFD)
        close(running.wakeReadFD)
        running.events.finish()  // the consumer drains what is queued, then ends
    }

    private func bindAndServe() throws -> Running {
        let socketPath = path.path
        let fm = FileManager.default

        // Fail before touching the filesystem if the path cannot fit sockaddr_un.
        guard HookWire.withAddress(path: socketPath, { _, _ in () }) != nil else {
            throw HookSocketError.pathTooLong
        }

        let directory = path.deletingLastPathComponent()
        if !fm.fileExists(atPath: directory.path) {
            do {
                try fm.createDirectory(
                    at: directory, withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700])
            } catch {
                throw HookSocketError.system("mkdir", errno: errno)
            }
            // Only a directory this server created is ours to restrict.
            chmod(directory.path, 0o700)
        }

        // Only a dead socket left by a crashed run may be replaced. Anything else at the path is
        // not ours to delete, and a live server must not be hijacked.
        var existing = stat()
        if lstat(socketPath, &existing) == 0 {
            guard (existing.st_mode & S_IFMT) == S_IFSOCK else { throw HookSocketError.notASocket }
            switch Self.probe(socketPath) {
            case .live: throw HookSocketError.addressInUse
            case .stale: unlink(socketPath)
            case .gone: break
            case .failed(let code): throw HookSocketError.system("connect", errno: code)
            }
        }

        let listener = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listener >= 0 else { throw HookSocketError.system("socket", errno: errno) }
        HookWire.configure(listener)
        // Non-blocking so a connection that vanishes before accept() cannot stall the loop.
        _ = fcntl(listener, F_SETFL, fcntl(listener, F_GETFL) | O_NONBLOCK)

        let bound = HookWire.withAddress(path: socketPath) { address, length in
            bind(listener, address, length)
        }
        guard let bound else {
            close(listener)
            throw HookSocketError.pathTooLong
        }
        guard bound == 0 else {
            let code = errno
            close(listener)
            throw HookSocketError.system("bind", errno: code)
        }
        // chmod before listen(): nothing can connect until the mode is already restrictive.
        guard chmod(socketPath, 0o600) == 0, listen(listener, SOMAXCONN) == 0 else {
            let code = errno
            close(listener)
            unlink(socketPath)
            throw HookSocketError.system("listen", errno: code)
        }
        var created = stat()
        let inode = stat(socketPath, &created) == 0 ? created.st_ino : 0

        var wake: [Int32] = [-1, -1]
        guard pipe(&wake) == 0 else {
            let code = errno
            close(listener)
            unlink(socketPath)
            throw HookSocketError.system("pipe", errno: code)
        }
        _ = fcntl(wake[0], F_SETFD, FD_CLOEXEC)
        _ = fcntl(wake[1], F_SETFD, FD_CLOEXEC)
        // stop() must never be able to kill the process with SIGPIPE, whatever state the reader is in.
        _ = fcntl(wake[1], F_SETNOSIGPIPE, 1)

        let finished = DispatchSemaphore(value: 0)
        let handler = self.handler
        let wakeRead = wake[0]
        // One consumer, started here and ended by `stop()`, applies non-permission events in order.
        let (stream, continuation) = AsyncStream<HookEvent>.makeStream()
        let eventSink = OrderedEvents(continuation)
        Task.detached {
            for await event in stream { _ = await handler(event) }
        }
        let thread = Thread {
            Self.acceptLoop(
                listener: listener, wakeRead: wakeRead, events: eventSink, handler: handler)
            close(listener)
            // Only remove the file if it is still the one we created.
            var current = stat()
            if stat(socketPath, &current) == 0, current.st_ino == inode { unlink(socketPath) }
            finished.signal()
        }
        thread.name = "buddy.hook-socket.accept"
        thread.start()
        return Running(
            wakeWriteFD: wake[1], wakeReadFD: wake[0], finished: finished, events: eventSink)
    }

    private enum Probe {
        case live, stale, gone
        case failed(Int32)
    }

    /// Tells a live listener from a dead socket file by connecting to it once.
    private static func probe(_ path: String) -> Probe {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return .failed(errno) }
        defer { close(fd) }
        HookWire.configure(fd)
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        var code: Int32 = 0
        let result = HookWire.withAddress(path: path) { address, length -> Int32 in
            let r = connect(fd, address, length)
            code = errno
            return r
        }
        if result == 0 { return .live }
        switch code {
        case ECONNREFUSED: return .stale
        case ENOENT: return .gone
        case EINPROGRESS, EAGAIN: return .live  // busy listener: err on the side of not hijacking
        default: return .failed(code)
        }
    }

    private static func acceptLoop(
        listener: Int32, wakeRead: Int32, events: OrderedEvents,
        handler: @escaping @Sendable (HookEvent) async -> HookReply?
    ) {
        let connections = DispatchQueue(
            label: "buddy.hook-socket.connections", qos: .userInitiated, attributes: .concurrent)
        while true {
            var fds = [
                pollfd(fd: listener, events: Int16(POLLIN), revents: 0),
                pollfd(fd: wakeRead, events: Int16(POLLIN), revents: 0),
            ]
            let ready = poll(&fds, 2, -1)
            if ready < 0 {
                if errno == EINTR { continue }
                return
            }
            if fds[1].revents != 0 { return }  // stop() woke us
            if fds[0].revents & Int16(POLLIN) != 0 {
                let connection = accept(listener, nil, nil)
                if connection < 0 {
                    switch errno {
                    case EINTR, ECONNABORTED, EAGAIN: continue
                    case EMFILE, ENFILE, ENOBUFS, ENOMEM:
                        // Out of resources: back off briefly instead of spinning on the listener.
                        usleep(50_000)
                        continue
                    default: return
                    }
                }
                HookWire.configure(connection)
                // BSD sockets inherit O_NONBLOCK from the listener; connections use blocking writes.
                _ = fcntl(connection, F_SETFL, fcntl(connection, F_GETFL) & ~O_NONBLOCK)
                let slot = events.reserve()  // accept order == connect order
                connections.async {
                    serve(connection: connection, slot: slot, events: events, handler: handler)
                }
            } else if fds[0].revents != 0 {
                return  // listener error or hangup
            }
        }
    }

    /// Reads one request line, then either replies (a `waitsForReply` event with an answer) or closes.
    private static func serve(
        connection: Int32, slot: Int, events: OrderedEvents,
        handler: @escaping @Sendable (HookEvent) async -> HookReply?
    ) {
        guard let line = readLine(from: connection),
              let event = HookEvent.parse(line)
        else {
            events.complete(slot, nil)
            close(connection)  // malformed, oversized or empty: never reaches the handler
            return
        }
        if event.waitsForReply {
            events.complete(slot, nil)  // not ordered: it waits for a human and must not be held back
            guard let watched = PermissionConnection(connection: connection) else {
                Task.detached {
                    let reply = await handler(event)
                    if let reply { writeAll(HookWire.replyLine(for: reply), to: connection) }
                    close(connection)
                }
                return
            }
            let task = Task.detached { watched.finish(with: await handler(event)) }
            // Its own thread, not this queue: it can wait as long as a human takes to answer.
            let watcher = Thread { watched.watch(cancelling: task) }
            watcher.name = "buddy.hook-socket.permission"
            watcher.start()
        } else {
            close(connection)  // the client does not wait for non-permission events
            events.complete(slot, event)  // delivered serially, in accept order
        }
    }

    /// The request line without its newline, or nil when the client sent more than
    /// `maxRequestBytes` without finishing a line, stalled, or errored.
    private static func readLine(from fd: Int32) -> Data? {
        let started = HookWire.now()
        let deadline = started + UInt64(HookWire.requestReadTimeout * 1_000_000_000)
        let firstByteDeadline = started + UInt64(HookWire.firstByteTimeout * 1_000_000_000)
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while buffer.count < HookWire.maxRequestBytes {
            // Until the first byte arrives only the shorter deadline applies.
            let limit = buffer.isEmpty ? min(firstByteDeadline, deadline) : deadline
            guard HookWire.wait(fd: fd, events: Int16(POLLIN), until: limit) else { return nil }
            let want = min(chunk.count, HookWire.maxRequestBytes - buffer.count)
            let n = read(fd, &chunk, want)
            if n < 0 {
                if errno == EINTR || errno == EAGAIN { continue }
                return nil
            }
            if n == 0 { break }  // EOF: take what we have; parsing decides if it is usable
            let start = buffer.count
            buffer.append(contentsOf: chunk[0..<n])
            if let newline = buffer[start...].firstIndex(of: 0x0A) {
                return buffer.prefix(newline)
            }
        }
        // Reached the cap (or EOF) without a newline.
        return buffer.count >= HookWire.maxRequestBytes ? nil : buffer
    }

    fileprivate static func writeAll(_ data: Data, to fd: Int32) {
        data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let n = write(fd, raw.baseAddress! + offset, raw.count - offset)
                if n < 0 {
                    if errno == EINTR { continue }
                    return
                }
                offset += n
            }
        }
    }
}

#endif
