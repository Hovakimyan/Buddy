import BuddyKit
import Foundation
import Testing

@Suite struct QuestionSelectionTests {
    private let questions = [
        AskQuestion(
            text: "Which database?", header: "Database",
            options: [AskOption(label: "Postgres", description: nil), AskOption(label: "SQLite", description: nil)],
            multiSelect: false),
        AskQuestion(
            text: "Which extras?", header: "Extras",
            options: [
                AskOption(label: "Auth", description: nil), AskOption(label: "Cache", description: nil),
                AskOption(label: "Logs", description: nil),
            ],
            multiSelect: true),
    ]

    @Test func nothingIsPickedAtFirstSoNothingCanBeSent() {
        let selection = QuestionSelection(questions: questions)
        #expect(!selection.isComplete)
        #expect(!selection.hasPick(question: 0))
        #expect(selection.responses == [[], []])
    }

    @Test func aSingleChoiceQuestionKeepsOnlyTheLatestPick() {
        var selection = QuestionSelection(questions: questions)
        selection.toggle(question: 0, option: 0)
        selection.toggle(question: 0, option: 1)
        #expect(selection.isSelected(question: 0, option: 1))
        #expect(!selection.isSelected(question: 0, option: 0))
        // Tapping the picked row again keeps it picked (a radio row does not turn off).
        selection.toggle(question: 0, option: 1)
        #expect(selection.isSelected(question: 0, option: 1))
    }

    @Test func aMultiSelectQuestionTogglesAndKeepsOptionOrder() {
        var selection = QuestionSelection(questions: questions)
        selection.toggle(question: 1, option: 2)
        selection.toggle(question: 1, option: 0)
        selection.toggle(question: 1, option: 1)
        selection.toggle(question: 1, option: 1)  // off again
        #expect(selection.responses[1] == ["Auth", "Logs"])
    }

    @Test func sendingIsPossibleOnceEveryQuestionHasAPick() {
        var selection = QuestionSelection(questions: questions)
        selection.toggle(question: 0, option: 0)
        #expect(!selection.isComplete)
        selection.toggle(question: 1, option: 1)
        #expect(selection.isComplete)
        #expect(selection.responses == [["Postgres"], ["Cache"]])
        selection.toggle(question: 1, option: 1)  // untick the only extra
        #expect(!selection.isComplete)
    }

    @Test func outOfRangeTapsChangeNothing() {
        var selection = QuestionSelection(questions: questions)
        selection.toggle(question: 5, option: 0)
        selection.toggle(question: 0, option: 9)
        #expect(selection == QuestionSelection(questions: questions))
    }
}
