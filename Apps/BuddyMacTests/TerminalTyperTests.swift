import Foundation
import Testing

@Suite struct TerminalTyperTests {
    @Test func typingNeedsClaudeCodeInFrontNeverAShell() {
        #expect(TerminalTyper.isClaudeInFront(psListing: "Ss   -zsh\nS+   claude --model haiku\n"))
        #expect(TerminalTyper.isClaudeInFront(psListing: "S+   /usr/local/bin/node /usr/local/lib/node_modules/@anthropic-ai/claude-code/cli.js\n"))
        // Claude exited: the shell is in front, so nothing is typed (it would run as a command).
        #expect(!TerminalTyper.isClaudeInFront(psListing: "Ss+  -zsh\n"))
        // Claude is there but in the background (a job), not in front.
        #expect(!TerminalTyper.isClaudeInFront(psListing: "S+   vim notes\nT    claude\n"))
        #expect(!TerminalTyper.isClaudeInFront(psListing: ""))
    }

    @Test func textIsQuotedSoItCannotBreakOutOfTheScript() {
        #expect(TerminalTyper.literal(#"say "hi" \ done"#) == #""say \"hi\" \\ done""#)
        let script = TerminalTyper.iTermScript(tty: "/dev/ttys004", text: #"" & do shell script "x"#)
        #expect(script.contains(#"write text "\" & do shell script \"x""#))
        #expect(script.contains(#"tty of s is "/dev/ttys004""#))
        #expect(TerminalTyper.terminalScript(tty: "/dev/ttys004", text: "hi").contains(#"do script "hi" in t"#))
    }
}
