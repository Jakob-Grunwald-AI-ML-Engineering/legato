import Testing
@testable import LegatoKeyboardCore

/// Every take starts at the user's caret: text typed by hand between takes (Enter, "- ", words) leaves the next take
/// starting right there, and nothing of an earlier take pulls new words elsewhere.
@Suite struct FieldQueueTakeStartTests {
    private func cleaned(_ text: String, run: String, version: Int) -> LiveDictationSnapshot {
        LiveDictationSnapshot(runID: run, version: version, segments: [.init(id: 0, text: text, cleaned: true, final: true)], complete: true)
    }

    private func type(_ keys: String, _ rig: inout QueueRig) {
        for key in keys { rig.queue.enqueue(.insert(String(key))); rig.run(ms: 66) }
    }

    /// Dictates `item` word by word as run `run`, then ends the take.
    private func dictate(_ item: String, run: String, _ rig: inout QueueRig) {
        var text = ""
        for (i, word) in item.split(separator: " ").enumerated() {
            text += (text.isEmpty ? "" : " ") + word
            rig.queue.enqueue(snap(i + 1, text, run: run))
            rig.run(ms: 330)
        }
        rig.queue.enqueue(snap(20, text, run: run, complete: true))
    }

    private static let items = ["buy milk", "call anna about the boat", "book the berth", "check the forecast"]
    private static let list = "- Buy milk.\n- Call anna about the boat.\n- Book the berth.\n- Check the forecast."

    /// A Markdown list, take by take: "- ", dictate, cleanup, Enter, "- ", dictate, ... (pinned).
    @Test(arguments: [(false, false), (true, false), (false, true), (true, true)])
    func aMarkdownListTypedTakeByTakeStartsEachTakeAtTheCaret(safari: Bool, blocks: Bool) {
        var field = FakeField("")
        field.hostDelays = safari
        field.blockEcho = blocks
        var rig = QueueRig(field, config: .init(animated: true))
        for (i, item) in Self.items.enumerated() {
            type(i == 0 ? "- " : "\n- ", &rig)
            rig.drain()
            dictate(item, run: "take\(i)", &rig)
            rig.drain()
            rig.queue.enqueue(cleaned(item.prefix(1).uppercased() + item.dropFirst() + ".", run: "take\(i)", version: 21))
            rig.drain()
        }
        #expect(rig.field.string == Self.list)
        #expect(rig.drops.isEmpty)
        #expect(rig.field.reorders == 0 && rig.field.staleTriggers == 0)
    }

    /// The same list with each cleanup arriving late: after the user typed the next line's Enter and "- ", or while
    /// the next take is already typing. The cleanup lands in its own take's line; the next take starts at the caret.
    @Test(arguments: [false, true])
    func aLateCleanupLandsInItsOwnLineWhileTheNextTakeStartsAtTheCaret(safari: Bool) {
        var field = FakeField("")
        field.hostDelays = safari
        var rig = QueueRig(field, config: .init(animated: true))
        for (i, item) in Self.items.enumerated() {
            type(i == 0 ? "- " : "\n- ", &rig)
            if i > 0 {
                let previous = Self.items[i - 1]
                let late = cleaned(previous.prefix(1).uppercased() + previous.dropFirst() + ".", run: "take\(i - 1)", version: 21)
                // Every other cleanup comes once the next take started typing.
                if i.isMultiple(of: 2) { rig.queue.enqueue(late) } else { rig.drain() }
                dictate(item, run: "take\(i)", &rig)
                if !i.isMultiple(of: 2) { rig.queue.enqueue(late) }
            } else {
                rig.drain()
                dictate(item, run: "take\(i)", &rig)
            }
            rig.drain()
        }
        let last = Self.items.last!
        rig.queue.enqueue(cleaned(last.prefix(1).uppercased() + last.dropFirst() + ".", run: "take\(Self.items.count - 1)", version: 21))
        rig.drain()
        #expect(rig.field.string == Self.list)
        #expect(rig.drops.isEmpty)
    }

    /// The user fixes the end of the take while it is still going: dictation goes on at their caret.
    @Test(arguments: [false, true])
    func dictationGoesOnAtTheCaretAfterTheUserEditsTheTakesText(safari: Bool) {
        var field = FakeField("Note: ")
        field.hostDelays = safari
        var rig = QueueRig(field, config: .init(animated: true))
        rig.queue.enqueue(snap(1, "buy milk and eggs"))
        rig.drain()
        for _ in 0..<5 { rig.queue.enqueue(.deleteBackward) }
        rig.drain()
        #expect(rig.field.string == "Note: buy milk and")
        type(" ", &rig)
        rig.queue.enqueue(snap(2, "buy milk and eggs bread"))
        rig.drain()
        #expect(rig.field.string == "Note: buy milk and bread")
        // The cleanup keeps the user's deletion and lands the rest.
        rig.queue.enqueue(cleaned("Buy milk and eggs bread.", run: "r", version: 3))
        rig.drain()
        #expect(rig.field.string == "Note: Buy milk and bread.")
    }

    /// Segments of one run as the app publishes them: `cleanedAs` puts the run's cleanup in the first segment (one
    /// unit over all of them, the others empty with their raw words).
    static func segments(_ items: [String], final: Bool = true, cleanedAs: String? = nil) -> [LiveSegment] {
        items.enumerated().map { i, item in
            guard let cleanedAs else { return LiveSegment(id: i, text: item, final: final || i < items.count - 1) }
            return LiveSegment(id: i, text: i == 0 ? cleanedAs : "", cleaned: true, final: true, unit: 0, raw: item)
        }
    }

    /// UAT F1: the take was stopped (complete) and its run goes on with new speech (the bridge reuses the run). The user
    /// pressed Enter and typed "- " meanwhile: the new words start at their caret, and the cleanup that joins both into
    /// one sentence lands in each piece's own words, the joiner nowhere.
    @Test(arguments: [false, true])
    func newSpeechAfterAStopStartsAtTheCaretNotAtTheTakesEnd(safari: Bool) {
        var field = FakeField("")
        field.hostDelays = safari
        var rig = QueueRig(field, config: .init(animated: true))
        type("- ", &rig)
        rig.drain()
        dictate("the meeting is at three", run: "m", &rig)
        rig.drain()
        rig.queue.enqueue(LiveDictationSnapshot(runID: "m", version: 21, segments: [
            .init(id: 0, text: "the meeting is at three", cleaned: true, final: true),
        ], complete: true))
        type("\n- ", &rig)
        rig.queue.enqueue(LiveDictationSnapshot(runID: "m", version: 22, segments: [
            .init(id: 0, text: "the meeting is at three", cleaned: true, final: true),
            .init(id: 1, text: "bring the laptop", final: true),
        ], complete: true))
        rig.drain()
        #expect(rig.field.string == "- the meeting is at three\n- bring the laptop")
        rig.queue.enqueue(LiveDictationSnapshot(runID: "m", version: 23, segments: Self.segments(
            ["the meeting is at three", "bring the laptop"], cleanedAs: "The meeting is at three, bring the laptop."), complete: true))
        rig.drain()
        #expect(rig.field.string == "- The meeting is at three\n- bring the laptop.")
        #expect(rig.drops.isEmpty)
    }

    /// F1, with the raw version of the new speech coalesced away: the cleanup is the first the keyboard sees of it. The
    /// unit that joins known words with unseen ones shows its raw words, so the new ones still start at the caret.
    @Test func aCleanupJoiningUnseenSpeechStillStartsTheNewWordsAtTheCaret() {
        var rig = QueueRig(FakeField(""), config: .init(animated: true))
        type("- ", &rig)
        dictate("the meeting is at three", run: "m", &rig)
        rig.drain()
        type("\n- ", &rig)
        rig.drain()
        rig.queue.enqueue(LiveDictationSnapshot(runID: "m", version: 23, segments: Self.segments(
            ["the meeting is at three", "bring the laptop"], cleanedAs: "The meeting is at three, bring the laptop."), complete: true))
        rig.drain()
        #expect(rig.field.string == "- the meeting is at three\n- bring the laptop")
    }

    /// UAT F3: three items dictated in one run, the user typing "\n- " between them; the cleanup joins them into one
    /// sentence. Each line takes its own words; no joiner lands at a line's start.
    @Test(arguments: [(", ", false), (", ", true), ("; ", true), (". ", false), (". ", true)])
    func aCleanupThatJoinsTheRunsPiecesLeavesTheJoinersOut(joiner: String, safari: Bool) {
        let items = ["buy some milk", "call the plumber tomorrow", "water the plants"]
        var field = FakeField("")
        field.hostDelays = safari
        var rig = QueueRig(field, config: .init(animated: true))
        for (i, item) in items.enumerated() {
            type(i == 0 ? "- " : "\n- ", &rig)
            rig.queue.enqueue(LiveDictationSnapshot(runID: "list", version: i + 1, segments: Self.segments(Array(items[...i]))))
            rig.drain()
        }
        #expect(rig.field.string == "- buy some milk\n- call the plumber tomorrow\n- water the plants")
        // The app hears where the pieces start, so it can clean each on its own.
        #expect(rig.queue.pieceStarts(of: "list") == [1, 2])
        let capital = joiner == ". "
        let pieces = items.enumerated().map { i, item in i == 0 || capital ? item.prefix(1).uppercased() + item.dropFirst() : item }
        rig.queue.enqueue(LiveDictationSnapshot(runID: "list", version: 9, segments: Self.segments(
            items, cleanedAs: pieces.joined(separator: joiner) + "."), complete: true))
        rig.drain()
        #expect(rig.field.string == "- " + pieces.joined(separator: "\n- ") + ".")
        #expect(rig.drops.isEmpty)
    }

    /// The user taps into the middle of a take's text and types a word there; the take's next words go where the
    /// user is, not back to the take's end.
    @Test(arguments: [false, true])
    func wordsAfterTheUserTypedInsideTheTakeStartAtTheirCaret(safari: Bool) {
        var field = FakeField("")
        field.hostDelays = safari
        var rig = QueueRig(field, config: .init(animated: true))
        rig.queue.enqueue(snap(1, "the boat leaves at noon"))
        rig.drain()
        rig.field.tap(at: 8); rig.outsidePending = true // after "the boat"
        rig.run(ms: 400)
        type(",", &rig)
        rig.drain()
        rig.queue.enqueue(snap(2, "the boat leaves at noon sharp"))
        rig.drain()
        #expect(rig.field.string == "the boat, sharp leaves at noon")
    }
}
