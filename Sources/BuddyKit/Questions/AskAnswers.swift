import Foundation

/// What a person gave for one question: chosen option labels, or typed text.
public enum QuestionResponse: Sendable, Equatable {
    case options([String])
    case text(String)
}

public enum AskAnswers {
    /// Builds the `answers` map Claude Code receives, keyed by the full question text. One response per
    /// question, in order. A single-select question takes exactly one of its labels; a multi-select
    /// question one or more distinct labels, joined with ", " in option order. `.text` is accepted for
    /// any question only when `allowFreeText` is true, and must not be empty or whitespace; it is
    /// stored as typed. Any invalid response makes the whole result nil.
    public static func build(
        questions: [AskQuestion], responses: [QuestionResponse], allowFreeText: Bool
    ) -> [String: String]? {
        guard questions.count == responses.count else { return nil }
        var answers: [String: String] = [:]
        for (question, response) in zip(questions, responses) {
            guard let answer = answer(for: response, to: question, allowFreeText: allowFreeText) else { return nil }
            answers[question.text] = answer
        }
        // Two questions sharing a text would overwrite each other.
        return answers.count == questions.count ? answers : nil
    }

    private static func answer(
        for response: QuestionResponse, to question: AskQuestion, allowFreeText: Bool
    ) -> String? {
        switch response {
        case .text(let text):
            guard allowFreeText, !text.allSatisfy(\.isWhitespace) else { return nil }
            return text
        case .options(let labels):
            guard !labels.isEmpty,
                  Set(labels).count == labels.count,
                  labels.allSatisfy({ label in question.options.contains { $0.label == label } }),
                  question.multiSelect || labels.count == 1 else { return nil }
            return question.options.map(\.label).filter(labels.contains).joined(separator: ", ")
        }
    }
}
