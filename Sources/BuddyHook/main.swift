import BuddyKit
import Foundation

// Claude Code hook relay: forwards the hook JSON on stdin to the Buddy app over its Unix socket
// and prints the app's decision, if any. It always exits 0 so it can never block or fail Claude
// Code; with no app running (or no human decision) it prints nothing. With `--ask`, a PreToolUse
// of AskUserQuestion also waits for the person's answer.
let input = (try? FileHandle.standardInput.readToEnd()) ?? Data()
let ask = CommandLine.arguments.dropFirst().contains("--ask")
if let output = HookClient.run(input: input, socketPath: HookSocketServer.defaultSocketPath(), ask: ask) {
    print(output)
}
exit(0)
