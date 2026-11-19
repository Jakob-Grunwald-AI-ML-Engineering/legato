import Foundation
import Testing
@testable import LegatoKeyboardCore

private func unit(_ id: Int, _ text: String, ready: Bool = true) -> LiveSegment {
    .init(id: id, text: text, cleaned: ready, final: true, ready: ready)
}
private func snapshot(_ version: Int, _ segments: [LiveSegment], head: String = "", complete: Bool = false, run: String = "take") -> LiveDictationSnapshot {
    .init(runID: run, version: version, segments: segments + (head.isEmpty ? [] : [.init(id: 99, text: head, final: false)]), complete: complete, staged: true)
}

/// What the queue types for a unit: `FieldInsertion` on the model's text, else the take's context (`StagedDictation.context`).
private func prepared(_ take: StagedDictation, _ text: String, proxyBefore: String, after: Character?, capitalization: AutoCapitalizationType) -> String {
    let typed = FieldInsertion.prepare(text, contextBefore: take.context(proxyBefore: proxyBefore), capitalization: capitalization)
    return typed.isEmpty ? "" : typed + FieldInsertion.trailingSeparator(after: typed, before: after)
}

@Suite struct StagedDictationTests {
    @Test func aSnapshotSplitsIntoThePreviewAndTheUnitsReadyToType() {
        var take = StagedDictation()
        take.receive(snapshot(3, [unit(0, "Hello there.", ready: false), unit(1, "Second one.", ready: false)], head: "and more"))
        #expect(take.preview == "Hello there. Second one. and more", "Raw words show until cleanup lands")
        #expect(take.nextReady == nil)
        take.receive(snapshot(4, [unit(0, "Hello there!"), unit(1, "Second one.", ready: false)], head: "and more"))
        #expect(take.preview == "Hello there! Second one. and more", "Cleaned text replaces raw in place")
        #expect(take.nextReady?.text == "Hello there!")
    }

    /// #313: the magic shimmer means "thinking": a closed unit waiting for cleanup, never the open unit still collecting words.
    @Test func onlyAClosedUnitAwaitingCleanupIsWaiting() {
        var take = StagedDictation()
        let open = LiveSegment(id: 1, text: "Open words", final: true, ready: false, closed: false)
        let closed = LiveSegment(id: 0, text: "Sent.", final: true, ready: false, closed: true)
        take.receive(snapshot(1, [closed, open], head: "head"))
        #expect(take.previewLayout.waiting == [0..<5], "only the closed unit")
        var run = LiveDictationRun(staged: true, manual: true)
        _ = run.addFinal(key: 0, text: "Hello there my friend how are you.")
        #expect(run.snapshot.segments.first?.closed == false, "manual: the open unit stays open past a sentence end")
        _ = run.flush()
        #expect(run.snapshot.segments.first?.closed == true)
    }

    /// #313: how much of the unit's own text is in the field drives the row's exit; the separator is not the unit's.
    @Test func exitProgressCountsTheUnitsOwnGraphemesAndNotItsSeparator() {
        var take = StagedDictation()
        take.receive(snapshot(1, [unit(0, "One two."), unit(1, "Next.", ready: false)], head: "more"))
        #expect(take.previewLayout.leaving == 0..<0 && take.previewLayout.waiting == [9..<14])
        take.begin(0, typed: " One two.")
        take.sent(" ")
        #expect(take.exited == 0 && take.started)
        take.sent("O"); take.sent("n")
        var layout = take.previewLayout
        #expect(layout.text == "One two. Next. more" && layout.leaving == 0..<8 && layout.exited == 2 && layout.waiting == [9..<14])
        take.sent("e two.") // a flushed rest, then the trailing separator past the unit's end
        take.sent(" ")
        layout = take.previewLayout
        #expect(layout.exited == 8 && take.preview == layout.text)
        #expect(layout.dropping(4).leaving == 0..<4 && layout.dropping(4).exited == 4 && layout.dropping(4).text == "two. Next. more")
        take.delivered(0)
        #expect(take.exited == 0 && !take.started && take.previewLayout.leaving == 0..<0 && take.preview == "Next. more")
    }

    @Test func aLongBurstNeverStallsAndTheUnverifiedBoundCountsOnlyBeforeTheUnitStarts() {
        var take = StagedDictation()
        take.receive(snapshot(1, [unit(0, "A long unit.")], complete: true))
        take.begin(0, typed: "A long unit.")
        #expect(take.isStalled(inFlightMs: 2_000, unverifiedInput: true), "Not started: the unverified bound holds")
        take.sent("A")
        // The caller counts from the latest piece: a burst of any length keeps resetting it, and once started the short bound is gone.
        #expect(!take.isStalled(inFlightMs: 35, unverifiedInput: false) && !take.isStalled(inFlightMs: 9_999, unverifiedInput: true))
        #expect(take.isStalled(inFlightMs: StagedDictation.stallMs, unverifiedInput: false))
    }

    @Test func unitsAreTypedInOrderAndLeaveThePreviewOnceInTheField() throws {
        var take = StagedDictation()
        // Unit 1 is ready before unit 0: it waits behind it.
        take.receive(snapshot(1, [unit(0, "One.", ready: false), unit(1, "Two.")]))
        #expect(take.nextReady == nil)
        take.receive(snapshot(2, [unit(0, "One."), unit(1, "Two.")], head: "three"))
        let first = try #require(take.nextReady)
        #expect(first.id == 0)
        take.begin(0, typed: "One.")
        #expect(take.nextReady == nil, "One unit at a time")
        #expect(take.preview == "One. Two. three", "Typed only once the queue confirmed it")
        take.delivered(0)
        #expect(take.preview == "Two. three")
        #expect(take.deliveredThrough == 0)
        #expect(take.nextReady?.id == 1)
        take.begin(1, typed: " Two.")
        take.delivered(1)
        #expect(take.deliveredThrough == 1 && take.nextReady == nil && take.preview == "three")
        #expect(take.record == "One. Two.")
        take.receive(snapshot(3, [unit(0, "One."), unit(1, "Two."), unit(2, "Three.")], complete: true))
        #expect(!take.isFinished)
        take.begin(2, typed: " Three.")
        take.delivered(2)
        #expect(take.isFinished)
    }

    @Test func aUnitCleanupDroppedHasNothingToType() {
        var take = StagedDictation()
        take.receive(snapshot(1, [unit(0, ""), unit(1, "Real text.")], complete: true))
        #expect(take.deliveredThrough == 0 && take.nextReady?.id == 1)
    }

    @Test func aFieldChangeHoldsDeliveryAndTheRestStaysInThePreviewUntilResumed() {
        var take = StagedDictation()
        take.receive(snapshot(1, [unit(0, "One."), unit(1, "Two.", ready: false), unit(2, "Three.", ready: false)], head: "four"))
        take.begin(0, typed: "One.")
        take.delivered(0)
        take.begin(1, typed: " Two.")
        // The insert of unit 1 did not stand: it may not have landed, so it stays pending with the rest (raw where no cleanup came).
        take.hold()
        #expect(take.held && take.nextReady == nil && take.inFlight == nil)
        #expect(take.preview == "Two. Three. four", "Back in the preview as pending, nothing typed")
        // A unit that becomes ready after the hold joins them; an older snapshot changes nothing.
        take.receive(snapshot(2, [unit(0, "One."), unit(1, "Two."), unit(2, "Three."), unit(3, "Four.")], complete: true))
        take.receive(snapshot(1, [unit(0, "One.")]))
        #expect(take.preview == "Two. Three. Four." && take.nextReady == nil)
        // Sent again by the person: delivery resumes with the first unit not in the field.
        take.resume()
        #expect(!take.held && take.nextReady?.id == 1)
    }

    @Test func aStagedUnitIsTypedAsSpeechWhileInputIsUnverified() {
        // The phone: a refocus leaves the queue's input unverified (a text callback with an unchanged report). The unit is
        // dictated words, so it goes in at the caret as speech does: one burst, one check, one undo step.
        var rig = QueueRig(FakeField("If the weather holds."), config: .init())
        rig.tick()
        rig.queue.observe(FieldQueue.Report(before: "If the weather holds."), callback: .text)
        #expect(rig.queue.hasUnverifiedInput)
        let edit = FieldQueue.Edit(kind: .typist, target: " The plan.", atCursor: true, requiresVerifiedInsertion: true, isSpeech: true)
        rig.queue.enqueue(edit, user: false)
        while rig.field.string != "If the weather holds. The plan.", rig.clockMs < 5_000 { rig.tick() }
        #expect(rig.field.string == "If the weather holds. The plan.")
        for _ in 0..<30 { rig.tick() }
        let applied = rig.events.contains { if case .applied(let id, _, _) = $0.event { id == edit.id } else { false } }
        #expect(applied, "Confirmed, so the take records it as delivered")
    }

    @Test func aUnitTheQueueHoldsOnUnverifiedInputIsHeldAfterABoundAndTheNextTakeIsNotBlocked() {
        // A unit that is not speech (or any unit the queue cannot place) stays queued under unverified input: the bound keeps it.
        var queue = FieldQueue()
        let report = FieldQueue.Report(before: "If the weather holds.")
        _ = queue.step(report: report, elapsedMs: 200)
        queue.observe(report, callback: .text)
        #expect(queue.hasUnverifiedInput)
        var take = StagedDictation()
        take.receive(snapshot(1, [unit(0, "The plan."), unit(1, "Then coffee.")], complete: true))
        take.begin(0, typed: " The plan.")
        let edit = FieldQueue.Edit(kind: .typist, target: " The plan.", atCursor: true, requiresVerifiedInsertion: true)
        queue.enqueue(edit, user: false)
        for _ in 0..<40 { #expect(queue.step(report: report, elapsedMs: 100) == .idle) }
        #expect(take.inFlight == 0 && take.hasUndelivered, "Held, not typed")
        #expect(!take.isStalled(inFlightMs: 1_900, unverifiedInput: true))
        #expect(take.isStalled(inFlightMs: 2_000, unverifiedInput: true))
        #expect(!take.isStalled(inFlightMs: 9_000, unverifiedInput: false) && take.isStalled(inFlightMs: 10_000, unverifiedInput: false))
        queue.cancelEdit(edit.id)
        let dropped = queue.drainEvents().contains { if case .dropped(let drop) = $0 { drop.id == edit.id } else { false } }
        #expect(dropped)
        take.hold()
        #expect(take.hasUndelivered && take.preview == "The plan. Then coffee." && take.nextReady == nil && !take.isStalled(inFlightMs: 60_000, unverifiedInput: true))
        take.receive(snapshot(1, [unit(0, "Fresh start.")], complete: true, run: "next"))
        #expect(!take.held && take.nextReady?.text == "Fresh start.")
    }

    @Test func aUnitInsertedAtTheCaretTakesTheSeparatorOfTheFieldThere() {
        // The field says "...simple." with the caret right after it: the space comes from the shared rule.
        #expect(FieldInsertion.prepare("I think so.", contextBefore: "It is simple.", capitalization: .none) == " I think so.")
        #expect(FieldInsertion.prepare("I think so.", contextBefore: "It is simple. ", capitalization: .none) == "I think so.")
    }

    @Test func aNewRunStartsTheTakeOver() {
        var take = StagedDictation()
        take.receive(snapshot(1, [unit(0, "Old.")]))
        take.begin(0, typed: "Old."); take.delivered(0)
        take.receive(snapshot(1, [unit(0, "New.")], run: "next"))
        #expect(take.runID == "next" && take.record.isEmpty && take.nextReady?.text == "New.")
    }

    @Test func theSeparatorFollowsTheProxyWhileItShowsTheTakeAndTheTakesRecordWhenItDoesNot() {
        var take = StagedDictation()
        // Nothing typed yet: the proxy's context decides.
        #expect(prepared(take, "hello", proxyBefore: "Dear", after: nil, capitalization: .none) == " hello")
        #expect(prepared(take, "hello", proxyBefore: "Dear ", after: nil, capitalization: .none) == "hello")
        take.receive(snapshot(1, [unit(0, "First sentence.")]))
        take.begin(0, typed: "First sentence."); take.delivered(0)
        // The proxy shows what the take typed: its own context stands.
        #expect(prepared(take, "Next.", proxyBefore: "Note: First sentence.", after: nil, capitalization: .none) == " Next.")
        // Stale: the proxy has not caught up (empty, or older text): the record decides, never "no space".
        #expect(prepared(take, "Next.", proxyBefore: "", after: nil, capitalization: .none) == " Next.")
        #expect(prepared(take, "Next.", proxyBefore: "Note:", after: nil, capitalization: .none) == " Next.")
        // Punctuation that closes joins without a space, with either source.
        #expect(prepared(take, ", and more", proxyBefore: "", after: nil, capitalization: .none) == ", and more")
    }

    @Test func withNeitherSourceKnownNoSeparatorIsGuessed() {
        let take = StagedDictation()
        #expect(prepared(take, "hello", proxyBefore: "", after: nil, capitalization: .none) == "hello")
    }

    @Test func aWordAfterTheCaretGetsASpaceBetween() {
        let take = StagedDictation()
        #expect(prepared(take, "hello", proxyBefore: "Dear ", after: "J", capitalization: .none) == "hello ")
        #expect(prepared(take, "hello", proxyBefore: "Dear ", after: ".", capitalization: .none) == "hello")
    }

    @Test func theStagedFlagAndUnitReadinessCrossTheLink() throws {
        let value = snapshot(5, [unit(0, "One."), unit(1, "Two.", ready: false)], head: "x")
        let restored = try JSONDecoder().decode(LiveDictationSnapshot.self, from: JSONEncoder().encode(value))
        #expect(restored.staged == true && restored.segments.map(\.ready) == [true, false, nil])
        let old = Data(#"{"runID":"old","version":1,"segments":[],"complete":false}"#.utf8)
        #expect(try JSONDecoder().decode(LiveDictationSnapshot.self, from: old).staged == nil)
    }
}

@Suite struct StagedRunTests {
    @Test func aStagedRunPublishesEachUnitWhenItsCleanupLandsNotAtTheEnd() {
        var run = LiveDictationRun(runID: "r", staged: true)
        let first = run.addFinal(key: 0, text: "um we should ship it on friday.")
        #expect(first != nil)
        run.setHead("and then")
        #expect(run.snapshot.segments.map(\.ready) == [false, nil])
        let shown = run.setCleaned(key: 0, text: "We should ship it on Friday.")
        #expect(shown, "Published at once, the take still going")
        let segments = run.snapshot.segments
        #expect(segments.first == .init(id: 0, text: "We should ship it on Friday.", cleaned: true, final: true, ready: true, closed: true))
        #expect(run.snapshot.staged == true && !run.snapshot.complete)
    }

    @Test func aPauseOrTheStopClosesTheOpenUnitWhateverItsLength() {
        var run = LiveDictationRun(runID: "r", staged: true)
        let closed = run.addFinal(key: 0, text: "Um.")
        #expect(closed == nil, "Short: it waits for more")
        let open = run.flush()
        #expect(open?.text == "Um.")
        let again = run.flush()
        #expect(again == nil)
        // The next words open a unit of their own.
        run.addFinal(key: 1, text: "Second part")
        #expect(run.snapshot.segments.map(\.id) == [0, 1])
        run.finish()
        #expect(run.snapshot.segments.allSatisfy { $0.ready == true } && run.snapshot.complete, "The end makes every unit ready")
    }

    @Test func aFailedCleanupLeavesTheRawWordsAsTheUnitsFinalText() {
        var run = LiveDictationRun(runID: "r", staged: true)
        run.addFinal(key: 0, text: "this is raw but long enough to close.")
        let changed = run.setRaw(key: 0)
        #expect(changed)
        let segment = run.snapshot.segments[0]
        #expect(segment.ready == true && segment.cleaned == false && segment.text == "this is raw but long enough to close.")
        let twice = run.setRaw(key: 0)
        #expect(!twice)
    }

    @Test func aCleanupResultThatArrivesAfterTheRawWordsStoodChangesNothing() {
        var run = LiveDictationRun(runID: "r", staged: true, manual: true)
        run.addFinal(key: 0, text: "send this raw please")
        let open = run.flush()
        #expect(open != nil && run.setRaw(key: open!.key))
        let version = run.version
        let late = run.setCleaned(key: 0, text: "Send this, raw please.")
        #expect(!late)
        #expect(run.version == version && run.snapshot.segments[0].text == "send this raw please")
    }
}

/// A take the keyboard did not see begin (it appeared, or its view was recreated, while the app kept the take going).
@Suite struct StagedAppearanceTests {
    @Test func aRunStillSpokenAfterTheAppearanceContinuesAndAnEndedOneDoesNot() {
        let seen = snapshot(4, [unit(0, "Hello.", ready: false)], head: "and")
        #expect(snapshot(5, [unit(0, "Hello.", ready: false)], head: "and more").continues(seen), "a later version, still spoken")
        #expect(!seen.continues(seen), "the version seen at the appearance itself")
        #expect(!snapshot(5, [unit(0, "Hello.")], head: "", run: "other").continues(seen), "another run")
        var stopped = snapshot(5, [unit(0, "Hello.")]); stopped.stopped = true
        var paused = snapshot(5, [unit(0, "Hello.")]); paused.paused = true
        #expect(!stopped.continues(seen) && !paused.continues(seen) && !snapshot(6, [unit(0, "Hello.")], complete: true).continues(seen),
                "hiding ended a stopped, paused or complete run: it stays in History")
        #expect(paused.isCapturing == false && snapshot(1, []).isCapturing)
    }

    @Test func adoptingARunSkipsTheUnitsAnEarlierAppearanceTypedAndKeepsAHeldRunHeld() {
        var take = StagedDictation()
        take.receive(snapshot(7, [unit(0, "One."), unit(1, "Two."), unit(2, "Three.", ready: false)], head: "four"))
        take.adopt(.init(runID: "take", version: 6, stats: .init(), delivered: true, deliveredThrough: 0))
        #expect(take.deliveredThrough == 0 && take.nextReady?.text == "Two." && take.preview == "Two. Three. four")

        var held = StagedDictation()
        held.receive(snapshot(7, [unit(0, "One."), unit(1, "Two.")]))
        held.adopt(.init(runID: "take", version: 6, stats: .init(), delivered: false, deliveredThrough: 0, ended: true))
        #expect(held.held && held.nextReady == nil && held.preview == "Two.", "pending for the person's tap, never retyped on its own")

        var fresh = StagedDictation()
        fresh.receive(snapshot(2, [unit(0, "One.")]))
        fresh.adopt(.init(runID: "other", version: 9, stats: .init(), delivered: false, deliveredThrough: 3, ended: true))
        #expect(!fresh.held && fresh.deliveredThrough == nil, "another run's receipt changes nothing")
    }

    @Test func theLinkKeepsTheLastNotesInOrder() {
        let link = LiveDictationLink(store: LinkStore(MemoryLinkStore()))
        for i in 0..<(LiveDictationLink.noteLimit + 3) { link.note(.init(runID: "r", event: "e\(i)", version: i)) }
        let notes = link.notes()
        #expect(notes.count == LiveDictationLink.noteLimit && notes.first?.event == "e3" && notes.last?.version == LiveDictationLink.noteLimit + 2)
    }
}
