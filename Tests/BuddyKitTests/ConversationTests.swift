import Foundation
import Testing
@testable import BuddyKit

/// Each session keeps its latest prompt and Claude's reply to it, so the phone shows where the conversation stands.
@Suite struct ConversationTests {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func thePromptAndTheReplyComeFromTheirHookFields() {
        let prompt = HookEvent.parse(Data(#"{"session_id":"s","hook_event_name":"UserPromptSubmit","prompt":"Fix the tests"}"#.utf8))
        #expect(prompt?.prompt == "Fix the tests")
        let stop = HookEvent.parse(Data(#"{"session_id":"s","hook_event_name":"Stop","last_assistant_message":"All green."}"#.utf8))
        #expect(stop?.lastAssistantMessage == "All green.")
        // Another type is ignored, never a reason to drop the event.
        let odd = HookEvent.parse(Data(#"{"session_id":"s","hook_event_name":"Stop","last_assistant_message":7}"#.utf8))
        #expect(odd?.name == .stop)
        #expect(odd?.lastAssistantMessage == nil)
    }

    @Test func aNewPromptClearsTheOldReplyUntilItsOwnComes() {
        var store = SessionStore()
        store.apply(HookEvent(sessionId: "s", name: .userPromptSubmit, prompt: "first"), now: t0)
        store.apply(HookEvent(sessionId: "s", name: .stop, lastAssistantMessage: "first reply"), now: t0 + 1)
        #expect(store.sessions.first?.lastPrompt == "first")
        #expect(store.sessions.first?.lastReply == "first reply")
        store.apply(HookEvent(sessionId: "s", name: .userPromptSubmit, prompt: "second"), now: t0 + 2)
        #expect(store.sessions.first?.lastPrompt == "second")
        #expect(store.sessions.first?.lastReply == nil)
        // A subagent finishing is not the conversation's reply.
        store.apply(HookEvent(sessionId: "s", name: .subagentStop, agentId: "a", lastAssistantMessage: "agent"), now: t0 + 3)
        #expect(store.sessions.first?.lastReply == nil)
    }

    @Test func longTextsKeepTheStartOfAPromptAndTheEndOfAReply() {
        let prompt = Session.keptPrompt(String(repeating: "p", count: Session.promptLimit) + "END")
        #expect(prompt.count == Session.promptLimit)
        #expect(prompt.hasSuffix("…") && prompt.hasPrefix("ppp"))
        let reply = Session.keptReply("START" + String(repeating: "r", count: Session.replyLimit) + "recap")
        #expect(reply.count == Session.replyLimit)
        #expect(reply.hasPrefix("…") && reply.hasSuffix("recap"))
        #expect(Session.keptReply("  short \n") == "short")
    }

    @Test func aMessageFromThePhoneBecomesThePromptTheNextReplyAnswers() {
        var store = SessionStore()
        store.apply(HookEvent(sessionId: "s", name: .stop, lastAssistantMessage: "done"), now: t0)
        store.notePrompt("Now add docs", sessionId: "s")
        #expect(store.sessions.first?.lastPrompt == "Now add docs")
        #expect(store.sessions.first?.lastReply == nil)
    }
}
