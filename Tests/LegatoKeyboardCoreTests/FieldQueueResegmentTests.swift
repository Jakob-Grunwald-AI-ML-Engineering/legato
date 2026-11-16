import Testing
@testable import LegatoKeyboardCore

/// The app re-splits a take's segments while the user speaks (a provisional segment becomes a short final one and a
/// new segment holding words already shown). Delivery is decided on the take's whole text: a re-split never types
/// delivered words again, and the stop lands the cleaned take.
@Suite struct FieldQueueResegmentTests {
    private func seg(_ id: Int, _ text: String, final: Bool = false, cleaned: Bool = false) -> LiveSegment {
        .init(id: id, text: text, cleaned: cleaned, final: final)
    }
    private func take(_ version: Int, _ segments: [LiveSegment], complete: Bool = false) -> LiveDictationSnapshot {
        .init(runID: "r", version: version, segments: segments, complete: complete)
    }
    private func count(_ word: String, in text: String) -> Int {
        text.lowercased().split { !($0.isLetter || $0.isNumber) }.filter { $0 == word }.count
    }

    /// A revision that still waits (an earlier word changed) is published again, its end the same: the punctuation after
    /// the last delivered word is delivered once (UAT stress: "some..", "larder.....").
    @Test func aRepeatedRevisionDeliversItsEndOnce() {
        var speech = FieldQueue.SpeechDelivery()
        speech.update(Array("hollow basket teapot more three"))
        for _ in 0..<3 { speech.update(Array("hollow basket biscuit more three some.")) }
        #expect(String(speech.delivered) == "hollow basket teapot more three some.")
    }

    private var provisional: [[LiveSegment]] {
        [
            [seg(0, "Fine,")],
            [seg(0, "Fine, the boat left")],
            [seg(0, "Fine, the boat left the harbour, uh,")],
            [seg(0, "Fine, the boat left the harbour, uh, early,")],
            // Re-split: the provisional segment shrinks, a new segment carries words already delivered.
            [seg(0, "Fine.", final: true), seg(1, "The boat left the harbour early")],
            [seg(0, "Fine.", final: true), seg(1, "The boat left the harbour", final: true), seg(2, "early", final: true),
             seg(3, "and.", final: true)],
            [seg(0, "Fine.", final: true), seg(1, "The boat left the harbour", final: true), seg(2, "early", final: true),
             seg(3, "and.", final: true), seg(4, "We sailed")],
            [seg(0, "Fine.", final: true), seg(1, "The boat left the harbour", final: true), seg(2, "early", final: true),
             seg(3, "and.", final: true), seg(4, "We sailed north", final: true)],
        ]
    }
    private var cleaned: [LiveSegment] {
        [seg(0, "Fine. The boat left the harbour early and", final: true, cleaned: true), seg(1, "", final: true, cleaned: true),
         seg(2, "", final: true, cleaned: true), seg(3, "", final: true, cleaned: true),
         seg(4, "we sailed north.", final: true, cleaned: true)]
    }

    @Test(arguments: [false, true])
    func aResplitNeverTypesDeliveredWordsTwice(animated: Bool) {
        var rig = QueueRig(FakeField(""), config: .init(prioritizeSpeech: true))
        for (i, segments) in provisional.enumerated() {
            rig.queue.enqueue(take(i + 1, segments))
            do { let drained = rig.drain(); #expect(drained) }
            for word in ["fine", "boat", "harbour", "early", "and", "sailed"] {
                #expect(count(word, in: rig.field.string) <= 1, "\(word) twice in \(rig.field.string.debugDescription)")
            }
        }
        // New speech after the re-split still arrives while speaking.
        #expect(rig.field.string.hasSuffix("We sailed north"))
        rig.queue.takeStopped("r")
        do { let drained = rig.drain(); #expect(drained) }
        rig.queue.enqueue(take(provisional.count + 1, cleaned, complete: true))
        do { let drained = rig.drain(); #expect(drained) }
        #expect(rig.field.string == "Fine. The boat left the harbour early and we sailed north.")
        #expect(rig.drops.isEmpty)
    }

    @Test func aRevisedFrontierEndingStillPinsNewSpeechByItsWords() {
        var target = FieldSpeechScheduling.Target()
        _ = target.update(Array("Fine, the boat left the harbour, uh, early,"), speaking: true)
        // Only punctuation and a filler changed: nothing is new, nothing is typed again.
        #expect(String(target.update(Array("Fine. The boat left the harbour early"), speaking: true))
            == "Fine, the boat left the harbour, uh, early,")
        #expect(String(target.update(Array("Fine. The boat left the harbour early and we sailed"), speaking: true))
            == "Fine, the boat left the harbour, uh, early, and we sailed")
        // A last word the revision changed stays deferred, never guessed.
        var changed = FieldSpeechScheduling.Target()
        _ = changed.update(Array("we left the harbour at dawn"), speaking: true)
        #expect(String(changed.update(Array("We left the harbor at noon and"), speaking: true)) == "we left the harbour at dawn")
    }
}

/// At stop, a take whose field text is not what the queue typed (the field changed it, or the user typed into it
/// while it was out of sight) is never repaired: the field keeps it, and the final text is reported for History.
@Suite struct StoppedTakeKeptTests {
    private struct Host {
        var queue = FieldQueue(config: .init(canReadAround: true, prioritizeSpeech: true))
        var text = "" { didSet { caret = min(caret, text.utf16.count) } }
        var caret = 0
        var requests = 0
        var events: [FieldQueue.Event] = []
        var drops: [FieldQueue.Drop] { events.compactMap { if case .dropped(let d) = $0 { d } else { nil } } }

        mutating func run(steps: Int = 400) {
            for _ in 0..<steps {
                if let request = queue.recoveryRequest {
                    requests += 1
                    queue.completeRecovery(request, report: nil, restored: false)
                }
                let before = String(decoding: Array(text.utf16.prefix(caret)), as: UTF16.self)
                let after = String(decoding: Array(text.utf16.dropFirst(caret)), as: UTF16.self)
                if case .send(let op) = queue.step(report: .init(before: before, after: after), elapsedMs: 33) {
                    let result = ShadowEditPlanner.simulate(ops: [op], shadow: text, cursor: caret)
                    text = result.text; caret = result.cursor
                }
                events += queue.drainEvents()
            }
        }
    }

    private func typed(_ words: String) -> Host {
        var host = Host()
        host.queue.enqueue(snap(1, words))
        host.run()
        return host
    }

    private static let final = LiveDictationSnapshot(runID: "r", version: 2, segments: [
        .init(id: 0, text: "The boat left the harbour early.", cleaned: true, final: true),
    ], complete: true)

    @Test(arguments: [true, false])
    func staleTypingTheQueueDidNotMakeIsKept(noticedAfterStop: Bool) {
        var host = typed("the boat left the harbour early")
        #expect(host.text == "the boat left the harbour early")
        // The field holds words the queue no longer believes are there.
        host.text = "the boat left left the harbour ear early"
        host.caret = host.text.utf16.count
        if !noticedAfterStop { host.run(steps: 40) }
        host.queue.takeStopped("r")
        host.queue.enqueue(Self.final)
        host.run()
        #expect(host.requests == 0, "dictation never looks around")
        #expect(host.text == "the boat left left the harbour ear early")
        #expect(host.drops.contains { $0.runID == "r" && $0.text == "The boat left the harbour early." })
    }

    @Test func userTerminalPunctuationWinsWhileUntouchedTextIsCorrected() {
        var host = typed("the boat left the harbour early")
        host.queue.enqueue(.insert("!"))
        host.run(steps: 40)
        host.queue.takeStopped("r")
        host.queue.enqueue(Self.final)
        host.run()
        #expect(host.text == "The boat left the harbour early!")
        #expect(host.drops.contains { $0.runID == "r" && $0.reason == .userEdited })
    }

    @Test func anUntouchedTakeChangesOnlyTheDifferingCharacters() {
        var host = typed("the boat left the harbour early")
        let from = host.events.count
        host.queue.enqueue(Self.final)
        host.run()
        #expect(host.text == "The boat left the harbour early.")
        let ops = host.events[from...].compactMap { if case .sent(let op, _) = $0 { op } else { nil } }
        #expect(ops.filter { if case .deleteBackward = $0 { true } else { false } } == [.deleteBackward(1)])
        #expect(ops.compactMap { if case .insert(let text) = $0 { text } else { nil } }.sorted() == [".", "T"])
        #expect(host.drops.isEmpty)
    }
}
