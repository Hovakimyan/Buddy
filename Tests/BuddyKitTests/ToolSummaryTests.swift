import Foundation
import Testing
@testable import BuddyKit

@Suite struct ToolSummaryTests {
    @Test func bashShowsCommand() {
        let input = JSONValue.object(["command": .string("ls -la"), "description": .string("list")])
        let summary = ToolSummary.make(toolName: "Bash", toolInput: input)
        #expect(summary.text == "ls -la")
        #expect(!summary.isTruncated)
    }

    @Test func editShowsFilePath() {
        let input = JSONValue.object([
            "file_path": .string("/Users/me/proj/main.swift"),
            "old_string": .string("a"),
            "new_string": .string("b"),
        ])
        for tool in ["Read", "Edit", "Write", "MultiEdit"] {
            let summary = ToolSummary.make(toolName: tool, toolInput: input)
            #expect(summary.text == "/Users/me/proj/main.swift")
            #expect(!summary.isTruncated)
        }
    }

    @Test func otherToolsShowEveryFieldSorted() {
        let grep = ToolSummary.make(
            toolName: "Grep", toolInput: .object(["pattern": .string("foo"), "path": .string("/src")]))
        #expect(grep.text == "path: /src\npattern: foo")
        #expect(!grep.isTruncated)

        let fetch = ToolSummary.make(
            toolName: "WebFetch",
            toolInput: .object(["url": .string("https://example.com/x"), "prompt": .string("summarise")]))
        #expect(fetch.text == "prompt: summarise\nurl: https://example.com/x")

        let mcp = ToolSummary.make(
            toolName: "mcp__github__create_issue",
            toolInput: .object([
                "repo": .string("example/x"),
                "labels": .array([.string("bug"), .number(2)]),
                "draft": .bool(false),
                "meta": .object(["b": .null, "a": .number(1.5)]),
            ]))
        #expect(mcp.text == #"draft: false\#nlabels: ["bug",2]\#nmeta: {"a":1.5,"b":null}\#nrepo: example/x"#)
        #expect(!mcp.isTruncated)
    }

    @Test func noInputShowsTheToolName() {
        #expect(ToolSummary.make(toolName: "ExitPlanMode", toolInput: nil).text == "ExitPlanMode")
        #expect(ToolSummary.make(toolName: "ExitPlanMode", toolInput: .object([:])).text == "ExitPlanMode")
        #expect(!ToolSummary.make(toolName: "ExitPlanMode", toolInput: nil).isTruncated)
    }

    @Test func aWellKnownToolWithoutItsFieldShowsWhatItHas() {
        let summary = ToolSummary.make(toolName: "Bash", toolInput: .object(["cmd": .string("rm -rf /")]))
        #expect(summary.text == "cmd: rm -rf /")
        #expect(ToolSummary.make(toolName: "Bash", toolInput: nil).text == "Bash")
    }

    @Test func notebookEditShowsTheNotebook() {
        let summary = ToolSummary.make(
            toolName: "NotebookEdit", toolInput: .object(["notebook_path": .string("/a.ipynb"), "new_source": .string("x")]))
        #expect(summary.text == "/a.ipynb")
    }

    @Test func bashOutsideTheSandboxSaysSo() {
        let off = ToolSummary.make(
            toolName: "Bash", toolInput: .object(["command": .string("ls"), "dangerouslyDisableSandbox": .bool(true)]))
        #expect(off.text == "[sandbox off] ls")
        let on = ToolSummary.make(
            toolName: "Bash", toolInput: .object(["command": .string("ls"), "dangerouslyDisableSandbox": .bool(false)]))
        #expect(on.text == "ls")
        // The marker counts towards the limit: a command that only fits without it is cut and cannot be allowed.
        let long = ToolSummary.make(
            toolName: "Bash",
            toolInput: .object(["command": .string(String(repeating: "x", count: 195)), "dangerouslyDisableSandbox": .bool(true)]))
        #expect(long.isTruncated)
        #expect(long.text.hasPrefix(ToolSummary.sandboxOffMarker))
    }

    @Test func longCommandIsTruncatedWithEllipsisAndFlagged() {
        let command = String(repeating: "x", count: 300)
        let summary = ToolSummary.make(toolName: "Bash", toolInput: .object(["command": .string(command)]))
        #expect(summary.text.count == 200)
        #expect(summary.text.hasSuffix("…"))
        #expect(summary.text == String(repeating: "x", count: 199) + "…")
        #expect(summary.isTruncated)
    }

    @Test func shortCommandNotTruncated() {
        let command = String(repeating: "y", count: 200)
        let summary = ToolSummary.make(toolName: "Bash", toolInput: .object(["command": .string(command)]))
        #expect(summary.text == command)
        #expect(!summary.isTruncated)
    }

    @Test func multiMegabyteInputStaysBounded() {
        let huge = String(repeating: "a", count: 8 * 1024 * 1024)
        let bash = ToolSummary.make(toolName: "Bash", toolInput: .object(["command": .string(huge)]))
        #expect(bash.text.count == 200)
        #expect(bash.isTruncated)

        let write = ToolSummary.make(
            toolName: "Write",
            toolInput: .object(["file_path": .string("/tmp/a.txt"), "content": .string(huge)]))
        #expect(write.text == "/tmp/a.txt")

        let other = ToolSummary.make(toolName: "Task", toolInput: .object(["prompt": .string(huge)]))
        #expect(other.text.count == 200)
        #expect(other.text.hasPrefix("prompt: aaa"))
        #expect(other.isTruncated, "a prompt that cannot be shown in full cannot be allowed")

        let many = JSONValue.array(Array(repeating: .string(huge), count: 50))
        let nested = ToolSummary.make(toolName: "mcp__x__y", toolInput: .object(["items": many]))
        #expect(nested.text.count == 200)
        #expect(nested.isTruncated)
    }
}
