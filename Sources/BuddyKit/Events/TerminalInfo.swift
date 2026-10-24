import Foundation

/// Where a Claude Code session runs, as its hook relay saw it: the terminal app (`TERM_PROGRAM`), the session's tty
/// and, inside tmux, its pane. The Mac uses it to type a message from the phone into exactly that place, so it shows as
/// the person's own prompt. Every field is checked against a strict shape; anything else is dropped.
public struct TerminalInfo: Codable, Sendable, Equatable {
    /// `TERM_PROGRAM`, such as `iTerm.app` or `Apple_Terminal`.
    public var program: String?
    /// The controlling terminal, such as `/dev/ttys004`.
    public var tty: String?
    /// `TMUX_PANE`, such as `%3`.
    public var tmuxPane: String?
    /// The tmux server's socket (the first field of `TMUX`).
    public var tmuxSocket: String?

    public init(program: String? = nil, tty: String? = nil, tmuxPane: String? = nil, tmuxSocket: String? = nil) {
        self.program = program.flatMap { Self.matches($0, #"^[A-Za-z0-9._-]{1,64}$"#) }
        self.tty = tty.flatMap { Self.matches($0, #"^/dev/ttys[0-9]{1,4}$"#) }
        self.tmuxPane = tmuxPane.flatMap { Self.matches($0, #"^%[0-9]{1,6}$"#) }
        self.tmuxSocket = tmuxSocket.flatMap { Self.matches($0, #"^/[A-Za-z0-9._/-]{1,200}$"#) }
    }

    public static let iTerm = "iTerm.app"
    public static let appleTerminal = "Apple_Terminal"

    /// Whether Buddy knows how to type into this place: a tmux pane (in any terminal app), or an iTerm2 or Terminal
    /// session found by its tty. Anything else gets messages through the `Stop` hook instead.
    public var isTypable: Bool {
        if tmuxPane != nil, tmuxSocket != nil, tty != nil { return true }
        return tty != nil && (program == Self.iTerm || program == Self.appleTerminal)
    }

    var isEmpty: Bool { program == nil && tty == nil && tmuxPane == nil }

    /// What the relay process sees: its environment, and the terminal it (and so Claude Code) is attached to.
    public static func current(environment: [String: String] = ProcessInfo.processInfo.environment) -> TerminalInfo? {
        let info = TerminalInfo(
            program: environment["TERM_PROGRAM"], tty: controllingTerminal(),
            tmuxPane: environment["TMUX_PANE"],
            tmuxSocket: environment["TMUX"].flatMap { $0.split(separator: ",").first.map(String.init) })
        return info.isEmpty ? nil : info
    }

    /// The terminal Claude Code runs in. Claude Code starts hooks without a terminal of their own (`/dev/tty` fails
    /// there), so this walks up the parent processes until one has a terminal: Claude Code itself.
    private static func controllingTerminal() -> String? {
        let fd = open("/dev/tty", O_RDONLY | O_NOCTTY)
        if fd >= 0 {
            defer { close(fd) }
            if let name = ttyname(fd) { return String(cString: name) }
        }
        var pid = getppid()
        for _ in 0..<8 where pid > 1 {
            guard let process = processInfo(pid) else { return nil }
            let device = process.kp_eproc.e_tdev
            if device != -1, device != 0, let name = devname(device, S_IFCHR) {
                return "/dev/" + String(cString: name)
            }
            pid = process.kp_eproc.e_ppid
        }
        return nil
    }

    private static func processInfo(_ pid: pid_t) -> kinfo_proc? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        return info
    }

    private static func matches(_ value: String, _ pattern: String) -> String? {
        value.range(of: pattern, options: .regularExpression) != nil ? value : nil
    }

    // The wire form inside a hook payload (`buddy_terminal`), written only by the relay.
    var json: JSONValue {
        var members: [String: JSONValue] = [:]
        if let program { members["program"] = .string(program) }
        if let tty { members["tty"] = .string(tty) }
        if let tmuxPane { members["tmux_pane"] = .string(tmuxPane) }
        if let tmuxSocket { members["tmux_socket"] = .string(tmuxSocket) }
        return .object(members)
    }

    init?(json: JSONValue?) {
        guard case .object(let members)? = json else { return nil }
        func text(_ key: String) -> String? { if case .string(let value)? = members[key] { value } else { nil } }
        self.init(program: text("program"), tty: text("tty"), tmuxPane: text("tmux_pane"), tmuxSocket: text("tmux_socket"))
        if isEmpty { return nil }
    }
}
