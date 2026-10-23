#if os(macOS)
import Foundation

/// The blocking relay behind the `buddy-hook` executable. Never throws and never blocks longer
/// than its timeouts, so a missing or misbehaving app cannot stall Claude Code.
public enum HookClient: Sendable {
    /// Bound on delivering a payload to a server that accepted the connection but is not reading.
    private static let sendTimeout: TimeInterval = 2

    /// How long a `PermissionRequest` waits for the app's reply by default. The app's own approval
    /// timeout (`BuddyEngine.defaultApprovalTimeout`) is shorter, so an approval always ends on
    /// the app's side first and a decision that is accepted can still be delivered.
    public static let defaultWaitTimeout: TimeInterval = 110

    /// How long an ask (`--ask` on an `AskUserQuestion` call) waits by default. The engine closes a
    /// question after 120 s, so the app's own end comes first here too.
    public static let askWaitTimeout: TimeInterval = 125

    /// Forwards `input` (the hook JSON from stdin) to the app listening on `socketPath`.
    ///
    /// Returns the string to print on stdout, or nil if there is nothing to print: the payload is
    /// not a valid hook event (nothing is sent), nobody is listening, the app made no decision,
    /// the reply was not one of the exact reply lines, or the wait timeout elapsed. Only a
    /// `PermissionRequest`, or an ask, waits for a reply; every other event returns right after
    /// sending. An ask is `ask` (the `--ask` flag) on a `PreToolUse` of `AskUserQuestion`: the
    /// relay itself marks that line `"buddy_ask": true` and removes the key from every other line,
    /// so only the flag, never the payload, makes the server wait. `waitTimeout` defaults to
    /// `askWaitTimeout` for an ask and `defaultWaitTimeout` otherwise.
    public static func run(
        input: Data,
        socketPath: URL,
        ask: Bool = false,
        connectTimeout: TimeInterval = 0.3,
        waitTimeout: TimeInterval? = nil
    ) -> String? {
        guard let event = HookEvent.parse(input) else { return nil }
        let isAsk = ask && event.name == .preToolUse && event.toolName == "AskUserQuestion"
        guard let line = requestLine(from: input, ask: isAsk, strayFlag: event.isAsk) else { return nil }
        guard let fd = connect(to: socketPath, timeout: connectTimeout) else { return nil }
        defer { close(fd) }

        let waitsForReply = event.name == .permissionRequest || isAsk
        let waitTimeout = waitTimeout ?? (isAsk ? askWaitTimeout : defaultWaitTimeout)
        let started = HookWire.now()
        let sendDeadline = started + nanoseconds(waitsForReply ? waitTimeout : sendTimeout)
        guard send(line, to: fd, until: sendDeadline), waitsForReply else { return nil }

        let replyDeadline = started + nanoseconds(waitTimeout)
        guard let reply = readReply(from: fd, until: replyDeadline) else { return nil }
        return HookOutput.stdout(for: HookWire.reply(fromReply: reply), event: event)
    }

    private static func nanoseconds(_ seconds: TimeInterval) -> UInt64 {
        UInt64(max(0, min(seconds, 1_000_000)) * 1_000_000_000)
    }

    /// The payload as a single newline-terminated line, with `buddy_ask` set to true for an ask and
    /// removed when the payload sets it without being one (`strayFlag`, as the server's own parser
    /// reads it, so an escaped key cannot slip through). In valid JSON a raw CR or LF can only be
    /// inter-token whitespace, so pretty-printed input is flattened rather than split. Any other
    /// payload is sent as it came; only these two cases are decoded and encoded again.
    private static func requestLine(from input: Data, ask: Bool, strayFlag: Bool) -> Data? {
        var payload = input
        if ask || strayFlag {
            // Too deeply nested to rewrite: send nothing rather than a line with the wrong flag.
            guard var members = try? JSONDecoder().decode([String: JSONValue].self, from: input),
                  members["buddy_ask"] != nil || ask
            else { return nil }
            members["buddy_ask"] = ask ? .bool(true) : nil
            guard let rewritten = try? JSONEncoder().encode(members) else { return nil }
            payload = rewritten
        }
        var line = Data(payload.map { $0 == 0x0A || $0 == 0x0D ? 0x20 : $0 })
        while line.last == 0x20 { line.removeLast() }
        guard line.count <= HookEvent.maxPayloadSize else { return nil }
        line.append(0x0A)
        return line
    }

    /// How long `connect` keeps retrying a refused connection to an existing socket file, at most.
    private static let refusedRetryBudget: TimeInterval = 0.15
    private static let refusedRetryFirstDelay: UInt32 = 2_000  // microseconds, doubles per retry
    private static let refusedRetryMaxDelay: UInt32 = 20_000

    private enum Attempt {
        case connected(Int32)
        /// ECONNREFUSED: nobody is listening, or the listener's backlog is full right now.
        case refused
        case failed
    }

    /// A connected, non-blocking socket, or nil if nothing accepted within `timeout`.
    ///
    /// A missing socket file (ENOENT) returns nil at once: no app is running. When the file
    /// exists but the connection is refused, the listener's backlog may just be full (a burst of
    /// hooks), so that is retried with a short backoff for at most `refusedRetryBudget` (and never
    /// beyond `timeout`). A stale file with no listener therefore costs at most that budget.
    private static func connect(to path: URL, timeout: TimeInterval) -> Int32? {
        let started = HookWire.now()
        let deadline = started + nanoseconds(timeout)
        let retryDeadline = started + nanoseconds(min(timeout, refusedRetryBudget))
        var delay = refusedRetryFirstDelay
        while true {
            switch attempt(path: path, until: deadline) {
            case .connected(let fd): return fd
            case .failed: return nil
            case .refused:
                var info = stat()
                guard stat(path.path, &info) == 0 else { return nil }  // file gone: no server
                guard HookWire.now() + UInt64(delay) * 1_000 < retryDeadline else { return nil }
                usleep(delay)
                delay = min(delay * 2, refusedRetryMaxDelay)
            }
        }
    }

    private static func attempt(path: URL, until deadline: UInt64) -> Attempt {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return .failed }
        HookWire.configure(fd)
        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else {
            close(fd)
            return .failed
        }

        let result = HookWire.withAddress(path: path.path) { address, length in
            Darwin.connect(fd, address, length)
        }
        guard let result else {  // path too long for sockaddr_un
            close(fd)
            return .failed
        }
        if result == 0 { return .connected(fd) }
        guard errno == EINPROGRESS else {  // ENOENT, ECONNREFUSED, EACCES, ...
            let refused = errno == ECONNREFUSED
            close(fd)
            return refused ? .refused : .failed
        }

        var failure: Int32 = 0
        var size = socklen_t(MemoryLayout<Int32>.size)
        guard HookWire.wait(fd: fd, events: Int16(POLLOUT), until: deadline),
              getsockopt(fd, SOL_SOCKET, SO_ERROR, &failure, &size) == 0,
              failure == 0
        else {
            close(fd)
            return failure == ECONNREFUSED ? .refused : .failed
        }
        return .connected(fd)
    }

    private static func send(_ data: Data, to fd: Int32, until deadline: UInt64) -> Bool {
        data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let n = write(fd, raw.baseAddress! + offset, raw.count - offset)
                if n > 0 {
                    offset += n
                } else if n < 0, errno == EINTR {
                    continue
                } else if n < 0, errno == EAGAIN || errno == EWOULDBLOCK {
                    guard HookWire.wait(fd: fd, events: Int16(POLLOUT), until: deadline) else { return false }
                } else {
                    return false
                }
            }
            return true
        }
    }

    /// The reply line (without newline), or nil on timeout, error, EOF with nothing, or overflow.
    private static func readReply(from fd: Int32, until deadline: UInt64) -> Data? {
        var reply = Data()
        var chunk = [UInt8](repeating: 0, count: HookWire.maxReplyBytes)
        while reply.count <= HookWire.maxReplyBytes {
            guard HookWire.wait(fd: fd, events: Int16(POLLIN), until: deadline) else { return nil }
            let n = read(fd, &chunk, chunk.count)
            if n < 0 {
                if errno == EINTR || errno == EAGAIN { continue }
                return nil
            }
            if n == 0 { return reply.isEmpty ? nil : reply }
            reply.append(contentsOf: chunk[0..<n])
            if let newline = reply.firstIndex(of: 0x0A) { return reply.prefix(newline) }
        }
        return nil
    }
}

#endif
