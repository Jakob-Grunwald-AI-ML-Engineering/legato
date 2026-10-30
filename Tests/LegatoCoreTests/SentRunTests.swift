import Foundation
import Testing
@testable import LegatoCore

private func final(_ text: String) -> TranscriptEvent { TranscriptEvent(text: text, isFinal: true) }

@MainActor
@Suite struct SentRunTests {
    private func rig(
        _ processor: ScriptedProcessor, script: [TranscriptEvent]
    ) -> (DictationCoordinator, FakeSink, FakeClipboard, FakeEngine) {
        let log = EventLog()
        let engine = FakeEngine(log: log)
        engine.set(script: script)
        let history = MemoryHistory()
        let clipboard = FakeClipboard(log: log)
        let coordinator = DictationCoordinator(
            activity: FakeActivity(log: log), clipboard: clipboard, readiness: FakeReadiness(),
            history: history,
            makeSession: { _, _ in
                DictationSession(
                    engine: engine, source: FakeSource(log: log), sessionControl: FakeSessionControl(log: log),
                    history: history, postProcessor: processor)
            })
        let sink = FakeSink(log: log)
        coordinator.sink = sink
        return (coordinator, sink, clipboard, engine)
    }

    @Test func theWholeTextIsCleanedOnceAtTheStopAcrossSegments() async throws {
        let processor = ScriptedProcessor(.text("Hello world, how are you?"))
        let (coordinator, sink, _, _) = rig(processor, script: [final("hello world "), final("how are you ")])
        #expect(await coordinator.toggle() == .started)
        #expect(await eventually { sink.updates.last?.committed == "hello world how are you " })
        #expect(await coordinator.toggle() == .stopped("Hello world, how are you?"))
        #expect(processor.received.map(\.text) == ["hello world how are you"])
        #expect(sink.ended.last?.committed == "hello world how are you ", "the run's committed text stays raw")
    }

    @Test func aSendReportedWhileTheRunEndsStillKeepsTheClipboardUntouched() async throws {
        let processor = ScriptedProcessor(.text("Hello world."))
        let (coordinator, sink, clipboard, engine) = rig(processor, script: [])
        sink.finalApplied = false
        #expect(await coordinator.toggle() == .started)
        engine.emit(final("hello world "), run: 0)
        #expect(await eventually { sink.updates.last?.committed == "hello world " })
        let runID = try #require(sink.started.last?.id.uuidString)
        // The session is done; the keyboard's report arrives while the sink waits for the final state.
        sink.onRunEnded = { coordinator.runTextSent(runID: runID) }
        #expect(await coordinator.toggle() == .stopped("Hello world."))
        #expect(clipboard.written.isEmpty, "the message was sent: nothing to copy")
    }

    @Test func aSentRunIsNeverCopiedAndAnotherRunsReportIsIgnored() async throws {
        let processor = ScriptedProcessor(.text("Hello world. How are you?"))
        let (coordinator, sink, clipboard, engine) = rig(processor, script: [])
        sink.finalApplied = false // the keyboard did not confirm (it was hidden after the send)
        #expect(await coordinator.toggle() == .started)
        engine.emit(final("hello world "), run: 0)
        #expect(await eventually { sink.updates.last?.committed == "hello world " })
        let runID = try #require(sink.started.last?.id.uuidString)
        coordinator.runTextSent(runID: "someone-else") // ignored: this run is still copied when unconfirmed
        engine.emit(final("how are you "), run: 0)
        #expect(await eventually { sink.updates.last?.committed == "hello world how are you " })
        coordinator.runTextSent(runID: runID)
        #expect(await coordinator.toggle() == .stopped("Hello world. How are you?"))
        #expect(clipboard.written.isEmpty, "a sent run is never copied")
    }
}
