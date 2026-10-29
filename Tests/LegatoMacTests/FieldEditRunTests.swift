import Foundation
import LegatoAppServices
import LegatoCore
import LegatoFieldEdit
import Testing
@testable import LegatoMac

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
                agent: FieldRunAgent(agent, replan: { await agent.replan() }, finish: { await agent.finish() }),
                now: { clock.now }, pause: { seconds in
                    clock.pauses.append(seconds)
                    clock.now += seconds + 0.01
                    clock.keepTyping?()
                })!
            let writer = FieldWriter(target: target, mode: mode, channel: run.channel)
            run.attach(writer: writer)
            await run.start()
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
        let fallback = FieldEditRun.fallbackText(shown: rig.writer.shownText, unapplied: outcome.unapplied)
        #expect(fallback == "Send the report")
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
