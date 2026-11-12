import Testing
@testable import LegatoKeyboardCore

/// The typed-line modes go through the field queue as runs, one line at a time (UAT bug 2: the typist used to drop the
/// rest of its line at the user's key; as a run, the rest finishes in the line's own text).
@Suite struct DictationLineRunsTests {
    private func line(_ seq: Int, _ text: String, final: Bool = true, retracted: Bool = false) -> DictationLine {
        DictationLine(lineID: "\(seq)", seq: seq, raw: text, text: text, status: .cleaned, final: final, retracted: retracted)
    }

    @Test func linesBecomeRunsOneAtATimeAndAreAcknowledgedWhenTheirFinalVersionLanded() {
        var runs = DictationLineRuns()
        let first = runs.accept(DictationPublication(sessionID: "s", lines: [line(1, "second line."), line(0, "first line.")]), acknowledged: nil)
        #expect(first?.runID == DictationLineRuns.runID(session: "s", seq: 0))
        #expect(first?.complete == true && first?.segments.first?.text == "first line.")
        let done = runs.applied(runID: first!.runID, version: first!.version)
        #expect(done.ack == 0)
        #expect(done.next?.runID == DictationLineRuns.runID(session: "s", seq: 1))
        let last = runs.applied(runID: done.next!.runID, version: done.next!.version)
        #expect(last.ack == 1 && last.next == nil && !runs.isBusy)
    }

    @Test func aStreamingLineGrowsAsVersionsOfOneRunAndIsDoneOnlyWhenFinal() {
        var runs = DictationLineRuns()
        let v1 = runs.accept(DictationPublication(sessionID: "s", lines: [line(0, "Water the", final: false)]), acknowledged: nil)!
        #expect(!v1.complete)
        #expect(runs.applied(runID: v1.runID, version: v1.version).ack == nil)
        let v2 = runs.accept(DictationPublication(sessionID: "s", lines: [line(0, "Water the plants.")]), acknowledged: nil)!
        #expect(v2.runID == v1.runID && v2.version == v1.version + 1 && v2.complete)
        #expect(runs.applied(runID: v2.runID, version: v2.version).ack == 0)
    }

    @Test func aRetractedLineWantsNoText() {
        var runs = DictationLineRuns()
        _ = runs.accept(DictationPublication(sessionID: "s", lines: [line(0, "Half a", final: false)]), acknowledged: nil)
        let erase = runs.accept(DictationPublication(sessionID: "s", lines: [line(0, "Half a", final: false, retracted: true)]), acknowledged: nil)!
        #expect(erase.complete && erase.segments.first?.text == "")
    }

    @Test func aLineThatTypedNothingStartsOverWhenItsFieldWentAwayOneThatTypedDrops() {
        var runs = DictationLineRuns()
        let a = runs.accept(DictationPublication(sessionID: "s", lines: [line(0, "one."), line(1, "two.")]), acknowledged: nil)!
        let again = runs.dropped(runID: a.runID, reset: true)
        #expect(again.ack == nil && again.next?.runID == a.runID && again.next!.version > a.version)
        runs.started(runID: a.runID)
        let gone = runs.dropped(runID: a.runID, reset: true)
        #expect(gone.ack == 0 && gone.next?.runID == DictationLineRuns.runID(session: "s", seq: 1))
    }

    @Test func acknowledgedLinesAreNeverTypedAgain() {
        var runs = DictationLineRuns()
        let next = runs.accept(DictationPublication(sessionID: "s", lines: [line(0, "one."), line(1, "two.")]),
                               acknowledged: DictationAck(sessionID: "s", upTo: 0))
        #expect(next?.runID == DictationLineRuns.runID(session: "s", seq: 1))
    }
}
