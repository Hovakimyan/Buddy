import Foundation
import Testing
@testable import BuddyKit

@Suite struct SessionStoreTests {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func event(
        _ name: HookEventName,
        id: String = "s1",
        cwd: String? = "/Users/me/proj",
        tool: String? = nil,
        message: String? = nil,
        notificationType: String? = nil
    ) -> HookEvent {
        HookEvent(
            sessionId: id, name: name, cwd: cwd, toolName: tool, toolInput: nil, message: message,
            notificationType: notificationType)
    }

    @Test func sessionStartCreatesIdle() {
        var store = SessionStore()
        store.apply(event(.sessionStart), now: t0)
        #expect(store.sessions.count == 1)
        #expect(store.sessions[0].id == "s1")
        #expect(store.sessions[0].state == .idle)
        #expect(store.sessions[0].lastTool == nil)
        #expect(store.sessions[0].updatedAt == t0)
    }

    /// Only a real SessionStart counts as a start: a session first seen through another event (it was running before
    /// Buddy started, or came back after expiring) has none, so nothing announces it as new.
    @Test func onlySessionStartCountsAsAStart() {
        var store = SessionStore()
        store.apply(event(.sessionStart), now: t0)
        #expect(store.sessions[0].starts == 1)
        store.apply(event(.userPromptSubmit), now: t0 + 1)
        store.apply(event(.preToolUse, tool: "Bash"), now: t0 + 2)
        store.apply(event(.stop), now: t0 + 3)
        #expect(store.sessions[0].starts == 1)
        store.apply(event(.sessionStart), now: t0 + 4)
        #expect(store.sessions[0].starts == 2)

        store.apply(event(.preToolUse, id: "running", tool: "Read"), now: t0 + 5)
        #expect(store.sessions.first { $0.id == "running" }?.starts == 0)
    }

    @Test func promptAndToolsSetWorkingAndLastTool() {
        var store = SessionStore()
        store.apply(event(.sessionStart), now: t0)
        store.apply(event(.userPromptSubmit), now: t0 + 1)
        #expect(store.sessions[0].state == .working)
        #expect(store.sessions[0].lastTool == nil)
        store.apply(event(.preToolUse, tool: "Bash"), now: t0 + 2)
        #expect(store.sessions[0].state == .working)
        #expect(store.sessions[0].lastTool == "Bash")
        store.apply(event(.postToolUseFailure, tool: "Edit"), now: t0 + 3)
        #expect(store.sessions[0].state == .working)
        #expect(store.sessions[0].lastTool == "Edit")
        #expect(store.sessions[0].updatedAt == t0 + 3)
    }

    @Test func permissionRequestSetsWaiting() {
        var store = SessionStore()
        store.apply(event(.preToolUse, tool: "Bash"), now: t0)
        store.apply(event(.permissionRequest, tool: "Bash"), now: t0 + 1)
        #expect(store.sessions[0].state == .waiting)
    }

    @Test func notificationSetsWaiting() {
        var store = SessionStore()
        store.apply(event(.userPromptSubmit), now: t0)
        store.apply(event(.notification, message: "needs input"), now: t0 + 1)
        #expect(store.sessions[0].state == .waiting)
    }

    // Claude Code sends an idle reminder ("Claude is waiting for your input") about a minute after a
    // turn ends. It is not a question: it must not open the island or bring a finished session back.
    @Test func idlePromptNotificationLeavesAFinishedSessionIdle() {
        var store = SessionStore()
        store.apply(event(.userPromptSubmit), now: t0)
        store.apply(event(.stop), now: t0 + 1)
        store.expire(now: t0 + 7)
        #expect(store.sessions[0].state == .idle)
        store.apply(
            event(.notification, message: "Claude is waiting for your input", notificationType: "idle_prompt"),
            now: t0 + 61)
        #expect(store.sessions[0].state == .idle)
        #expect(store.sessions[0].updatedAt == t0 + 1)  // nothing happened in the session
    }

    @Test func idlePromptNotificationChangesNoState() {
        for name in [HookEventName.stop, .stopFailure, .userPromptSubmit, .sessionStart] {
            var store = SessionStore()
            store.apply(event(name), now: t0)
            let before = store.sessions
            store.apply(event(.notification, notificationType: "idle_prompt"), now: t0 + 2)
            #expect(store.sessions == before, "\(name)")
        }
    }

    @Test func idleMessageWithoutATypeIsAnIdlePromptToo() {
        var store = SessionStore()
        store.apply(event(.sessionStart), now: t0)
        store.apply(event(.notification, message: "Claude is waiting for your input"), now: t0 + 1)
        #expect(store.sessions[0].state == .idle)
    }

    @Test func permissionAndUnknownNotificationsSetWaiting() {
        let cases: [(String?, String?)] = [
            ("permission_prompt", "Claude needs your permission to use Bash"),
            ("permission_prompt", "Claude is waiting for your input"),  // the type wins over the text
            ("auth_success", nil),
            (nil, "Claude needs your permission to use Bash"),
            (nil, nil),
        ]
        for (type, message) in cases {
            var store = SessionStore()
            store.apply(event(.sessionStart), now: t0)
            store.apply(event(.notification, message: message, notificationType: type), now: t0 + 1)
            #expect(store.sessions[0].state == .waiting, "\(String(describing: type)) \(String(describing: message))")
        }
    }

    @Test func idlePromptOfAnUnknownSessionCreatesItIdle() {
        var store = SessionStore()
        store.apply(event(.notification, notificationType: "idle_prompt"), now: t0)
        #expect(store.sessions.map(\.state) == [.idle])
    }

    @Test func postToolUseReturnsToWorking() {
        var store = SessionStore()
        store.apply(event(.permissionRequest, tool: "Bash"), now: t0)
        #expect(store.sessions[0].state == .waiting)
        store.apply(event(.postToolUse, tool: "Bash"), now: t0 + 1)
        #expect(store.sessions[0].state == .working)
        #expect(store.sessions[0].lastTool == "Bash")
    }

    @Test func stopSetsFinishedThenIdleAfter5s() {
        var store = SessionStore()
        store.apply(event(.userPromptSubmit), now: t0)
        store.apply(event(.stop), now: t0 + 10)
        #expect(store.sessions[0].state == .finished)

        store.expire(now: t0 + 14.9)
        #expect(store.sessions[0].state == .finished)

        store.expire(now: t0 + 15)
        #expect(store.sessions.count == 1)
        #expect(store.sessions[0].state == .idle)
    }

    @Test func stopFailureSetsError() {
        var store = SessionStore()
        store.apply(event(.userPromptSubmit), now: t0)
        store.apply(event(.stopFailure), now: t0 + 1)
        #expect(store.sessions[0].state == .error)
        store.expire(now: t0 + 60)
        #expect(store.sessions[0].state == .error)
    }

    @Test func sessionEndRemoves() {
        var store = SessionStore()
        store.apply(event(.sessionStart), now: t0)
        store.apply(event(.sessionStart, id: "s2"), now: t0 + 1)
        store.apply(event(.sessionEnd), now: t0 + 2)
        #expect(store.sessions.map(\.id) == ["s2"])
        store.apply(event(.sessionEnd, id: "never-seen"), now: t0 + 3)
        #expect(store.sessions.map(\.id) == ["s2"])
    }

    @Test func expiresAfter30MinutesIdle() {
        var store = SessionStore()
        store.apply(event(.sessionStart), now: t0)
        store.expire(now: t0 + 1799)
        #expect(store.sessions.count == 1)
        store.expire(now: t0 + 1800)
        #expect(store.sessions.isEmpty)
    }

    @Test func projectIsLastPathComponent() {
        var store = SessionStore()
        store.apply(event(.sessionStart, id: "a", cwd: "/Users/me/work/buddy"), now: t0)
        store.apply(event(.sessionStart, id: "b", cwd: "/Users/me/work/trailing/"), now: t0 + 1)
        store.apply(event(.sessionStart, id: "c", cwd: nil), now: t0 + 2)
        let projects = Dictionary(uniqueKeysWithValues: store.sessions.map { ($0.id, $0.project) })
        #expect(projects == ["a": "buddy", "b": "trailing", "c": "unknown"])
    }

    @Test func unknownSessionEventCreatesSession() {
        var store = SessionStore()
        store.apply(event(.preToolUse, id: "late", tool: "Read"), now: t0)
        #expect(store.sessions.count == 1)
        #expect(store.sessions[0].id == "late")
        #expect(store.sessions[0].state == .working)
        #expect(store.sessions[0].lastTool == "Read")
    }

    @Test func sortedMostRecentFirst() {
        var store = SessionStore()
        store.apply(event(.sessionStart, id: "old"), now: t0)
        store.apply(event(.sessionStart, id: "new"), now: t0 + 20)
        store.apply(event(.sessionStart, id: "mid"), now: t0 + 10)
        #expect(store.sessions.map(\.id) == ["new", "mid", "old"])
        store.apply(event(.userPromptSubmit, id: "old"), now: t0 + 30)
        #expect(store.sessions.map(\.id) == ["old", "new", "mid"])
    }

    // MARK: Activity

    @Test func newSessionStartsWithNoActivity() {
        var store = SessionStore()
        store.apply(event(.sessionStart), now: t0)
        #expect(store.sessions[0].activity == .none)
        #expect(store.sessions[0].recentTools.isEmpty)
        #expect(store.sessions[0].toolCount == 0)
    }

    @Test func promptSetsThinkingAndResetsToolCount() {
        var store = SessionStore()
        store.apply(event(.preToolUse, tool: "Edit"), now: t0)
        store.apply(event(.preToolUse, tool: "Edit"), now: t0 + 1)
        #expect(store.sessions[0].toolCount == 2)
        store.apply(event(.userPromptSubmit), now: t0 + 2)
        #expect(store.sessions[0].activity == .thinking)
        #expect(store.sessions[0].toolCount == 0)
    }

    @Test(arguments: ["Grep", "Glob", "WebSearch", "WebFetch"])
    func searchingToolsSetSearching(tool: String) {
        var store = SessionStore()
        store.apply(event(.userPromptSubmit), now: t0)
        store.apply(event(.preToolUse, tool: tool), now: t0 + 1)
        #expect(store.sessions[0].activity == .searching)
        #expect(store.sessions[0].toolCount == 1)
    }

    @Test func otherToolClearsActivityAndCountsTheCall() {
        var store = SessionStore()
        store.apply(event(.userPromptSubmit), now: t0)
        store.apply(event(.preToolUse, tool: "Grep"), now: t0 + 1)
        store.apply(event(.preToolUse, tool: "Edit"), now: t0 + 2)
        #expect(store.sessions[0].activity == SessionActivity.none)
        #expect(store.sessions[0].toolCount == 2)
    }

    @Test func postToolEventsLeaveActivityAlone() {
        var store = SessionStore()
        store.apply(event(.preToolUse, tool: "Grep"), now: t0)
        store.apply(event(.postToolUse, tool: "Grep"), now: t0 + 1)
        #expect(store.sessions[0].activity == .searching)
        #expect(store.sessions[0].toolCount == 1)
    }

    // A tool finishing means Claude is running again: an earlier question or rate-limit notice is over.
    @Test(arguments: [
        (HookEventName.postToolUse, "You hit a rate limit"), (.postToolUse, "Continue?"),
        (.postToolUseFailure, "You hit a rate limit"), (.postToolUseFailure, "Continue?"),
    ])
    func postToolEventsEndAskingAndRateLimited(name: HookEventName, message: String) {
        var store = SessionStore()
        store.apply(event(.preToolUse, tool: "Bash"), now: t0)
        store.apply(event(.notification, message: message), now: t0 + 1)
        #expect(store.sessions[0].activity != SessionActivity.none)
        store.apply(event(name, tool: "Bash"), now: t0 + 2)
        #expect(store.sessions[0].state == .working)
        #expect(store.sessions[0].activity == SessionActivity.none)
        let resolved = CharacterState.resolve(
            session: store.sessions[0], approvalPending: false, questionPending: false, quietFor: 0,
            islandVisible: true)
        #expect(resolved == .working)
    }

    @Test func rateLimitNotificationIsCaseInsensitive() {
        var store = SessionStore()
        store.apply(event(.userPromptSubmit), now: t0)
        store.apply(event(.notification, message: "You hit a Rate Limit"), now: t0 + 1)
        #expect(store.sessions[0].activity == .rateLimited)
    }

    @Test func questionMarkNotificationSetsAsking() {
        var store = SessionStore()
        store.apply(event(.userPromptSubmit), now: t0)
        store.apply(event(.notification, message: "Continue?  \n"), now: t0 + 1)
        #expect(store.sessions[0].activity == .asking)
    }

    @Test func otherNotificationLeavesActivityAlone() {
        var store = SessionStore()
        store.apply(event(.userPromptSubmit), now: t0)
        store.apply(event(.notification, message: "Claude needs your permission"), now: t0 + 1)
        #expect(store.sessions[0].activity == .thinking)
    }

    @Test(arguments: [HookEventName.stop, .stopFailure, .sessionStart])
    func endingEventsClearActivity(name: HookEventName) {
        var store = SessionStore()
        store.apply(event(.userPromptSubmit), now: t0)
        store.apply(event(name), now: t0 + 1)
        #expect(store.sessions[0].activity == SessionActivity.none)
    }

    @Test func recentToolsKeepsLastThreeNewestLast() {
        var store = SessionStore()
        for (i, tool) in ["Bash", "Read", "Edit", "Grep"].enumerated() {
            store.apply(event(.preToolUse, tool: tool), now: t0 + Double(i))
        }
        #expect(store.sessions[0].recentTools == ["Read", "Edit", "Grep"])
        #expect(store.sessions[0].toolCount == 4)
    }
}
