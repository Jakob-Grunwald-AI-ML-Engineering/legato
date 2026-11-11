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
