import BuddyKit
import Foundation
import Testing

private let t0 = Date(timeIntervalSince1970: 1_000)
/// Well past the arming delay.
private let armed = t0.addingTimeInterval(IslandLogic.armingDelay + 0.1)
/// Well past the arming delay of a question that showed at `armed`.
private let later = armed.addingTimeInterval(IslandLogic.armingDelay + 0.1)

private func ask(
    _ text: String, _ labels: [String], multi: Bool = false, descriptions: [String?]? = nil
) -> AskQuestion {
    let options = labels.enumerated().map { index, label in
        AskOption(label: label, description: descriptions?[index])
    }
    return AskQuestion(text: text, header: "Pick", options: options, multiSelect: multi)
}

private func card(_ questions: [AskQuestion], shownAt: Date? = t0) -> QuestionCardModel {
    var model = QuestionCardModel(question: PendingQuestion(
        id: UUID(), sessionId: "s1", agentId: nil, questions: questions, createdAt: t0,
        expiresAt: t0.addingTimeInterval(120)))
    model.shownAt = shownAt
    return model
}

@Suite struct QuestionCardModelTests {
    @Test func singleSelectAdvancesThenSendsAfterTheLast() {
        var model = card([ask("Colour?", ["Red", "Blue"]), ask("Size?", ["S", "M", "L"])])
        #expect(model.index == 0)
        #expect(model.progress == "1/2")
        #expect(model.pick("Blue", now: armed) == .advanced)
        #expect(model.index == 1)
        #expect(model.progress == "2/2")
        #expect(model.responses == nil)
        #expect(model.pick("M", now: later) == .send([.options(["Blue"]), .options(["M"])]))
        #expect(model.responses == [.options(["Blue"]), .options(["M"])])
    }

    @Test func aSingleQuestionHasNoProgressAndSendsOnThePick() {
        var model = card([ask("Colour?", ["Red", "Blue"])])
        #expect(model.progress == nil)
        #expect(model.pick("Red", now: armed) == .send([.options(["Red"])]))
    }

    @Test func nothingIsSentTwice() {
        var model = card([ask("Colour?", ["Red", "Blue"])])
        #expect(model.pick("Red", now: armed) == .send([.options(["Red"])]))
        #expect(model.pick("Blue", now: armed) == CardAction.none)
        #expect(model.next(now: armed) == CardAction.none)
    }

    /// A send the engine refused (the question was already resolved, or the reply too big) leaves the card usable.
    @Test func aRefusedSendCanBeAnsweredAgain() {
        var model = card([ask("Colour?", ["Red", "Blue"]), ask("Size?", ["S", "M"])])
        #expect(model.pick("Red", now: armed) == .advanced)
        #expect(model.pick("S", now: later) == .send([.options(["Red"]), .options(["S"])]))
        model.answerRefused()
        #expect(model.index == 1)
        #expect(model.pick("M", now: later) == .send([.options(["Red"]), .options(["M"])]))
    }

    @Test func multiSelectTogglesAndSendIsEnabledOnceOneIsPicked() {
        var model = card([ask("Which?", ["A", "B", "C"], multi: true)])
        #expect(!model.canAdvance)
        #expect(model.next(now: armed) == CardAction.none)
        #expect(model.pick("C", now: armed) == CardAction.none)
        #expect(model.canAdvance)
        #expect(model.pick("A", now: armed) == CardAction.none)
        #expect(model.selections[0] == ["A", "C"])
        #expect(model.pick("C", now: armed) == CardAction.none)
        #expect(model.selections[0] == ["A"])
        #expect(model.pick("A", now: armed) == CardAction.none)
        #expect(!model.canAdvance)
        _ = model.pick("C", now: armed)
        _ = model.pick("A", now: armed)
        // In option order, whatever order they were picked in.
        #expect(model.next(now: armed) == .send([.options(["A", "C"])]))
    }

    @Test func multiSelectFirstThenSingleSelect() {
        var model = card([ask("Which?", ["A", "B"], multi: true), ask("Colour?", ["Red", "Blue"])])
        _ = model.pick("B", now: armed)
        #expect(model.next(now: armed) == .advanced)
        #expect(model.index == 1)
        #expect(model.pick("Red", now: later) == .send([.options(["B"]), .options(["Red"])]))
    }

    @Test func keysOneToFourPickTheOptionAtThatPlace() {
        var model = card([ask("Size?", ["S", "M", "L", "XL"]), ask("Colour?", ["Red", "Blue"])])
        #expect(model.pressNumber(4, now: armed) == .advanced)
        #expect(model.pressNumber(3, now: later) == CardAction.none)  // only two options here
        #expect(model.pressNumber(0, now: later) == CardAction.none)
        #expect(model.index == 1)
        #expect(model.pressNumber(1, now: later) == .send([.options(["XL"]), .options(["Red"])]))
    }

    @Test func keysToggleAMultiSelectQuestion() {
        var model = card([ask("Which?", ["A", "B", "C"], multi: true)])
        _ = model.pressNumber(2, now: armed)
        _ = model.pressNumber(3, now: armed)
        #expect(model.selections[0] == ["B", "C"])
    }

    @Test func otherTextIsSentAsText() {
        var model = card([ask("Colour?", ["Red", "Blue"]), ask("Size?", ["S", "M"])])
        #expect(model.otherText == nil)
        model.openOther()
        #expect(model.otherText == "")
        #expect(!model.canAdvance)
        #expect(model.next(now: armed) == CardAction.none)  // nothing typed yet
        model.otherText = "   "
        #expect(model.next(now: armed) == CardAction.none)  // blank is no answer
        model.otherText = "Teal, please"
        #expect(model.canAdvance)
        #expect(model.next(now: armed) == .advanced)
        #expect(model.otherText == nil)  // the field closes for the next question
        model.openOther()
        model.otherText = "Huge"
        #expect(model.next(now: later) == .send([.text("Teal, please"), .text("Huge")]))
    }

    @Test func escapeClosesTheFieldWithoutAnswering() {
        var model = card([ask("Colour?", ["Red", "Blue"])])
        model.openOther()
        model.otherText = "Teal"
        model.cancelOther()
        #expect(model.otherText == nil)
        #expect(model.index == 0)
        #expect(model.responses == nil)
        // Opening again starts empty.
        model.openOther()
        #expect(model.otherText == "")
    }

    @Test func pickingAnOptionClosesTheField() {
        var model = card([ask("Which?", ["A", "B"], multi: true)])
        model.openOther()
        model.otherText = "x"
        _ = model.pick("A", now: armed)
        #expect(model.otherText == nil)
        #expect(model.next(now: armed) == .send([.options(["A"])]))
    }

    @Test func picksInsideTheArmingDelayAreIgnored() {
        var model = card([ask("Colour?", ["Red", "Blue"])])
        let early = t0.addingTimeInterval(IslandLogic.armingDelay - 0.05)
        #expect(model.pick("Red", now: early) == CardAction.none)
        #expect(model.pressNumber(1, now: early) == CardAction.none)
        #expect(model.selections[0].isEmpty)
        #expect(model.pick("Red", now: t0.addingTimeInterval(IslandLogic.armingDelay)) == .send([.options(["Red"])]))
    }

    /// A double click, or "1" pressed twice, must not answer the next question unread: it waits for the delay again.
    @Test func theNextQuestionWaitsForTheArmingDelayAgain() {
        var model = card([ask("Colour?", ["Red", "Blue"]), ask("Size?", ["S", "M"])])
        #expect(model.pressNumber(1, now: armed) == .advanced)
        #expect(model.questionShownAt == armed)
        #expect(!model.isArmed(now: armed))
        #expect(model.pressNumber(1, now: armed.addingTimeInterval(0.05)) == CardAction.none)
        #expect(model.pick("S", now: armed.addingTimeInterval(IslandLogic.armingDelay - 0.05)) == CardAction.none)
        #expect(model.next(now: armed) == CardAction.none)
        #expect(model.selections[1].isEmpty)
        #expect(model.responses == nil)
        #expect(model.isArmed(now: armed.addingTimeInterval(IslandLogic.armingDelay)))
        #expect(model.pressNumber(1, now: armed.addingTimeInterval(IslandLogic.armingDelay)) == .send([
            .options(["Red"]), .options(["S"]),
        ]))
    }

    /// The card's own clock (`shownAt`, restarted by the window) does not undo the next question's delay.
    @Test func anOlderShownAtDoesNotArmTheNextQuestionEarly() {
        var model = card([ask("Which?", ["A", "B"], multi: true), ask("Colour?", ["Red", "Blue"])])
        _ = model.pick("A", now: armed)
        #expect(model.next(now: armed) == .advanced)
        model.shownAt = t0
        #expect(model.pick("Red", now: armed.addingTimeInterval(0.1)) == CardAction.none)
        model.shownAt = armed
        #expect(model.pick("Red", now: later) == .send([.options(["A"]), .options(["Red"])]))
    }

    @Test func typedTextIsCutAtTheCap() {
        #expect(QuestionCardModel.maxOtherLength == 2_000)
        var model = card([ask("Colour?", ["Red", "Blue"])])
        model.openOther()
        model.otherText = String(repeating: "a", count: QuestionCardModel.maxOtherLength)
        #expect(model.otherText?.unicodeScalars.count == QuestionCardModel.maxOtherLength)
        model.otherText = String(repeating: "\u{1F600}", count: QuestionCardModel.maxOtherLength + 50)
        #expect(model.otherText?.unicodeScalars.count == QuestionCardModel.maxOtherLength)
        guard case .send(let responses) = model.next(now: armed), case .text(let text) = responses.first else {
            Issue.record("the capped text is sent")
            return
        }
        #expect(text.unicodeScalars.count == QuestionCardModel.maxOtherLength)
        // Four capped answers, even as 4-byte characters, fit one hook reply with room to spare.
        #expect(4 * text.utf8.count < 48 * 1024)  // the hook reply limit is 64 KiB
    }

    @Test func nothingIsPickedWhileTheCardIsNotDrawn() {
        var model = card([ask("Colour?", ["Red", "Blue"])], shownAt: nil)
        #expect(model.pick("Red", now: armed) == CardAction.none)
        #expect(!model.isArmed(now: armed))
    }

    @Test func multiSelectTogglesInsideTheDelayAreIgnoredToo() {
        var model = card([ask("Which?", ["A", "B"], multi: true)])
        _ = model.pick("A", now: t0)
        #expect(model.selections[0].isEmpty)
    }

    @Test func unknownLabelsAreIgnored() {
        var model = card([ask("Colour?", ["Red", "Blue"])])
        #expect(model.pick("Green", now: armed) == CardAction.none)
        #expect(model.responses == nil)
    }

    @Test func aListIsUsedOnlyWhenAnOptionHasADescription() {
        #expect(!QuestionCardModel.usesList(ask("Colour?", ["Red", "Blue"])))
        #expect(!QuestionCardModel.usesList(ask("Colour?", ["Red", "Blue"], descriptions: ["", "  "])))
        #expect(QuestionCardModel.usesList(ask("Colour?", ["Red", "Blue"], descriptions: [nil, "the sky"])))
    }

    @Test func theFooterShowsForMultiSelectOrAnOpenField() {
        var single = card([ask("Colour?", ["Red", "Blue"])])
        #expect(!single.showsFooter)
        single.openOther()
        #expect(single.showsFooter)
        #expect(card([ask("Which?", ["A", "B"], multi: true)]).showsFooter)
    }

    @Test func theFooterSaysNextUntilTheLastQuestion() {
        var model = card([ask("Which?", ["A", "B"], multi: true), ask("More?", ["C", "D"], multi: true)])
        #expect(model.footerTitle == "Next")
        _ = model.pick("A", now: armed)
        _ = model.next(now: armed)
        #expect(model.footerTitle == "Send")
    }

    @Test func aTallerQuestionNeedsATallerCard() {
        let short = card([ask("Colour?", ["Red", "Blue"])])
        let long = card([ask(String(repeating: "Which colour would you like? ", count: 20), ["Red", "Blue"])])
        let list = card([ask("Colour?", ["Red", "Blue"], descriptions: ["warm", "cool"])])
        #expect(long.naturalHeight > short.naturalHeight)
        #expect(list.naturalHeight > short.naturalHeight)
        var typing = short
        typing.openOther()
        #expect(typing.naturalHeight > short.naturalHeight)
    }
}
