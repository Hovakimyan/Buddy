import BuddyKit
import CoreGraphics
import Foundation

/// What a press on the question card led to.
enum CardAction: Equatable, Sendable {
    case none
    /// The next question shows.
    case advanced
    /// Every question has its answer: send these, one per question in order.
    case send([QuestionResponse])
}

/// What the question card's controls report to the window controller.
enum QuestionCardEvent: Equatable, Sendable {
    case pick(String)
    /// Keys 1-4: the option at that place.
    case number(Int)
    /// Next or Send (or Return in the field).
    case next
    case openOther
    case cancelOther
    /// "Answer in terminal".
    case answerInTerminal
}

/// The question card's state, pure so it is unit-tested without a view (spec 6.3). One question shows at a time.
/// Single select moves on with the pick (and sends after the last); multi select toggles, and Next / Send moves on once
/// one is picked. "Other..." opens a field whose text is the answer (`.text`, at most `maxOtherLength` scalars).
/// Option picks only count once the card has been drawn for `IslandLogic.armingDelay`, and again once each next
/// question has shown that long, so a click aimed at something else (or a second click) cannot answer.
struct QuestionCardModel: Equatable, Sendable {
    /// The question's request id.
    let id: UUID
    let questions: [AskQuestion]
    /// The question showing.
    private(set) var index = 0
    /// Each question's chosen labels so far.
    private(set) var selections: [Set<String>]
    /// The "Other..." field's text while it is open; nil while it is closed. Cut to `maxOtherLength` scalars.
    var otherText: String? {
        didSet {
            if let otherText, otherText.unicodeScalars.count > Self.maxOtherLength {
                self.otherText = String(String.UnicodeScalarView(otherText.unicodeScalars.prefix(Self.maxOtherLength)))
            }
        }
    }
    /// Since when the card has been drawn without a break (the window controller's arming clock); nil while it is not.
    var shownAt: Date?
    /// When the question showing replaced the one before it; nil for the first. It must show for the arming delay
    /// too before a pick counts.
    private(set) var questionShownAt: Date?
    private var answers: [QuestionResponse?]
    private var sent = false

    /// The longest typed answer, in Unicode scalars. A scalar is at most 4 bytes of UTF-8, or 6 as an escaped control
    /// character, so four answers (the most one call asks) stay under 48 KB, well inside one hook reply
    /// (`HookWire.maxReplyBytes`, 64 KiB). The engine still refuses a reply that would not fit.
    static let maxOtherLength = 2_000

    init(question: PendingQuestion) {
        id = question.id
        questions = question.questions
        selections = Array(repeating: [], count: question.questions.count)
        answers = Array(repeating: nil, count: question.questions.count)
    }

    var current: AskQuestion { questions[index] }
    private var isLast: Bool { index == questions.count - 1 }

    /// "i/N" when there are several questions.
    var progress: String? { questions.count > 1 ? "\(index + 1)/\(questions.count)" : nil }

    /// Every question's answer, once each has one.
    var responses: [QuestionResponse]? {
        let given = answers.compactMap { $0 }
        return given.count == questions.count ? given : nil
    }

    /// Whether Next / Send would move on: text typed in the open field, or at least one pick of a multi-select question.
    var canAdvance: Bool {
        if let otherText { return !Self.isBlank(otherText) }
        return current.multiSelect && !selections[index].isEmpty
    }

    /// Next / Send shows for a multi-select question and while the field is open.
    var showsFooter: Bool { current.multiSelect || otherText != nil }
    var footerTitle: String { isLast ? "Send" : "Next" }

    func isArmed(now: Date) -> Bool {
        guard let shownAt else { return false }
        return IslandLogic.isArmed(shownAt: max(shownAt, questionShownAt ?? shownAt), now: now)
    }

    mutating func pick(_ label: String, now: Date) -> CardAction {
        guard !sent, isArmed(now: now), current.options.contains(where: { $0.label == label }) else { return .none }
        otherText = nil
        if current.multiSelect {
            if selections[index].contains(label) {
                selections[index].remove(label)
            } else {
                selections[index].insert(label)
            }
            return .none
        }
        selections[index] = [label]
        answers[index] = .options([label])
        return advance(now: now)
    }

    /// Keys 1-4: the option at place `n` (from 1) of the question showing.
    mutating func pressNumber(_ n: Int, now: Date) -> CardAction {
        guard current.options.indices.contains(n - 1) else { return .none }
        return pick(current.options[n - 1].label, now: now)
    }

    mutating func next(now: Date) -> CardAction {
        guard !sent, isArmed(now: now), canAdvance else { return .none }
        if let otherText {
            answers[index] = .text(otherText)
            self.otherText = nil
        } else {
            answers[index] = .options(current.options.map(\.label).filter(selections[index].contains))
        }
        return advance(now: now)
    }

    /// The engine refused the answers sent (`feed.answer` returned false): the card takes picks again.
    mutating func answerRefused() {
        sent = false
    }

    mutating func openOther() {
        if otherText == nil { otherText = "" }
    }

    mutating func cancelOther() {
        otherText = nil
    }

    /// The next question restarts the arming delay: a double click or a key pressed twice must not answer it unread.
    private mutating func advance(now: Date) -> CardAction {
        guard isLast else {
            index += 1
            questionShownAt = now
            return .advanced
        }
        guard let responses else { return .none }
        sent = true
        return .send(responses)
    }

    /// Options are drawn as a list (each with its description) when any option has a description, as a row of chips
    /// otherwise.
    static func usesList(_ question: AskQuestion) -> Bool {
        question.options.contains { !isBlank($0.description ?? "") }
    }

    private static func isBlank(_ text: String) -> Bool { text.allSatisfy(\.isWhitespace) }
}

// MARK: - Layout

/// Sizes of the question card, shared by the view and the island's height (`naturalHeight`). The estimate need not be
/// exact: what does not fit scrolls inside the card.
enum QuestionCardLayout {
    static let padding: CGFloat = 10
    static let spacing: CGFloat = 8
    static let topRowHeight: CGFloat = 16
    static let headerHeight: CGFloat = 16
    static let questionLineHeight: CGFloat = 17
    /// Characters per line of the 13 pt question text, low so the estimate errs tall.
    static let questionColumns = 70
    static let chipHeight: CGFloat = 28
    /// A list row: its label, plus its description's lines.
    static let rowBaseHeight: CGFloat = 30
    static let descriptionLineHeight: CGFloat = 14
    static let descriptionColumns = 80
    static let rowSpacing: CGFloat = 4
    static let controlHeight: CGFloat = 26
}

extension QuestionCardModel {
    /// The card's height with nothing scrolled away: the top row, the header, the question, its options, "Other..." (or
    /// the field) and, when shown, Next / Send.
    var naturalHeight: CGFloat {
        typealias L = QuestionCardLayout
        let question = current
        var height = 2 * L.padding + L.topRowHeight + L.spacing + L.headerHeight + 4
        height += CGFloat(CardText.lineCount(of: DisplayText.sanitized(question.text), columns: L.questionColumns))
            * L.questionLineHeight
        height += L.spacing
        if Self.usesList(question) {
            for option in question.options {
                let description = DisplayText.sanitized(option.description ?? "")
                let lines = Self.isBlank(description)
                    ? 0 : CardText.lineCount(of: description, columns: L.descriptionColumns)
                height += L.rowBaseHeight + CGFloat(lines) * L.descriptionLineHeight
            }
            height += CGFloat(question.options.count - 1) * L.rowSpacing
        } else {
            height += L.chipHeight
        }
        height += L.spacing + L.controlHeight
        if showsFooter { height += L.spacing + L.controlHeight }
        return height
    }
}
