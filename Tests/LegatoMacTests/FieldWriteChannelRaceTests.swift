import Foundation
import LegatoCore
import LegatoFieldEdit
import Testing
@testable import LegatoMac

/// The typing guard and the races around a write: cleanup waits for quiet without being issued, the run's text and
/// user commands do not wait, nothing selects a stale span, an undo never overwrites typed text, and a write
/// planned after the user typed lands where the writer meant it.
@MainActor
@Suite struct FieldWriteChannelRaceTests {
    private final class Source: FieldActivitySource {
        func start(_ handler: @escaping @MainActor () -> Void) -> Bool { true }
        func stop() {}
    }

    private final class Clock { var now: TimeInterval = 50 }

    private struct Rig {
        let field: FakeTextTarget
        let executor: AXFieldExecutor
        let guardian: TypingGuard
        let clock: Clock
        let channel: QueuedFieldWriteChannel
    }

    private func rig(_ text: String, caret: Int? = nil) -> Rig {
        let field = FakeTextTarget(text, selection: caret.map { UTF16Range(location: $0, length: 0) })
        let clock = Clock()
        let guardian = TypingGuard(source: Source(), now: { clock.now })
        let executor = AXFieldExecutor(target: field, typingGuard: guardian)!
        return Rig(
            field: field, executor: executor, guardian: guardian, clock: clock,
            channel: QueuedFieldWriteChannel(executor: executor, owner: "run"))
    }

    // MARK: a. Cleanup waits for typing quiet

    @Test(arguments: [EditOrigin.liveCleanup, .finalSwap]) func cleanupWriteWhileTypingIsHeldAndNeverIssued(_ origin: EditOrigin) throws {
        let r = rig("Hi helo")
        r.guardian.noteUserActivity()
        let version = r.executor.queue.document.version
        #expect(throws: QueuedFieldWriteChannel.Held.self) {
            try r.channel.replace(UTF16Range(location: 3, length: 4), with: "hello", expect: "helo", origin: origin)
        }
        #expect(r.field.writes.isEmpty)
        #expect(!r.executor.queue.hasPending)
        #expect(r.executor.queue.document.version == version)  // no version burned
        #expect(r.executor.takeEvents().isEmpty)
        r.clock.now += 0.31
        try r.channel.replace(UTF16Range(location: 3, length: 4), with: "hello", expect: "helo", origin: origin)
        #expect(r.field.string == "Hi hello")
    }

    @Test(arguments: [EditOrigin.asr, .hold, .versions, .wordRow]) func theRunsTextAndUserPicksAreNotHeld(_ origin: EditOrigin) throws {
        let r = rig("Hi ")
        r.guardian.noteUserActivity()
        try r.channel.replace(UTF16Range(location: 3, length: 0), with: "hello", expect: "", origin: origin)
        #expect(r.field.string == "Hi hello")
    }

    @Test func heldCleanupEditStaysQueuedWithoutConflictOrBurntVersionWhileTheRunWrites() throws {
        let r = rig("Hi helo")
        let agent = EditTransaction(
            origin: .agent, owner: "agent", base: r.executor.queue.document.version,
            steps: [EditStep(span: Span(location: 3, length: 4), text: "hello", expect: "helo")])
        r.executor.submit(agent)
        r.guardian.noteUserActivity()
        let version = r.executor.queue.document.version
        try r.channel.replace(UTF16Range(location: 7, length: 0), with: "!", expect: "", origin: .asr)
        #expect(r.field.string == "Hi helo!")
        #expect(r.executor.queue.hasPending)
        #expect(r.executor.queue.document.version == version.next)  // only the run's own write spent a version
        #expect(r.executor.takeEvents().isEmpty)
    }

    @Test func drainRunsTheRunsEditWhileTypingAndOnlyHoldsCleanup() throws {
        let r = rig("Hi helo")
        let agent = EditTransaction(
            origin: .agent, owner: "agent", base: r.executor.queue.document.version,
            steps: [EditStep(span: Span(location: 3, length: 4), text: "hello", expect: "helo")])
        let run = EditTransaction(
            origin: .asr, owner: "run", base: r.executor.queue.document.version,
            steps: [EditStep.insert("!", at: 7)])
        r.executor.submit(agent)
        r.executor.submit(run)
        r.guardian.noteUserActivity()
        guard case .held = r.executor.drain() else { Issue.record("expected held"); return }
        #expect(r.field.string == "Hi helo!")
        let events = r.executor.takeEvents()
        #expect(events.count == 1)
        #expect(events.contains { if case .applied(run.id, _) = $0 { true } else { false } })
        r.clock.now += 0.31
        #expect(r.executor.drain() == .idle)
        #expect(r.field.string == "Hi hello!")
    }

    @Test func finalSwapWhileTypingLeavesTheFieldAndTheWriterHealthy() throws {
        let r = rig("")
        let writer = FieldWriter(target: r.field, channel: r.channel)
        writer.apply(.commit(delta: "meet on friday"))
        r.guardian.noteUserActivity()
        guard case .held(let wait) = writer.swapWritten(for: "Meet on Friday.") else { Issue.record("expected held"); return }
        #expect(wait > 0 && wait <= 0.3)
        #expect(r.field.string == "meet on friday")
        #expect(writer.degradeReason == nil)
        r.clock.now += 0.31
        #expect(writer.swapWritten(for: "Meet on Friday.") == .swapped)
        #expect(r.field.string == "Meet on Friday.")
    }

    // MARK: b. The span is checked before it is selected

    @Test func aFieldThatChangedIsNeverSelectedAtTheStaleSpan() throws {
        let start = 9
        let base = FakeTextTarget("ANCHOR | send teh report | OUTSIDE", selection: UTF16Range(location: 24, length: 0))
        let hooked = HookedTarget(base)
        let executor = AXFieldExecutor(target: hooked)!
        let step = try #require(ContiguousPatch.between("send teh report", "send the report", at: start))
        executor.submit(EditTransaction(origin: .agent, owner: "agent", base: executor.queue.document.version, steps: [step]))
        // The user types in front of the span after the executor's read, right before it starts the write.
        hooked.onFocusCheck = { count in
            if count == 2 { base.externalEdit(UTF16Range(location: 0, length: 0), with: "Z") }
        }
        executor.drain()
        #expect(base.string == "ZANCHOR | send the report | OUTSIDE")
        #expect(base.selections.first { $0.length > 0 } == UTF16Range(location: step.span.location + 1, length: step.span.length))
    }

    // MARK: c. A partial write is only taken back where it still reads as written

    @Test func typedTextRightAfterAPartialStepIsKeptWhenTheStepIsTakenBack() throws {
        let base = FakeTextTarget("Hi there", selection: UTF16Range(location: 8, length: 0))
        let hooked = HookedTarget(base)
        let executor = AXFieldExecutor(target: hooked)!
        let steps = [
            EditStep(span: Span(location: 0, length: 2), text: "Yo", expect: "Hi"),
            EditStep.insert("ab", at: 8),
        ]
        executor.submit(EditTransaction(origin: .agent, owner: "agent", base: executor.queue.document.version, steps: steps))
        var typed = false
        hooked.onReplace = { count in  // the insert at 8 lands first; the user types "b" right after it
            guard count == 1, !typed else { return }
            typed = true
            base.externalEdit(UTF16Range(location: 10, length: 0), with: "b")
        }
        executor.drain()
        // The insert was taken back without touching the user's "b", then the write ran again on the new text.
        #expect(base.string == "Yo thereabb")
        #expect(base.writes.map(\.text) == ["ab", "", "ab", "Yo"])
    }

    @Test func aStepThatNoLongerReadsAsWrittenIsNotTakenBack() throws {
        let base = FakeTextTarget("Hi there", selection: UTF16Range(location: 8, length: 0))
        let hooked = HookedTarget(base)
        let executor = AXFieldExecutor(target: hooked)!
        let steps = [
            EditStep(span: Span(location: 0, length: 2), text: "Yo", expect: "Hi"),
            EditStep.insert("ab", at: 8),
        ]
        executor.submit(EditTransaction(origin: .agent, owner: "agent", base: executor.queue.document.version, steps: steps))
        var typed = false
        hooked.onReplace = { count in  // the user types inside the inserted text
            guard count == 1, !typed else { return }
            typed = true
            base.externalEdit(UTF16Range(location: 9, length: 0), with: "X")
        }
        executor.drain()
        // "aXb" is not what the step wrote: it stays, and the write is settled as the field shows it.
        #expect(base.string.contains("aXb"))
        #expect(!base.writes.contains { $0.text.isEmpty })
    }

    // MARK: d. A write planned after the user typed lands where the writer put it

    @Test func insertAfterTheWritersTextLandsAfterItWhenTheUserTypedBeforeTheQueueSawIt() throws {
        let r = rig("Hi hello", caret: 8)
        r.field.externalEdit(UTF16Range(location: 0, length: 0), with: "Z")  // between the writer's check and the channel
        try r.channel.replace(
            UTF16Range(location: 8, length: 0), with: " world", expect: "", preceding: "Hi hello", origin: .asr)
        #expect(r.field.string == "ZHi hello world")
    }

    @Test func insertWhoseTextIsNowhereIsRejectedNotMisplaced() throws {
        let r = rig("Hi hello", caret: 8)
        r.field.externalEdit(UTF16Range(location: 0, length: 0), with: "Z")
        #expect(throws: QueuedFieldWriteChannel.Rejected(reason: .expectMismatch)) {
            try r.channel.replace(
                UTF16Range(location: 8, length: 0), with: " world", expect: "", preceding: "Hi hellp", origin: .asr)
        }
        #expect(r.field.string == "ZHi hello")
        #expect(r.field.writes.isEmpty)
    }

    @Test func retriedChannelWriteLandsAfterTheUserTypedDuringTheSelect() throws {
        let r = rig("Hi hello", caret: 8)
        var fired = false
        r.field.onSelect = {
            guard !fired else { return }
            fired = true
            r.field.externalEdit(UTF16Range(location: 0, length: 0), with: "Z")
        }
        try r.channel.replace(UTF16Range(location: 8, length: 0), with: " world", expect: "", origin: .asr)
        #expect(r.field.string == "ZHi hello world")
    }

    @Test func bothViewsMatchingTheAnchorPlansOnTheQueuesViewAndMapsThroughTheTyping() throws {
        let r = rig("the", caret: 3)
        r.field.externalEdit(UTF16Range(location: 0, length: 0), with: "the ")
        try r.channel.replace(
            UTF16Range(location: 3, length: 0), with: " world", expect: "", preceding: "the", origin: .asr)
        #expect(r.field.string == "the the world")
    }

    @Test func writerInsertsAfterItsOwnTextWhenTheUserTypesBetweenItsCheckAndTheChannel() throws {
        let base = FakeTextTarget("", selection: UTF16Range(location: 0, length: 0))
        let hooked = HookedTarget(base)
        let clock = Clock()
        let executor = AXFieldExecutor(target: hooked, typingGuard: TypingGuard(source: Source(), now: { clock.now }))!
        let writer = FieldWriter(target: hooked, channel: QueuedFieldWriteChannel(executor: executor, owner: "run"))
        writer.apply(.commit(delta: "Hi hello"))
        // The writer reads its text back (its drift check), then the user types in front of it.
        var armed = true
        hooked.onTextRead = {
            guard armed else { return }
            armed = false
            base.externalEdit(UTF16Range(location: 0, length: 0), with: "Z")
        }
        writer.apply(.commit(delta: " world"))
        #expect(base.string == "ZHi hello world")
    }
}

/// Forwards to a `FakeTextTarget` with hooks at the moments a user could type.
@MainActor
private final class HookedTarget: TextTarget {
    let base: FakeTextTarget
    var onFocusCheck: ((Int) -> Void)?
    var onReplace: ((Int) -> Void)?
    var onTextRead: (() -> Void)?
    private var focusChecks = 0
    private var replaces = 0

    init(_ base: FakeTextTarget) { self.base = base }

    func isFocused() -> Bool {
        focusChecks += 1
        onFocusCheck?(focusChecks)
        return base.isFocused()
    }
    func selectedRange() throws -> UTF16Range { try base.selectedRange() }
    func length() throws -> Int { try base.length() }
    func text(in range: UTF16Range) throws -> String {
        let text = try base.text(in: range)
        onTextRead?()
        return text
    }
    func replace(_ range: UTF16Range, with text: String) throws {
        try base.replace(range, with: text)
        replaces += 1
        onReplace?(replaces)
    }
    func select(_ range: UTF16Range) throws { base.select(range) }
}
