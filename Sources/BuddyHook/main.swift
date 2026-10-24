import BuddyKit
import Foundation

// Claude Code hook relay: forwards the hook JSON on stdin to the Buddy app over its Unix socket
// and prints the app's decision, if any. It always exits 0 so it can never block or fail Claude
// Code; with no app running (or no human decision) it prints nothing. With `--ask`, a PreToolUse
// of AskUserQuestion also waits for the person's answer; with `--stop`, a Stop waits for a message from the phone.
let input = (try? FileHandle.standardInput.readToEnd()) ?? Data()
let flags = CommandLine.arguments.dropFirst()
if let output = HookClient.run(
    input: input, socketPath: HookSocketServer.defaultSocketPath(), ask: flags.contains("--ask"),
    stop: flags.contains("--stop"), terminal: TerminalInfo.current()) {
    print(output)
}
exit(0)
