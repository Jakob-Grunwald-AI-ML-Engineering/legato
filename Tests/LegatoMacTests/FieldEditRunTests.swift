import Foundation
import LegatoAppServices
import LegatoCore
import LegatoFieldEdit
import Testing
@testable import LegatoMac

/// An agent that does not answer its feed batches until the gate opens (the shared model session is still warming).
private actor Gate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        for waiter in waiters { waiter.resume() }
        waiters = []
    }
}

private struct GatedAgent: FieldAgent {
    let base: CleanupAgent
    let gate: Gate

    func consume(_ batch: FeedBatch) async -> [EditTransaction] {
        await gate.wait()
        return await base.consume(batch)
    }

    func conflicted(_ conflict: Conflict, for transaction: UUID) async { await base.conflicted(conflict, for: transaction) }
}

/// A run's edit queue wiring (`FieldEditRun`) over a `FakeTextTarget`, with the real cleanup agent on a
/// scripted rolling session: Live patches land patch-sized, the user's typing is a conflict with a note, Replace
/// and Hold go through the queue, and a final swap held back by typing waits and retries.
@MainActor
@Suite struct FieldEditRunTests {
    @MainActor final class Clock {
        var now: TimeInterval = 100
        var pauses: [TimeInterval] = []
        /// Types in the field on every pause (the user does not stop).
        var keepTyping: (() -> Void)?
        /// Pauses never return (the background retry of a held edit does not run until released).
        var blockPauses = false
    }

    @MainActor final class Typed { var done = false }

    @MainActor struct Rig {
        let target: FakeTextTarget
        let clock: Clock
        let run: FieldEditRun
        let writer: FieldWriter
        let session: ScriptedSession?

        /// The agent's edits written through the queue; `replies` is the model's script.
        static func live(
            _ text: String = "", replies: [String], mode: FieldWriter.Mode = .streamCommitted,
            onRespond: (@MainActor @Sendable () -> Void)? = nil, target: FakeTextTarget? = nil, clock: Clock? = nil
        ) async -> Rig {
            let clock = clock ?? Clock()
            let target = target ?? FakeTextTarget(text)
            let session = ScriptedSession(replies: replies, onRespond: onRespond)
            let agent = CleanupAgent(session: session, options: .init(owner: "run"))
            let run = FieldEditRun(
                target: target, owner: "run",
                agent: FieldRunAgent(
                    agent, tentative: { await agent.setTentative(length: $0) }, replan: { await agent.replan() },
                    finish: { await agent.finish() }),
                now: { clock.now }, pause: { seconds in
                    if clock.blockPauses {
                        try? await Task.sleep(for: .seconds(30))
                        return
                    }
                    clock.pauses.append(seconds)
                    clock.now += seconds + 0.01
                    clock.keepTyping?()
                })!
            let writer = FieldWriter(target: target, mode: mode, channel: run.channel)
            run.attach(writer: writer)
            run.start()
            return Rig(target: target, clock: clock, run: run, writer: writer, session: session)
        }

        /// No agent (Replace, Hold).
        static func plain(
            _ text: String = "", mode: FieldWriter.Mode = .streamCommitted, clock: Clock? = nil
        ) -> Rig {
            let clock = clock ?? Clock()
            let target = FakeTextTarget(text)
            let run = FieldEditRun(
                target: target, owner: "run", agent: nil, now: { clock.now }, pause: { seconds in
                    clock.pauses.append(seconds)
                    clock.now += seconds + 0.01
                    clock.keepTyping?()
                })!
            let writer = FieldWriter(target: target, mode: mode, channel: run.channel)
            run.attach(writer: writer)
            return Rig(target: target, clock: clock, run: run, writer: writer, session: nil)
        }

        /// The engine commits `text`; the agent gets to see it.
        func hear(_ text: String) async {
            writer.apply(.commit(delta: text))
            run.textChanged()
            await run.idle()
        }
    }

    // MARK: Live

    @Test(.timeLimit(.minutes(1))) func aDeferredAgentCleansTextThatLandedBeforeItWasMade() async {
        let session = ScriptedSession(replies: [ScriptedSession.edits((1, "Send the report."))])
        let gate = Gate()
        let target = FakeTextTarget()
        let run = FieldEditRun(
            target: target, owner: "run",
            agent: FieldRunAgent(deferred: {
                await gate.wait()
                let cleanup = CleanupAgent(session: session, options: .init(owner: "run"))
                return FieldRunAgent(cleanup, replan: { await cleanup.replan() }, finish: { await cleanup.finish() })
            }))!
        let writer = FieldWriter(target: target, channel: run.channel)
        run.attach(writer: writer)
        #expect(run.agentRuns)
        run.start()
        writer.apply(.commit(delta: "Send teh report. Then"))
        run.textChanged()
        #expect(target.string == "Send teh report. Then")
        await gate.open()
        await run.idle()
        #expect(target.string == "Send the report. Then")
        let outcome = await run.finish()
        #expect(outcome.unapplied.isEmpty)
        #expect(writer.degradeReason == nil)
    }

    @Test(.timeLimit(.minutes(1))) func aDeferredAgentThatNeverComesLeavesTheRawText() async {
        let target = FakeTextTarget()
        let run = FieldEditRun(target: target, owner: "run", agent: FieldRunAgent(deferred: { nil }))!
        let writer = FieldWriter(target: target, channel: run.channel)
        run.attach(writer: writer)
        run.start()
        writer.apply(.commit(delta: "Send teh report."))
        run.textChanged()
        await run.idle()
        let outcome = await run.finish()
        #expect(outcome.unapplied.isEmpty)
        #expect(target.string == "Send teh report.")
        #expect(writer.finish(finalText: nil) == .done)
    }


    @Test(.timeLimit(.minutes(1))) func startDoesNotWaitForTheAgentAndItStillSeesTheFieldBeforeTheFirstText() async {
        let session = ScriptedSession(replies: [ScriptedSession.edits((1, "Send the report."))])
        let cleanup = CleanupAgent(session: session, options: .init(owner: "run"))
        let gate = Gate()
        let target = FakeTextTarget()
        let run = FieldEditRun(
            target: target, owner: "run",
            agent: FieldRunAgent(
                GatedAgent(base: cleanup, gate: gate), replan: { await cleanup.replan() }, finish: { await cleanup.finish() }))!
        let writer = FieldWriter(target: target, channel: run.channel)
        run.attach(writer: writer)
        run.start()  // returns while the agent still waits: recording is not held back

        writer.apply(.commit(delta: "Send teh report. Then"))
        run.textChanged()
        #expect(target.string == "Send teh report. Then")
        await gate.open()
        await run.idle()
        // The agent got the field as it was before the text landed, so it knows the text is the run's.
        #expect(target.string == "Send the report. Then")
        let outcome = await run.finish()
        #expect(outcome.unapplied.isEmpty)
        #expect(writer.degradeReason == nil)
    }


    @Test func liveAgentPatchesLandPatchSized() async {
        let rig = await Rig.live(replies: [ScriptedSession.edits((1, "Send the report now."))])
        await rig.hear("Send teh report now.")
        #expect(rig.target.string == "Send the report now.")
        // P01: two characters out, two in, at their place; not the sentence.
        let patch = rig.target.writes.last
        #expect(patch?.text == "he")
        #expect(patch?.range == UTF16Range(location: 6, length: 2))
        #expect(rig.writer.degradeReason == nil)
        #expect(rig.writer.shownText == "Send the report now.")

        // The writer keeps going after the agent's patch: more text lands where it should.
        await rig.hear(" Thanks.")
        let outcome = await rig.run.finish()
        #expect(outcome.unapplied.isEmpty)
        #expect(rig.writer.degradeReason == nil)
        #expect(rig.writer.finish(finalText: nil) == .done)
        #expect(rig.target.string == "Send the report now. Thanks.")
    }

    @Test func liveFinalPassCleansTheLastSentence() async {
        // The unfinished last sentence is only reviewed by the final pass.
        let rig = await Rig.live(replies: [ScriptedSession.edits((1, "Send the report"))])
        await rig.hear("Send teh report")
        #expect(rig.target.string == "Send teh report")
        let outcome = await rig.run.finish()
        #expect(outcome.unapplied.isEmpty)
        #expect(rig.target.string == "Send the report")
        #expect(rig.writer.finish(finalText: nil) == .done)
    }

    @Test func tentativeTextIsNeverEditedByTheAgentAndTheWriterKeepsStreaming() async {
        let rig = await Rig.live(
            replies: [ScriptedSession.edits((1, "Send the report.")), ScriptedSession.edits((2, "Then the dog."))],
            mode: .streamLive)
        rig.writer.apply(.commit(delta: "Send teh report."))
        rig.writer.apply(.replaceVolatile(" Then teh dog."))
        rig.run.textChanged()
        await rig.run.idle()
        #expect(rig.target.string == "Send the report. Then teh dog.")
        #expect(rig.writer.degradeReason == nil)
        let requests = await rig.session!.requests
        #expect(requests.count == 1)
        #expect(requests.first?.contains("dog") == false)

        // The tentative text becomes final: now it is the agent's to review.
        rig.writer.apply(.commit(delta: " Then teh dog."))
        rig.run.textChanged()
        await rig.run.idle()
        #expect(rig.writer.degradeReason == nil)
        let outcome = await rig.run.finish()
        #expect(outcome.unapplied.isEmpty)
        #expect(rig.target.string == "Send the report. Then the dog.")
        #expect(rig.writer.finish(finalText: nil) == .done)
    }

    @Test func userTypingMidRunIsAConflictWithANoteAndTheAgentLeavesThatSpan() async {
        let target = FakeTextTarget()
        let typed = Typed()
        // While the model works (the first request only), the user types into the second sentence.
        let rig = await Rig.live(
            replies: [ScriptedSession.edits((1, "Send the report."), (2, "Then go to the store."))],
            onRespond: {
                guard !typed.done else { return }
                typed.done = true
                target.externalEdit(UTF16Range(location: 30, length: 0), with: "!")
            }, target: target)
        await rig.hear("Send teh report. Then go to teh store.")
        // First sentence cleaned; the second keeps the user's "!" and the agent did not rewrite it.
        #expect(target.string == "Send the report. Then go to te!h store.")
        #expect(!target.string.contains("Then go to the store."))
        let appended = await rig.session!.appended.joined()
        #expect(appended.contains(Conflict.userNote))
        // The agent re-plans from the feed: the sentence the user touched is locked in the next request.
        let requests = await rig.session!.requests
        #expect(requests.count == 2)
        #expect(requests.last?.contains("Locked: 2.") == true)
        _ = await rig.run.finish()
        #expect(target.string == "Send the report. Then go to te!h store.")
    }

    @Test func finalEditsHeldByTypingWaitThenLand() async {
        let rig = await Rig.live(replies: [ScriptedSession.edits((1, "Send the report"))])
        await rig.hear("Send teh report")
        rig.run.typingGuard.noteUserActivity()
        let outcome = await rig.run.finish()
        #expect(!rig.clock.pauses.isEmpty)
        #expect(outcome.unapplied.isEmpty)
        #expect(rig.target.string == "Send the report")
    }

    @Test func finalEditsStillHeldAfterTheBudgetAreGivenUpForTheClipboard() async {
        let clock = Clock()
        let rig = await Rig.live(replies: [ScriptedSession.edits((1, "Send the report"))], clock: clock)
        await rig.hear("Send teh report")
        let guardRef = rig.run.typingGuard
        guardRef.noteUserActivity()
        clock.keepTyping = { guardRef.noteUserActivity() }  // the user never stops
        let outcome = await rig.run.finish()
        #expect(clock.pauses.reduce(0, +) <= FieldEditRun.finalHoldBudget)
        #expect(rig.target.string == "Send teh report")
        #expect(outcome.unapplied.count == 1)
        let fallback = rig.run.clipboardText(unapplied: outcome.unapplied)
        #expect(fallback == "Send the report")
    }

    @Test func rollingEditsHeldByTypingAtStopAreNotWithdrawnSilently() async {
        let clock = Clock()
        let rig = await Rig.live(replies: [ScriptedSession.edits((1, "Send the report."))], clock: clock)
        let guardRef = rig.run.typingGuard
        guardRef.noteUserActivity()
        clock.blockPauses = true
        await rig.hear("Send teh report. Then")
        #expect(rig.target.string == "Send teh report. Then")  // the rolling edit is held
        clock.blockPauses = false
        clock.keepTyping = { guardRef.noteUserActivity() }  // the user never stops
        let outcome = await rig.run.finish()
        #expect(outcome.unapplied.count == 1)
        #expect(outcome.unapplied.first?.steps.first?.expect == "eh")
        #expect(rig.target.string == "Send teh report. Then")
        let fallback = rig.run.clipboardText(unapplied: outcome.unapplied)
        #expect(fallback == "Send the report. Then")
    }

    @Test func rollingEditsHeldByTypingAtStopLandOnceTheUserPauses() async {
        let clock = Clock()
        let rig = await Rig.live(replies: [ScriptedSession.edits((1, "Send the report."))], clock: clock)
        rig.run.typingGuard.noteUserActivity()
        clock.blockPauses = true
        await rig.hear("Send teh report. Then")
        #expect(rig.target.string == "Send teh report. Then")
        clock.blockPauses = false
        let outcome = await rig.run.finish()
        #expect(outcome.unapplied.isEmpty)
        #expect(rig.target.string == "Send the report. Then")
        #expect(rig.writer.degradeReason == nil)
    }

    @Test(.timeLimit(.minutes(1))) func idleReturnsAfterTheRunWasClosedWithAWakeQueued() async {
        let rig = await Rig.live(replies: [])
        rig.run.textChanged()
        rig.run.cancel()
        await rig.run.idle()
    }

    // MARK: Clipboard fallback

    private func transaction(_ steps: EditStep...) -> EditTransaction {
        EditTransaction(origin: .agent, owner: "run", base: FieldVersion(0), steps: steps)
    }

    @Test func fallbackAppliesAStepAtItsPositionNotWhereItsExpectedTextFirstOccurs() {
        // "eh" occurs twice; the edit is for the second sentence, 100 characters into the field.
        let current = "I saw teh cat. A teh dog."
        let step = EditStep(span: Span(location: 118, length: 2), text: "he", expect: "eh")
        let text = FieldEditRun.fallbackText(current: current, spanStart: 100, unapplied: [transaction(step)])
        #expect(text == "I saw teh cat. A the dog.")
    }

    @Test func fallbackAppliesEveryStepWithoutShiftingTheOthersAndIncludesInsertions() {
        let current = "Teh cat sat. Teh dog ran"
        let steps = [
            EditStep(span: Span(location: 0, length: 3), text: "The", expect: "Teh"),
            EditStep(span: Span(location: 13, length: 3), text: "The big", expect: "Teh"),
            EditStep.insert(".", at: 24),
        ]
        let text = FieldEditRun.fallbackText(
            current: current, spanStart: 0, unapplied: [transaction(steps[0], steps[2]), transaction(steps[1])])
        #expect(text == "The cat sat. The big dog ran.")
    }

    @Test func fallbackLeavesAStepWhoseExpectedTextIsNotThereAlone() {
        let step = EditStep(span: Span(location: 6, length: 2), text: "he", expect: "eh")
        let text = FieldEditRun.fallbackText(current: "I saw tea cat.", spanStart: 0, unapplied: [transaction(step)])
        #expect(text == "I saw tea cat.")
    }

    // MARK: Replace and Hold

    @Test func replaceSwapsOnlyWhatDiffersThroughTheQueue() async {
        let rig = Rig.plain()
        rig.writer.apply(.commit(delta: "Send teh report now."))
        let action = rig.writer.finish(rawText: "Send teh report now.", cleanedText: "Send the report now.", delivery: .replace)
        #expect(action == .done)
        #expect(rig.target.string == "Send the report now.")
        let patch = rig.target.writes.last
        #expect(patch?.text == "he")
        #expect(patch?.range == UTF16Range(location: 6, length: 2))
        let origins = rig.run.executor.queue.feed.entries.compactMap { entry -> EditOrigin? in
            if case .applied(_, let origin, _, _) = entry.event { origin } else { nil }
        }
        #expect(origins == [.asr, .finalSwap])
    }

    @Test func holdInsertsOnceThroughTheQueueInTheAsrLane() async {
        let rig = Rig.plain(mode: .insertOnStop)
        rig.writer.apply(.commit(delta: "Send teh report now."))
        #expect(rig.target.writes.isEmpty)
        let action = rig.writer.finish(rawText: "Send teh report now.", cleanedText: "Send the report now.", delivery: .hold)
        #expect(action == .done)
        #expect(rig.target.writes.count == 1)
        #expect(rig.target.string == "Send the report now.")
        let origins = rig.run.executor.queue.feed.entries.compactMap { entry -> EditOrigin? in
            if case .applied(_, let origin, _, _) = entry.event { origin } else { nil }
        }
        #expect(origins == [.hold])
    }

    @Test func heldSwapIsRetriedAndLands() async {
        let rig = Rig.plain()
        rig.writer.apply(.commit(delta: "Send teh report now."))
        rig.run.typingGuard.noteUserActivity()
        let action = await rig.writer.finish(
            rawText: "Send teh report now.", cleanedText: "Send the report now.", delivery: .replace,
            retryingFor: FieldEditRun.finalHoldBudget, wait: { await rig.run.wait($0) })
        #expect(action == .done)
        #expect(!rig.clock.pauses.isEmpty)
        #expect(rig.target.string == "Send the report now.")
    }

    @Test func heldSwapFallsBackToTheClipboardAfterTheBudget() async {
        let clock = Clock()
        let rig = Rig.plain(clock: clock)
        rig.writer.apply(.commit(delta: "Send teh report now."))
        let guardRef = rig.run.typingGuard
        guardRef.noteUserActivity()
        clock.keepTyping = { guardRef.noteUserActivity() }
        let action = await rig.writer.finish(
            rawText: "Send teh report now.", cleanedText: "Send the report now.", delivery: .replace,
            retryingFor: FieldEditRun.finalHoldBudget, wait: { await rig.run.wait($0) })
        #expect(action == .copy("Send the report now."))
        #expect(clock.pauses.reduce(0, +) <= FieldEditRun.finalHoldBudget)
        #expect(rig.target.string == "Send teh report now.")
    }

    @Test func conflictAtStopKeepsTheClipboardFallback() async {
        let rig = Rig.plain()
        rig.writer.apply(.commit(delta: "Send teh report now."))
        rig.target.externalEdit(UTF16Range(location: 6, length: 2), with: "XX")  // the user changed the spot
        let action = rig.writer.finish(rawText: "Send teh report now.", cleanedText: "Send the report now.", delivery: .replace)
        #expect(action == .copy("Send the report now."))
    }
}
