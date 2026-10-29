import Foundation
import Testing
import LegatoFieldEdit

/// Settle cases from the PR #85 review: a read never confirms a write it does not evidence, a write is never
/// issued against a contradicted prediction, possibly-user text is never claimed by the agent, and a guessed
/// history never maps a late edit.
@Suite struct FieldEditQueueSettleReviewTests {
    let v0 = FieldVersion(0)

    private func applied(_ events: [QueueEvent], _ id: UUID) -> Bool {
        events.contains { if case .applied(id, _) = $0 { true } else { false } }
    }

    // MARK: Intermediate states confirm only what they evidence

    /// "teh cat|": the keystroke "s" is issued, then the cleanup teh→the. The host shows "teh catx": the
    /// keystroke never landed and a foreign "x" was typed. The delete's empty-before state must not explain it.
    @Test func aForeignReadIsNotTheEmptyBeforeStateOfALaterWrite() {
        var queue = FieldEditQueue(FieldSnapshot(before: "teh cat", after: ""))
        let key = EditTransaction(origin: .keystroke, base: v0, steps: [.insert("s", at: 7)])
        queue.submit(key)
        _ = queue.next()
        let fix = EditTransaction(
            origin: .liveCleanup, owner: "run", base: queue.document.version, steps: [replace(0, "teh", with: "the")])
        queue.submit(fix)
        _ = queue.next(for: fix.id)
        let read = FieldSnapshot(before: "teh catx", after: "")
        var events: [QueueEvent] = []
        #expect(queue.settle(read, final: false) != .notYet)
        events += queue.takeEvents()
        queue.settle(read)
        events += queue.takeEvents()
        #expect(!applied(events, key.id))
        #expect(events.contains(.conflict(key.id, Conflict(.verifyFailed))))
        #expect(events.contains(.conflict(fix.id, Conflict(.verifyFailed))))
        #expect(queue.feed.entries.contains { $0.event == .foreign(.insert("x", at: 7), byUser: true, version: queue.document.version) })
        #expect(queue.document.window == "teh catx")
    }

    /// A read nothing explains is not the delete's empty-before state with a moved edge either (the field's
    /// start hides no edge): it is unexplained and holds issuing.
    @Test func theEmptyBeforeStateIsNoEdgeShiftedMatch() {
        var queue = FieldEditQueue(FieldSnapshot(before: "teh cat", after: ""))
        let key = EditTransaction(origin: .keystroke, base: v0, steps: [.insert("s", at: 7)])
        queue.submit(key)
        _ = queue.next()
        let fix = EditTransaction(
            origin: .liveCleanup, owner: "run", base: queue.document.version, steps: [replace(0, "teh", with: "the")])
        queue.submit(fix)
        _ = queue.next(for: fix.id)
        #expect(queue.settle(FieldSnapshot(before: "Xteh catx", after: ""), final: false) == .notYet)
        #expect(queue.takeEvents().isEmpty)
        #expect(queue.needsFinalSettle)
    }

    /// A read matching an edge-shifted intermediate state of the second write waits, confirming nothing: the
    /// moved edge hides part of what the first write would have to show.
    @Test func anEdgeShiftedIntermediateStateConfirmsNothing() {
        var queue = FieldEditQueue(FieldSnapshot(before: "ab teh cat", after: ""))
        let key = EditTransaction(origin: .keystroke, base: v0, steps: [.insert("s", at: 10)])
        queue.submit(key)
        _ = queue.next()
        let fix = EditTransaction(
            origin: .liveCleanup, owner: "run", base: queue.document.version, steps: [replace(3, "teh", with: "the")])
        queue.submit(fix)
        _ = queue.next(for: fix.id)
        let predicted = queue.document
        #expect(queue.settle(FieldSnapshot(before: "b t", after: " cats"), final: false) == .notYet)
        #expect(queue.takeEvents().isEmpty)
        #expect(queue.document == predicted)
        #expect(queue.settle(queue.predicted) == .confirmed)
        #expect(queue.takeEvents().count == 2)
    }

    /// The cleanup teh→the landed and the user typed "s" after it: a non-final read confirms the write and
    /// records the foreign typing, as a final one does.
    @Test func aNonFinalReadWithTypingAfterALandedWriteConfirmsItAndRecordsTheTyping() {
        var queue = FieldEditQueue(FieldSnapshot(before: "teh cat", after: ""))
        let fix = EditTransaction(origin: .liveCleanup, owner: "run", base: v0, steps: [replace(0, "teh", with: "the")])
        queue.submit(fix)
        _ = queue.next()
        let written = queue.document.version
        #expect(queue.settle(FieldSnapshot(before: "the cats", after: ""), final: false) == .confirmed)
        #expect(queue.takeEvents() == [.applied(fix.id, version: written)])
        #expect(queue.feed.entries.last?.event == .foreign(.insert("s", at: 7), byUser: true, version: queue.document.version))
        #expect(queue.document.window == "the cats")
    }

    // MARK: No writes against a contradicted prediction

    /// A non-final read nothing explains holds every lane (also ``FieldEditQueue/next(for:)``) until a settle
    /// resolves it.
    @Test func anUnexplainedNonFinalReadHoldsIssuingUntilTheNextSettle() {
        var queue = FieldEditQueue(FieldSnapshot(before: "teh cat", after: ""))
        let fix = EditTransaction(origin: .liveCleanup, owner: "run", base: v0, steps: [replace(0, "teh", with: "the")])
        queue.submit(fix)
        _ = queue.next()
        #expect(!queue.needsFinalSettle)
        #expect(queue.settle(FieldSnapshot(before: "zz", after: "qq"), final: false) == .notYet)
        #expect(queue.needsFinalSettle)
        let key = EditTransaction(origin: .keystroke, base: queue.document.version, steps: [.insert("s", at: 7)])
        queue.submit(key)
        #expect(queue.peek() == nil)
        #expect(queue.next() == nil)
        #expect(queue.next(for: key.id) == nil)
        #expect(queue.takeEvents().isEmpty)
        #expect(queue.settle(queue.predicted) == .confirmed)
        #expect(!queue.needsFinalSettle)
        #expect(queue.next()?.steps == [.insert("s", at: 7)])
    }

    /// A non-final read that a foreign change explains is not a contradiction: the prediction follows the read
    /// and the next keystroke is issued against it.
    @Test func aKeystrokeAfterAnExplainedForeignReadIsIssuedAgainstTheRead() {
        var queue = FieldEditQueue(FieldSnapshot(before: "hello world", after: ""))
        let key = EditTransaction(origin: .keystroke, base: v0, steps: [.insert("s", at: 11)])
        queue.submit(key)
        _ = queue.next()
        #expect(queue.settle(FieldSnapshot(before: "hello", after: " there"), final: false) == .diverged)
        #expect(queue.takeEvents() == [.conflict(key.id, Conflict(.verifyFailed))])
        #expect(!queue.needsFinalSettle)
        #expect(queue.document.window == "hello there")
        queue.submit(EditTransaction(origin: .keystroke, base: queue.document.version, steps: [.insert("!", at: 5)]))
        #expect(queue.next()?.steps == [.insert("!", at: 5)])
    }

    // MARK: Possibly-user text is never agent-owned

    /// Mac "u and u": the agent fixes both "u"s, nothing lands, the user types "yo" before the last "u". The
    /// read is also the second fix landed alone; the caret after the typed text makes typing the reading: the
    /// write fails, "yo" is the user's (tainted), the agent owns nothing there.
    @Test func typingThatLooksLikeOneStepOfAnAgentWriteStaysTheUsers() {
        var queue = macQueue("u and u")
        let fix = EditTransaction(
            origin: .agent, owner: "agent", base: v0,
            steps: [replace(0, "u", with: "you"), replace(6, "u", with: "you")])
        let mark = EditTransaction(origin: .liveCleanup, owner: "run", base: v0, steps: [.insert("!", at: 7)])
        queue.submit(fix)
        queue.submit(mark)
        _ = queue.next()
        #expect(queue.settle(FieldSnapshot(window: "u and you", caret: 8, windowBase: 0)) == .diverged)
        #expect(queue.takeEvents() == [.conflict(fix.id, Conflict(.verifyFailed))])
        #expect(queue.document.window == "u and you")
        #expect(!queue.document.owned.contains { $0.owner == "agent" })
        #expect(queue.document.tainted.contains(Span(location: 6, length: 2)))
        #expect(queue.feed.entries.last?.event == .foreign(.insert("yo", at: 6), byUser: true, version: queue.document.version))
        #expect(queue.next()?.steps == [.insert("!", at: 9)])
    }

    // MARK: Ties

    /// "xay" + inserts of "a" at 1 and 2, read "xaay": either insert landed. The field is the same, but an edit
    /// based before the write maps differently through each: it comes back `outOfWindow`, never misplaced.
    @Test func aTieWithDifferentHistoriesMapsNoLateEdit() {
        var queue = macQueue("xay")
        let write = EditTransaction(origin: .tool, base: v0, steps: [.insert("a", at: 1), .insert("a", at: 2)])
        queue.submit(write)
        _ = queue.next()
        #expect(queue.settle(FieldSnapshot(window: "xaay", caret: 4, windowBase: 0)) == .diverged)
        _ = queue.takeEvents()
        let late = EditTransaction(origin: .agent, base: v0, steps: [.insert("!", at: 2)])
        queue.submit(late)
        #expect(queue.takeEvents() == [.conflict(late.id, Conflict(.outOfWindow))])
        #expect(queue.next() == nil)
        let current = EditTransaction(origin: .agent, base: queue.document.version, steps: [.insert("!", at: 3)])
        queue.submit(current)
        #expect(queue.next()?.steps == [.insert("!", at: 3)])
    }

    // MARK: Feed compatibility

    /// The feed's wire format is frozen per build: app and keyboard ship in one bundle and update together. A
    /// reader of another build fails to decode an unknown case loudly instead of misreading it.
    @Test func anUnknownFeedEventFailsToDecode() {
        let json = Data(#"{"futureCase":{"_0":"x"}}"#.utf8)
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(FeedEvent.self, from: json) }
    }
}
