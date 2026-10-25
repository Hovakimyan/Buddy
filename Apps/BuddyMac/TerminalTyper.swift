import AppKit
import BuddyKit
import Foundation
import OSLog

private let log = Logger(subsystem: "com.sergeyhovakimyan.buddy", category: "typing")

/// Types a message from the phone into the terminal a Claude Code session runs in, so it shows as the person's own
/// prompt: into its tmux pane (any terminal app), or its iTerm2 or Terminal tab found by tty. It types only when no
/// key was pressed on the Mac for `quietBeforeTyping` (never into what someone is typing; moving the mouse is fine)
/// and only while Claude Code is the program in front on that tty (never into a shell, where the text would run as a
/// command). Anything else returns false (and logs why), and the message goes through the `Stop` hook instead.
enum TerminalTyper {
    static let quietBeforeTyping: TimeInterval = 3

    static func type(_ terminal: TerminalInfo, _ text: String) async -> Bool {
        guard let tty = terminal.tty, !text.contains("\n") else { return false }
        let sinceKey = secondsSinceKeyPress()
        guard sinceKey >= quietBeforeTyping else {
            log.notice("not typed into \(tty, privacy: .public): a key was pressed \(sinceKey, privacy: .public) s ago")
            return false
        }
        guard await claudeIsInFront(tty: tty) else {
            log.notice("not typed into \(tty, privacy: .public): Claude Code is not the program in front")
            return false
        }
        let typed: Bool
        if let pane = terminal.tmuxPane, let socket = terminal.tmuxSocket {
            typed = await tmux(socket: socket, pane: pane, text: text)
        } else {
            switch terminal.program {
            case TerminalInfo.iTerm?: typed = await MainActor.run { run(iTermScript(tty: tty, text: text)) }
            case TerminalInfo.appleTerminal?: typed = await MainActor.run { run(terminalScript(tty: tty, text: text)) }
            default: typed = false
            }
        }
        log.notice("\(typed ? "typed" : "could not type", privacy: .public) into \(tty, privacy: .public) (\(terminal.program ?? "?", privacy: .public))")
        return typed
    }

    /// Seconds since a key was last pressed on this Mac (no permission needed).
    static func secondsSinceKeyPress() -> TimeInterval {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .keyDown)
    }

    // MARK: Is Claude Code in front?

    /// Whether a process of the tty's foreground group is Claude Code (`ps` marks the foreground group with "+").
    static func claudeIsInFront(tty: String) async -> Bool {
        let name = (tty as NSString).lastPathComponent
        guard let listing = await output(of: "/bin/ps", ["-t", name, "-o", "stat=,args="]) else { return false }
        return isClaudeInFront(psListing: listing)
    }

    static func isClaudeInFront(psListing: String) -> Bool {
        psListing.split(separator: "\n").contains { line in
            let fields = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            guard fields.count == 2, fields[0].contains("+") else { return false }
            let command = fields[1].split(separator: " ").first.map { ($0 as NSString).lastPathComponent } ?? ""
            return command == "claude" || (command == "node" && fields[1].contains("claude"))
        }
    }

    // MARK: tmux

    private static let tmuxPaths = ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux"]

    private static func tmux(socket: String, pane: String, text: String) async -> Bool {
        guard let tmux = tmuxPaths.first(where: FileManager.default.isExecutableFile(atPath:)) else { return false }
        // The text literally (-l: no key names), then Enter on its own, as a person would type it.
        guard await output(of: tmux, ["-S", socket, "send-keys", "-t", pane, "-l", text]) != nil else { return false }
        return await output(of: tmux, ["-S", socket, "send-keys", "-t", pane, "Enter"]) != nil
    }

    // MARK: iTerm2 and Terminal

    /// An AppleScript string literal of `text` (one line: backslashes and quotes escaped).
    static func literal(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    static func iTermScript(tty: String, text: String) -> String {
        """
        tell application id "com.googlecode.iterm2"
            repeat with w in windows
                repeat with t in tabs of w
                    repeat with s in sessions of t
                        if tty of s is \(literal(tty)) then
                            tell s to write text \(literal(text))
                            return "typed"
                        end if
                    end repeat
                end repeat
            end repeat
        end tell
        return "missing"
        """
    }

    static func terminalScript(tty: String, text: String) -> String {
        """
        tell application id "com.apple.Terminal"
            repeat with w in windows
                repeat with t in tabs of w
                    if tty of t is \(literal(tty)) then
                        do script \(literal(text)) in t
                        return "typed"
                    end if
                end repeat
            end repeat
        end tell
        return "missing"
        """
    }

    /// Runs a script (the first run asks the person to let Buddy control that app); true when it typed.
    @MainActor private static func run(_ source: String) -> Bool {
        var error: NSDictionary?
        let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error {
            // The number is public; the message stays private: it can quote the script, which holds the message text.
            log.error("""
                script failed: \(error[NSAppleScript.errorNumber] as? Int ?? 0, privacy: .public) \
                \(String(describing: error[NSAppleScript.errorMessage] ?? error), privacy: .private)
                """)
        }
        return error == nil && result?.stringValue == "typed"
    }

    // MARK: Processes

    /// The standard output of a finished process with exit status 0; nil otherwise. Arguments are passed as an
    /// array, never through a shell.
    private static func output(of path: String, _ arguments: [String]) async -> String? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: path)
                process.arguments = arguments
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = FileHandle.nullDevice
                do {
                    try process.run()
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()
                    continuation.resume(returning: process.terminationStatus == 0 ? String(decoding: data, as: UTF8.self) : nil)
                } catch {
                    continuation.resume(returning: nil)
                }
            }
        }
    }
}
