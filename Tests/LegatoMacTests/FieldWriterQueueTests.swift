import Foundation
import LegatoFieldEdit
import Testing
@testable import LegatoMac

/// The spike's patch fixtures (P01-P12, `spikes/keyboard-corrections/Fixtures/patches.json`) replayed through the
/// Mac executor onto a `FakeTextTarget`: the queue's steps go in as select, replace, select back, each checked by
/// readback; faults and user typing never produce a misplaced write.
@MainActor
@Suite struct FieldWriterQueueTests {
    static let prefix = "ANCHOR | "
    static let outside = " | OUTSIDE"

    struct Case: Sendable {
        let id: String
        let old: String
        let new: String
    }

    /// P01-P06: one contiguous correction at the end of the run's text.
    nonisolated static let patchCases: [Case] = [
        Case(id: "P01", old: "Send teh report while the meeting continues with no change to the remaining facts.", new: "Send the report while the meeting continues with no change to the remaining facts."),
        Case(id: "P02", old: "Send report while the meeting continues with no change to the remaining facts.", new: "Send the report while the meeting continues with no change to the remaining facts."),
        Case(id: "P03", old: "Send the the report while the meeting continues with no change to the remaining facts.", new: "Send the report while the meeting continues with no change to the remaining facts."),
        Case(id: "P04", old: "go go go home today", new: "go go stay home today"),
        Case(id: "P05", old: "Cafe\u{301} and cafe\u{301} remain", new: "Caf\u{E9} and cafe\u{301} remain"),
        Case(id: "P06", old: "Keep \u{1F469}\u{1F3FD}\u{200D}\u{1F4BB} teh \u{1F1E9}\u{1F1EA} flag and \u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}\u{200D}\u{1F466}", new: "Keep \u{1F469}\u{1F3FD}\u{200D}\u{1F4BB} the \u{1F1E9}\u{1F1EA} flag and \u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}\u{200D}\u{1F466}"),
    ]

    // MARK: Harness

    /// A field holding `prefix + old + outside` with the caret at the end of `old` (where the run's text ends).
    private func fixture(old: String) -> (field: FakeTextTarget, executor: AXFieldExecutor, start: Int) {
        let start = Self.prefix.utf16.count
        let field = FakeTextTarget(
            Self.prefix + old + Self.outside, selection: UTF16Range(location: start + old.utf16.count, length: 0))
        return (field, AXFieldExecutor(target: field)!, start)
    }

    private func transaction(
        _ executor: AXFieldExecutor, _ steps: [EditStep], origin: EditOrigin = .agent, caret: Int? = nil,
        coalesce: String? = nil
    ) -> EditTransaction {
        EditTransaction(
            origin: origin, owner: "run", base: executor.queue.document.version, steps: steps, caret: caret,
            coalesce: coalesce)
    }

    private func conflicts(_ events: [QueueEvent]) -> [Conflict.Reason] {
        events.compactMap { if case .conflict(_, let conflict) = $0 { conflict.reason } else { nil } }
    }

    private func appliedCount(_ events: [QueueEvent]) -> Int {
        events.filter { if case .applied = $0 { true } else { false } }.count
    }

    // MARK: P01-P06 patches

    @Test(arguments: patchCases) func patchLandsAsOneSmallWriteAndLeavesTheRestAlone(_ c: Case) throws {
        let (field, executor, start) = fixture(old: c.old)
        let step = try #require(ContiguousPatch.between(c.old, c.new, at: start))
        let oldCaret = field.selection
        executor.submit(transaction(executor, [step]))
        #expect(executor.drain() == .idle)

        #expect(field.string == Self.prefix + c.new + Self.outside, Comment(rawValue: c.id))
        // Patch volume: exactly one replace, of the patch's removed text only (never the whole run).
        #expect(field.writes.count == 1)
        #expect(field.writes[0].range == UTF16Range(location: step.span.location, length: step.span.length))
        #expect(field.writes[0].text == step.text)
        #expect(step.span.length + step.text.utf16.count < c.old.utf16.count)
        // The caret is where the user left it, shifted by the net length change.
        let net = c.new.utf16.count - c.old.utf16.count
        #expect(field.selection == UTF16Range(location: oldCaret.location + net, length: 0))
        #expect(field.selections.last == field.selection)
        #expect(appliedCount(executor.takeEvents()) == 1)
    }

    @Test func writeIsSelectThenReplaceThenSelectBack() throws {
        let (field, executor, start) = fixture(old: "send teh report")
        let step = try #require(ContiguousPatch.between("send teh report", "send the report", at: start))
        executor.submit(transaction(executor, [step]))
        executor.drain()
        #expect(field.selections.first == UTF16Range(location: step.span.location, length: step.span.length))
        #expect(field.selections.count == 2)
    }

    @Test func twoStepEditLandsHighestFirstAndKeepsBothSpansValid() throws {
        let (field, executor, start) = fixture(old: "teh cat sat on teh mat")
        let steps = [
            EditStep(span: Span(location: start, length: 3), text: "the", expect: "teh"),
            EditStep(span: Span(location: start + 15, length: 3), text: "the", expect: "teh"),
        ]
        executor.submit(transaction(executor, steps))
        executor.drain()
        #expect(field.string == Self.prefix + "the cat sat on the mat" + Self.outside)
        #expect(field.writes.map(\.range.location) == [start + 15, start])
    }

    // MARK: P07 a newer commit lands before the patch is written

    @Test func p07NewerTextAppendedMeanwhileMapsThePatchAndKeepsTheCaretAfterIt() throws {
        let (field, executor, start) = fixture(old: "send teh report")
        let step = try #require(ContiguousPatch.between("send teh report", "send the report", at: start))
        executor.submit(transaction(executor, [step]))
        field.userTypes(" and keep 42 unchanged") // the run's next phrase landed first
        #expect(executor.drain() == .idle)
        let typed = Self.prefix + "send the report and keep 42 unchanged" + Self.outside
        #expect(field.string == typed)
        #expect(field.selection.location == start + "send the report and keep 42 unchanged".utf16.count)
        #expect(conflicts(executor.takeEvents()).isEmpty)
    }

    // MARK: P08 growth at the end

    @Test func p08StillGrowingTextIsPatchedAtTheEnd() throws {
        let (field, executor, start) = fixture(old: "hello wor")
        let step = try #require(ContiguousPatch.between("hello wor", "hello world", at: start))
        executor.submit(transaction(executor, [step], origin: .asr))
        executor.drain()
        #expect(field.string == Self.prefix + "hello world" + Self.outside)
        #expect(field.selection.location == start + "hello world".utf16.count)
    }

    // MARK: P09 ordering

    @Test func p09OlderCoalescedEditIsSupersededAndOnlyTheNewestWrites() throws {
        let (field, executor, start) = fixture(old: "send teh report")
        let step = try #require(ContiguousPatch.between("send teh report", "send the report", at: start))
        let older = transaction(executor, [step], coalesce: "run")
        let newer = transaction(executor, [step], coalesce: "run")
        executor.submit(older)
        executor.submit(newer)
        executor.drain()
        #expect(field.string == Self.prefix + "send the report" + Self.outside)
        #expect(field.writes.count == 1)
        let events = executor.takeEvents()
        #expect(events.contains(.superseded(older.id, by: newer.id)))
    }

    // MARK: P10 the user acts before the write

    @Test func p10UserTextBeforeThePatchRemapsIt() throws {
        let (field, executor, start) = fixture(old: "send teh report")
        let step = try #require(ContiguousPatch.between("send teh report", "send the report", at: start))
        executor.submit(transaction(executor, [step]))
        field.externalEdit(UTF16Range(location: 0, length: 0), with: "Note: ")
        executor.drain()
        #expect(field.string == "Note: " + Self.prefix + "send the report" + Self.outside)
    }

    @Test func p10UserEditInsideThePatchIsAConflictNotAWrite() throws {
        let (field, executor, start) = fixture(old: "send teh report")
        let step = try #require(ContiguousPatch.between("send teh report", "send the report", at: start))
        executor.submit(transaction(executor, [step]))
        field.externalEdit(UTF16Range(location: start + 5, length: 3), with: "TEH")
        executor.drain()
        #expect(field.string == Self.prefix + "send TEH report" + Self.outside)
        #expect(field.writes.isEmpty)
        #expect(conflicts(executor.takeEvents()).count == 1)
    }

    @Test func p10CaretMovedAwayStaysWhereTheUserPutIt() throws {
        let (field, executor, start) = fixture(old: "send teh report")
        let step = try #require(ContiguousPatch.between("send teh report", "send the report", at: start))
        executor.submit(transaction(executor, [step]))
        field.moveCaret(to: 2)
        executor.drain()
        #expect(field.string == Self.prefix + "send the report" + Self.outside)
        #expect(field.selection == UTF16Range(location: 2, length: 0))
    }

    @Test func p10FocusLostConflictsEverythingWithFocusLostAndWritesNothing() throws {
        let (field, executor, start) = fixture(old: "send teh report")
        let step = try #require(ContiguousPatch.between("send teh report", "send the report", at: start))
        executor.submit(transaction(executor, [step]))
        field.focused = false
        #expect(executor.drain() == .blocked(.focusLost))
        #expect(field.writes.isEmpty)
        #expect(conflicts(executor.takeEvents()) == [.focusLost])
    }

    // MARK: P11 the field was cleared or sent

    @Test func p11ClearedFieldHandsTheEditBackWithoutWriting() throws {
        let (field, executor, start) = fixture(old: "hello world ")
        let step = try #require(ContiguousPatch.between("hello world ", "Hello world. ", at: start))
        executor.submit(transaction(executor, [step]))
        field.externalEdit(UTF16Range(location: 0, length: field.units.count), with: "")
        executor.drain()
        #expect(field.string.isEmpty)
        #expect(field.writes.isEmpty)
        #expect(conflicts(executor.takeEvents()) == [.outOfWindow])
    }

    @Test func p11NewRawTextReplacingTheSentOneIsAConflict() throws {
        let (field, executor, start) = fixture(old: "hello world ")
        let step = try #require(ContiguousPatch.between("hello world ", "Hello world. ", at: start))
        executor.submit(transaction(executor, [step]))
        field.externalEdit(UTF16Range(location: start, length: "hello world ".utf16.count), with: "new message ")
        executor.drain()
        #expect(field.string == Self.prefix + "new message " + Self.outside)
        #expect(field.writes.isEmpty)
        #expect(conflicts(executor.takeEvents()).count == 1)
    }

    // MARK: P12 faults degrade into conflicts, never into a misplaced write

    private func faultFixture() throws -> (FakeTextTarget, AXFieldExecutor, EditStep) {
        let (field, executor, start) = fixture(old: "send teh report suffix")
        let step = try #require(ContiguousPatch.between("send teh report suffix", "send the report suffix", at: start))
        executor.submit(transaction(executor, [step]))
        return (field, executor, step)
    }

    @Test func p12IgnoredWriteIsVerifyFailedAndTheFieldIsUntouched() throws {
        let (field, executor, _) = try faultFixture()
        field.ignoreWrites = true
        executor.drain()
        #expect(field.string == Self.prefix + "send teh report suffix" + Self.outside)
        #expect(conflicts(executor.takeEvents()) == [.verifyFailed])
    }

    @Test func p12LyingAndTruncatedWritesAreVerifyFailed() throws {
        for configure in [{ (f: FakeTextTarget) in f.lieOnWrites = true }, { (f: FakeTextTarget) in f.storeOnlyFirst = 1 }] {
            let (field, executor, _) = try faultFixture()
            configure(field)
            executor.drain()
            #expect(conflicts(executor.takeEvents()) == [.verifyFailed])
            // Outside the patch nothing else was written.
            #expect(field.string.hasPrefix(Self.prefix + "send t"))
            #expect(field.string.hasSuffix(" report suffix" + Self.outside))
        }
    }

    @Test func p12ThrowingWriteIsWriteFailedAndTheUsersSelectionComesBack() throws {
        let (field, executor, _) = try faultFixture()
        let before = field.selection
        field.failWritesAfter = 0
        executor.drain()
        #expect(field.string == Self.prefix + "send teh report suffix" + Self.outside)
        #expect(conflicts(executor.takeEvents()) == [.writeFailed])
        #expect(field.selection == before)
    }

    @Test func p12UnreadableFieldBlocksWithoutWritingAndConflictsThePendingEdit() throws {
        let (field, executor, _) = try faultFixture()
        field.failReads = true
        #expect(executor.drain() == .blocked(.unreadable))
        #expect(field.writes.isEmpty)
        #expect(conflicts(executor.takeEvents()) == [.unreadable])
    }

    @Test func p12ReadbackFailureAfterTheWriteIsUnreadable() throws {
        let (field, executor, _) = try faultFixture()
        let flaky = FlakyTarget(field)
        flaky.failReadsAfterReplace = true
        let start = Self.prefix.utf16.count
        let local = AXFieldExecutor(target: flaky)!
        let step = try #require(ContiguousPatch.between("send teh report suffix", "send the report suffix", at: start))
        local.submit(transaction(local, [step]))
        #expect(local.drain() == .blocked(.unreadable))
        #expect(conflicts(local.takeEvents()).contains(.unreadable))
    }

    @Test func p12FailedSelectIsWriteFailedAndNothingIsReplaced() throws {
        let (field, _, step) = try faultFixture()
        let flaky = FlakyTarget(field)
        flaky.failSelect = true
        let local = AXFieldExecutor(target: flaky)!
        local.submit(transaction(local, [step]))
        local.drain()
        #expect(field.writes.isEmpty)
        #expect(conflicts(local.takeEvents()) == [.writeFailed])
    }

    // MARK: Typing between the select and the replace

    @Test func typingBeforeTheSpanBetweenSelectAndReplaceRemapsTheWrite() throws {
        let (field, executor, start) = fixture(old: "send teh report")
        let step = try #require(ContiguousPatch.between("send teh report", "send the report", at: start))
        executor.submit(transaction(executor, [step]))
        var fired = false
        field.onSelect = {
            guard !fired else { return }
            fired = true
            field.externalEdit(UTF16Range(location: 0, length: 0), with: "Hi! ")
        }
        executor.drain()
        #expect(field.string == "Hi! " + Self.prefix + "send the report" + Self.outside)
        #expect(field.writes.count == 1)
        #expect(conflicts(executor.takeEvents()).isEmpty)
    }

    @Test func typingInsideTheSpanBetweenSelectAndReplaceIsAConflictAndNeverAWrite() throws {
        let (field, executor, start) = fixture(old: "send teh report")
        let step = try #require(ContiguousPatch.between("send teh report", "send the report", at: start))
        executor.submit(transaction(executor, [step]))
        var fired = false
        field.onSelect = {
            guard !fired else { return }
            fired = true
            field.externalEdit(UTF16Range(location: step.span.location, length: 1), with: "X")
        }
        executor.drain()
        #expect(field.writes.isEmpty)
        #expect(field.string == Self.prefix + "send tXh report" + Self.outside)
        #expect(conflicts(executor.takeEvents()).count == 1)
    }

    @Test func endlessTypingBetweenSelectAndReplaceGivesUpWithAConflict() throws {
        let (field, executor, start) = fixture(old: "send teh report")
        let step = try #require(ContiguousPatch.between("send teh report", "send the report", at: start))
        executor.submit(transaction(executor, [step]))
        field.onSelect = { field.externalEdit(UTF16Range(location: 0, length: 0), with: "x") }
        executor.drain()
        #expect(field.writes.isEmpty)
        #expect(conflicts(executor.takeEvents()) == [.expectMismatch])
    }

    // MARK: One edit's failure never blocks the others

    @Test func staleEditConflictsWhileTheNextOneStillLands() throws {
        let (field, executor, start) = fixture(old: "teh cat sat on teh mat")
        let stale = EditStep(span: Span(location: start, length: 3), text: "the", expect: "WRONG")
        let good = EditStep(span: Span(location: start + 15, length: 3), text: "the", expect: "teh")
        executor.submit(transaction(executor, [stale]))
        executor.submit(transaction(executor, [good]))
        executor.drain()
        #expect(field.string == Self.prefix + "teh cat sat on the mat" + Self.outside)
        let events = executor.takeEvents()
        #expect(conflicts(events) == [.expectMismatch])
        #expect(appliedCount(events) == 1)
    }

    @Test func oneThrowingWriteDoesNotFailTheOthers() throws {
        let (field, executor, start) = fixture(old: "teh cat sat on teh mat")
        let first = EditStep(span: Span(location: start, length: 3), text: "the", expect: "teh")
        let second = EditStep(span: Span(location: start + 15, length: 3), text: "the", expect: "teh")
        executor.submit(transaction(executor, [first]))
        executor.submit(transaction(executor, [second]))
        field.failWritesAfter = 0 // the first replace throws ...
        var selects = 0
        field.onSelect = { // ... and the field recovers before the second edit's select
            selects += 1
            if selects == 2 { field.failWritesAfter = nil }
        }
        executor.drain()
        #expect(field.string == Self.prefix + "teh cat sat on the mat" + Self.outside)
        let events = executor.takeEvents()
        #expect(conflicts(events) == [.writeFailed])
        #expect(appliedCount(events) == 1)
    }

    // MARK: Typing guard

    private final class Source: FieldActivitySource {
        var handler: (@MainActor () -> Void)?
        func start(_ handler: @escaping @MainActor () -> Void) { self.handler = handler }
        func stop() { handler = nil }
    }

    private final class Clock { var now: TimeInterval = 50 }

    @Test func agentWritesWaitForQuietAndUserCommandsDoNot() throws {
        let start = Self.prefix.utf16.count
        let field = FakeTextTarget(Self.prefix + "teh cat sat" + Self.outside, selection: UTF16Range(location: start, length: 0))
        let source = Source()
        let clock = Clock()
        let guardian = TypingGuard(source: source, now: { clock.now })
        let executor = AXFieldExecutor(target: field, typingGuard: guardian)!
        // The user types; the field changes, which is not an echo of our writes.
        field.userTypes("x")
        MainActor.assumeIsolated { source.handler?() }
        // Planned against the field before the user typed; the queue maps it through the "x".
        let fix = EditStep(span: Span(location: start, length: 3), text: "the", expect: "teh")
        executor.submit(transaction(executor, [fix]))
        guard case .held(let wait) = executor.drain() else { Issue.record("expected held"); return }
        #expect(wait > 0.29 && wait <= 0.3)
        #expect(field.writes.isEmpty)

        // A user command (a word-row pick) goes through at once, ahead of the held edit.
        let pick = EditStep(span: Span(location: start + 1 + 4, length: 3), text: "dog", expect: "cat")
        executor.submit(transaction(executor, [pick], origin: .wordRow))
        guard case .held = executor.drain() else { Issue.record("expected held after the user command"); return }
        #expect(field.string == Self.prefix + "xteh dog sat" + Self.outside)

        clock.now += 0.31
        #expect(executor.drain() == .idle)
        #expect(field.string == Self.prefix + "xthe dog sat" + Self.outside)
    }

    @Test func ownWritesAreNotUserActivity() throws {
        let start = Self.prefix.utf16.count
        let field = FakeTextTarget(Self.prefix + "teh cat teh" + Self.outside, selection: UTF16Range(location: start, length: 0))
        let source = Source()
        let clock = Clock()
        let guardian = TypingGuard(source: source, now: { clock.now })
        let executor = AXFieldExecutor(target: field, typingGuard: guardian)!
        executor.submit(transaction(executor, [EditStep(span: Span(location: start, length: 3), text: "the", expect: "teh")]))
        #expect(executor.drain() == .idle)
        // AX reports our write's value change after the fact: the field reads as the queue left it.
        MainActor.assumeIsolated { source.handler?() }
        executor.submit(transaction(executor, [EditStep(span: Span(location: start + 8, length: 3), text: "the", expect: "teh")]))
        #expect(executor.drain() == .idle)
        #expect(field.string == Self.prefix + "the cat the" + Self.outside)
    }

    // MARK: Channel seam

    @Test func queuedChannelDrivesAFieldWriterToTheSameFieldAsTheDirectOne() throws {
        let direct = FakeTextTarget("Hi ")
        let directWriter = FieldWriter(target: direct)
        let queued = FakeTextTarget("Hi ")
        let executor = AXFieldExecutor(target: queued)!
        let queuedWriter = FieldWriter(target: queued, channel: QueuedFieldWriteChannel(executor: executor, owner: "run"))
        for writer in [directWriter, queuedWriter] {
            writer.apply(.commit(delta: "hello"))
            writer.apply(.commit(delta: " world"))
        }
        #expect(queued.string == direct.string)
        #expect(queued.selection == direct.selection)
        #expect(queuedWriter.finish(finalText: "hello world") == directWriter.finish(finalText: "hello world"))
        #expect(queuedWriter.degradeReason == nil)
    }

    @Test func queuedChannelWriteFailureDegradesTheWriterLikeADirectOne() throws {
        let queued = FakeTextTarget()
        let executor = AXFieldExecutor(target: queued)!
        let writer = FieldWriter(target: queued, channel: QueuedFieldWriteChannel(executor: executor, owner: "run"))
        queued.failWritesAfter = 0
        writer.apply(.commit(delta: "hello"))
        #expect(writer.degradeReason == .writeFailed)
        #expect(queued.string.isEmpty)
        #expect(writer.finish(finalText: "hello") == .paste("hello"))
    }
}

/// Forwards to a `FakeTextTarget` with faults a fake cannot express (a select that throws, reads that die after a write).
@MainActor
private final class FlakyTarget: TextTarget {
    let base: FakeTextTarget
    var failSelect = false
    var failReadsAfterReplace = false
    private var replaced = false
    struct Failure: Error {}

    init(_ base: FakeTextTarget) { self.base = base }
    func isFocused() -> Bool { base.isFocused() }
    func selectedRange() throws -> UTF16Range {
        if replaced && failReadsAfterReplace { throw Failure() }
        return try base.selectedRange()
    }
    func text(in range: UTF16Range) throws -> String {
        if replaced && failReadsAfterReplace { throw Failure() }
        return try base.text(in: range)
    }
    func replace(_ range: UTF16Range, with text: String) throws {
        try base.replace(range, with: text)
        replaced = true
    }
    func select(_ range: UTF16Range) throws {
        if failSelect { throw Failure() }
        base.select(range)
    }
}
