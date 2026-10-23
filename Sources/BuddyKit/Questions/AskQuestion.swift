import Foundation

/// One choice of an `AskUserQuestion` question.
public struct AskOption: Codable, Sendable, Equatable {
    public let label: String
    public let description: String?

    public init(label: String, description: String?) {
        self.label = label
        self.description = description
    }
}

/// One question of an `AskUserQuestion` tool call.
public struct AskQuestion: Codable, Sendable, Equatable {
    /// The full question, which is also the key of its answer.
    public let text: String
    public let header: String
    public let options: [AskOption]
    public let multiSelect: Bool

    public init(text: String, header: String, options: [AskOption], multiSelect: Bool) {
        self.text = text
        self.header = header
        self.options = options
        self.multiSelect = multiSelect
    }

    public static let questionCountRange = 1...4
    public static let optionCountRange = 2...4
    public static let maxHeaderLength = 12

    /// Reads the questions of an `AskUserQuestion` `tool_input`. All or nothing: nil unless the
    /// whole set is well formed, so a malformed call never reaches a card. Valid means 1-4 questions
    /// with distinct, non-blank text; each with a string `header` of at most 12 characters, 2-4
    /// options with distinct, non-blank labels (and a string `description` if any), and a bool
    /// `multiSelect` if present (absent means false).
    public static func parseSet(toolInput: JSONValue?) -> [AskQuestion]? {
        guard case .object(let input)? = toolInput,
              case .array(let items)? = input["questions"],
              questionCountRange.contains(items.count) else { return nil }
        var questions: [AskQuestion] = []
        for item in items {
            guard let question = parse(item),
                  !questions.contains(where: { $0.text == question.text }) else { return nil }
            questions.append(question)
        }
        return questions
    }

    private static func parse(_ value: JSONValue) -> AskQuestion? {
        guard case .object(let fields) = value,
              case .string(let text)? = fields["question"], !isBlank(text),
              case .string(let header)? = fields["header"], header.count <= maxHeaderLength,
              case .array(let rawOptions)? = fields["options"],
              optionCountRange.contains(rawOptions.count) else { return nil }
        var multiSelect = false
        if let raw = fields["multiSelect"] {
            guard case .bool(let flag) = raw else { return nil }
            multiSelect = flag
        }
        var options: [AskOption] = []
        for raw in rawOptions {
            guard let option = parseOption(raw),
                  !options.contains(where: { $0.label == option.label }) else { return nil }
            options.append(option)
        }
        return AskQuestion(text: text, header: header, options: options, multiSelect: multiSelect)
    }

    private static func parseOption(_ value: JSONValue) -> AskOption? {
        guard case .object(let fields) = value,
              case .string(let label)? = fields["label"], !isBlank(label) else { return nil }
        var description: String?
        if let raw = fields["description"] {
            guard case .string(let text) = raw else { return nil }
            description = text
        }
        return AskOption(label: label, description: description)
    }

    private static func isBlank(_ text: String) -> Bool {
        text.allSatisfy(\.isWhitespace)
    }
}
