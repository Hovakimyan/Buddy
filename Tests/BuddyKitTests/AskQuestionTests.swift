import Foundation
import Testing
@testable import BuddyKit

@Suite struct AskQuestionTests {
    private static func option(_ label: String, description: String? = nil) -> JSONValue {
        var fields: [String: JSONValue] = ["label": .string(label)]
        if let description { fields["description"] = .string(description) }
        return .object(fields)
    }

    private static func question(
        _ text: String = "Format?",
        header: JSONValue? = .string("Format"),
        options: [JSONValue]? = nil,
        multiSelect: JSONValue? = nil
    ) -> JSONValue {
        var fields: [String: JSONValue] = [
            "question": .string(text),
            "options": .array(options ?? [option("Dot"), option("Plain")]),
        ]
        if let header { fields["header"] = header }
        if let multiSelect { fields["multiSelect"] = multiSelect }
        return .object(fields)
    }

    private static func input(_ questions: [JSONValue]) -> JSONValue {
        .object(["questions": .array(questions)])
    }

    private static func options(_ labels: [String]) -> [JSONValue] { labels.map { option($0) } }

    private static func parsed(_ questions: [JSONValue]) -> [AskQuestion]? {
        AskQuestion.parseSet(toolInput: input(questions))
    }

    @Test func validSetParses() throws {
        let one = try #require(Self.parsed([Self.question()]))
        #expect(one == [
            AskQuestion(
                text: "Format?", header: "Format",
                options: [AskOption(label: "Dot", description: nil), AskOption(label: "Plain", description: nil)],
                multiSelect: false)
        ])

        let four = try #require(Self.parsed([
            Self.question("Q1?", options: [Self.option("A", description: "first"), Self.option("B")]),
            Self.question("Q2?", multiSelect: .bool(true)),
            Self.question("Q3?", multiSelect: .bool(false)),
            Self.question("Q4?", options: Self.options(["A", "B", "C", "D"])),
        ]))
        #expect(four.map(\.text) == ["Q1?", "Q2?", "Q3?", "Q4?"])
        #expect(four[0].options == [AskOption(label: "A", description: "first"), AskOption(label: "B", description: nil)])
        #expect(four.map(\.multiSelect) == [false, true, false, false])
        #expect(four[3].options.count == 4)
    }

    @Test func invalidSetsRejected() {
        let twelve = String(repeating: "h", count: 12)
        #expect(Self.parsed([Self.question("Q?", header: .string(twelve))]) != nil)
        #expect(Self.parsed([Self.question("Q?", header: .string(""))]) != nil)

        #expect(Self.parsed([]) == nil)
        #expect(Self.parsed((1...5).map { Self.question("Q\($0)?") }) == nil)
        #expect(Self.parsed([Self.question("Q?", options: Self.options(["A"]))]) == nil)
        #expect(Self.parsed([Self.question("Q?", options: Self.options(["A", "B", "C", "D", "E"]))]) == nil)
        #expect(Self.parsed([Self.question("")]) == nil)
        #expect(Self.parsed([Self.question("  ")]) == nil)
        #expect(Self.parsed([Self.question("Q?", options: [Self.option(""), Self.option("B")])]) == nil)
        #expect(Self.parsed([Self.question("Q?", header: .string(twelve + "x"))]) == nil)
        #expect(Self.parsed([Self.question("Same?"), Self.question("Same?")]) == nil)
        #expect(Self.parsed([Self.question("Q?", multiSelect: .string("yes"))]) == nil)

        #expect(AskQuestion.parseSet(toolInput: .object(["questions": .string("nope")])) == nil)
        #expect(AskQuestion.parseSet(toolInput: .object([:])) == nil)
        #expect(AskQuestion.parseSet(toolInput: nil) == nil)
        #expect(AskQuestion.parseSet(toolInput: .string("x")) == nil)
    }

    @Test func malformedFieldsRejected() {
        #expect(Self.parsed([Self.question("Q?", header: nil)]) == nil)
        #expect(Self.parsed([Self.question("Q?", header: .number(1))]) == nil)
        #expect(Self.parsed([Self.question("Q?", options: [Self.option("A", description: "d"), .object(["label": .string("B"), "description": .number(1)])])]) == nil)
        #expect(Self.parsed([Self.question("Q?", options: [Self.option("A"), Self.option("A")])]) == nil)
        #expect(Self.parsed([Self.question("Q?", options: [Self.option("A"), .object([:])])]) == nil)
        #expect(Self.parsed([.string("not an object")]) == nil)
        #expect(Self.parsed([.object(["question": .string("Q?"), "header": .string("H")])]) == nil)
    }

    private static let format = AskQuestion(
        text: "Format?", header: "Format",
        options: [AskOption(label: "Dot", description: nil), AskOption(label: "Plain", description: nil)],
        multiSelect: false)
    private static let letters = AskQuestion(
        text: "Which?", header: "Which",
        options: ["A", "B", "C"].map { AskOption(label: $0, description: nil) },
        multiSelect: true)

    @Test func singleSelectAnswer() {
        let answers = AskAnswers.build(
            questions: [Self.format], responses: [.options(["Dot"])], allowFreeText: false)
        #expect(answers == ["Format?": "Dot"])
    }

    @Test func multiSelectJoinsInOptionOrder() {
        let answers = AskAnswers.build(
            questions: [Self.letters], responses: [.options(["C", "A"])], allowFreeText: false)
        #expect(answers == ["Which?": "A, C"])
    }

    @Test func severalQuestionsKeyedByText() {
        let answers = AskAnswers.build(
            questions: [Self.format, Self.letters],
            responses: [.options(["Plain"]), .options(["B"])],
            allowFreeText: false)
        #expect(answers == ["Format?": "Plain", "Which?": "B"])
    }

    @Test func freeTextOnlyWhenAllowed() {
        for question in [Self.format, Self.letters] {
            #expect(AskAnswers.build(questions: [question], responses: [.text("x")], allowFreeText: true)
                == [question.text: "x"])
            #expect(AskAnswers.build(questions: [question], responses: [.text("x")], allowFreeText: false) == nil)
        }
        #expect(AskAnswers.build(questions: [Self.format], responses: [.text(" hi ")], allowFreeText: true)
            == ["Format?": " hi "])
        for blank in ["", "   ", "\n\t"] {
            #expect(AskAnswers.build(questions: [Self.format], responses: [.text(blank)], allowFreeText: true) == nil)
        }
    }

    @Test func invalidResponsesRejected() {
        func build(_ q: [AskQuestion], _ r: [QuestionResponse]) -> [String: String]? {
            AskAnswers.build(questions: q, responses: r, allowFreeText: true)
        }
        #expect(build([Self.format], []) == nil)
        #expect(build([Self.format], [.options(["Dot"]), .options(["Dot"])]) == nil)
        #expect(build([Self.format], [.options(["Nope"])]) == nil)
        #expect(build([Self.format], [.options([])]) == nil)
        #expect(build([Self.format], [.options(["Dot", "Plain"])]) == nil)
        #expect(build([Self.letters], [.options(["A", "A"])]) == nil)
        #expect(build([Self.letters], [.options(["A", "Z"])]) == nil)
        #expect(build([Self.letters], [.options([])]) == nil)
        // One bad response spoils the whole map.
        #expect(build([Self.format, Self.letters], [.options(["Dot"]), .options(["Z"])]) == nil)
    }
}
