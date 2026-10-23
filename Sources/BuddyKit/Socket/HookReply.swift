import Foundation

/// What a person chose for a plan: the three ways to answer Claude Code's plan approval.
public enum PlanChoice: String, Codable, Sendable {
    /// Keep planning: the changes are typed in the terminal.
    case change
    /// Approve the plan and let edits through without asking.
    case acceptEdits
    /// Approve the plan and keep asking before each edit.
    case askEachTime
}

/// What the app tells the `buddy-hook` relay to print for one hook call.
public enum HookReply: Sendable, Equatable {
    /// Allow or deny a `PermissionRequest`.
    case decision(Decision)
    /// Approve or send back a plan.
    case plan(PlanChoice)
    /// Answers to an `AskUserQuestion`, keyed by question text; a multi-select answer joins its
    /// labels with ", ".
    case answers([String: String])
}
