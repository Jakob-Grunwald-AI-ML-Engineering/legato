import Foundation
import Synchronization
import Testing
@testable import LegatoCore

/// A post-processor with a scripted answer that records what it was asked.
final class ScriptedProcessor: TranscriptPostProcessor {
    enum Answer: Sendable {
        case text(String)
        case fail
    }

    let id = "scripted"
    private let answer: Answer
    private let calls = Mutex<[(text: String, locale: String)]>([])

    init(_ answer: Answer) { self.answer = answer }

    var received: [(text: String, locale: String)] { calls.withLock { $0 } }

    func process(_ text: String, locale: Locale) async throws -> String {
        calls.withLock { $0.append((text, locale.identifier)) }
        switch answer {
        case .text(let out): return out
        case .fail: throw TestError(tag: "cleanup")
        }
    }
}

@MainActor
private func session(
    processor: (any TranscriptPostProcessor)?, script: [TranscriptEvent], history: MemoryHistory
) -> DictationSession {
    let log = EventLog()
    let engine = FakeEngine(log: log)
    engine.set(script: script)
    return DictationSession(
        engine: engine, source: FakeSource(log: log), sessionControl: FakeSessionControl(log: log),
        history: history, postProcessor: processor, now: { Date(timeIntervalSince1970: 100) })
}

@MainActor
@Suite struct SessionPostProcessingTests {
    private let script = [TranscriptEvent(text: "um hello world ", isFinal: true)]

    @Test func stopSavesTheProcessedTextAndKeepsTheRawText() async throws {
        let history = MemoryHistory()
        let processor = ScriptedProcessor(.text("Hello, world."))
        let s = session(processor: processor, script: script, history: history)
        try await s.start(locale: Locale(identifier: "de_DE"))
        let entry = try #require(try await s.stop())
        #expect(entry.text == "Hello, world.")
        #expect(entry.rawText == "um hello world")
        #expect(await history.entries == [entry])
        // The committed text, trimmed, in the run's locale.
        #expect(processor.received.map(\.text) == ["um hello world"])
        #expect(processor.received.map(\.locale) == ["de_DE"])
    }

    @Test func aThrowingProcessorKeepsTheRawText() async throws {
        let history = MemoryHistory()
        let s = session(processor: ScriptedProcessor(.fail), script: script, history: history)
        try await s.start()
        let entry = try #require(try await s.stop())
        #expect(entry.text == "um hello world")
        #expect(entry.rawText == nil)
        #expect(await history.entries.map(\.text) == ["um hello world"])
    }

    @Test(arguments: ["", "   \n"])
    func anEmptyResultKeepsTheRawText(result: String) async throws {
        let s = session(processor: ScriptedProcessor(.text(result)), script: script, history: MemoryHistory())
        try await s.start()
        let entry = try #require(try await s.stop())
        #expect(entry.text == "um hello world")
        #expect(entry.rawText == nil)
    }

    @Test func anUnchangedResultHasNoRawText() async throws {
        let s = session(processor: ScriptedProcessor(.text("um hello world")), script: script, history: MemoryHistory())
        try await s.start()
        let entry = try #require(try await s.stop())
        #expect(entry.text == "um hello world")
        #expect(entry.rawText == nil)
    }

    @Test func theProcessedTextIsTrimmed() async throws {
        let s = session(processor: ScriptedProcessor(.text("  Hello.\n")), script: script, history: MemoryHistory())
        try await s.start()
        let entry = try #require(try await s.stop())
        #expect(entry.text == "Hello.")
        #expect(entry.rawText == "um hello world")
    }

    @Test func nothingRecognizedNeverCallsTheProcessor() async throws {
        let processor = ScriptedProcessor(.text("Invented."))
        let s = session(processor: processor, script: [], history: MemoryHistory())
        try await s.start()
        #expect(try await s.stop() == nil)
        #expect(processor.received.isEmpty)
    }

    @Test func partialEntryStaysRaw() async throws {
        let processor = ScriptedProcessor(.text("Hello, world."))
        let s = session(processor: processor, script: script, history: MemoryHistory())
        try await s.start()
        #expect(await eventually { s.partialEntry() != nil })
        let partial = try #require(s.partialEntry())
        #expect(partial.text == "um hello world")
        #expect(partial.rawText == nil)
        #expect(processor.received.isEmpty)
        _ = try await s.stop()
    }

    @Test func withoutAProcessorTheEntryIsRaw() async throws {
        let s = session(processor: nil, script: script, history: MemoryHistory())
        try await s.start()
        let entry = try #require(try await s.stop())
        #expect(entry.text == "um hello world")
        #expect(entry.rawText == nil)
    }
}

@Suite struct DictationEntryRawTextTests {
    @Test func anOldLineWithoutRawTextDecodes() throws {
        let line = #"{"id":"6F1C3A52-8E0B-4D35-9C55-2B7C6E9D1F00","date":100000,"text":"hello","localeIdentifier":"en_US","engineID":"fake","duration":2}"#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        let entry = try decoder.decode(DictationEntry.self, from: Data(line.utf8))
        #expect(entry.text == "hello")
        #expect(entry.rawText == nil)
    }

    @Test func rawTextSurvivesTheHistoryFile() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("legato-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("history.jsonl")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = JSONLHistoryStore(fileURL: url)
        let entry = DictationEntry(
            date: Date(timeIntervalSince1970: 1), text: "Hello.", rawText: "um hello", localeIdentifier: "en_US",
            engineID: "fake", duration: 1)
        try await store.append(entry)
        #expect(try await store.recent(limit: 1) == [entry])
    }
}

@Suite struct CleanupDeliveryTests {
    /// The raw values persist in the settings: they must not change.
    @Test func rawValuesAreStable() {
        #expect(CleanupDelivery.allCases.map(\.rawValue) == ["replace", "clipboard", "hold", "live"])
    }

    @Test func onlyHoldKeepsTheFieldFreeWhileListening() {
        #expect(CleanupDelivery.replace.streamsIntoField)
        #expect(CleanupDelivery.clipboard.streamsIntoField)
        #expect(!CleanupDelivery.hold.streamsIntoField)
    }

    @Test func liveStreamsIntoTheField() {
        #expect(CleanupDelivery.live.streamsIntoField)
    }
}

@MainActor
@Suite struct CoordinatorFinishingTests {
    @Test func theSinkHearsTheRunFinishingBeforeItEnds() async throws {
        let r = CoordinatorRig(script: [TranscriptEvent(text: "hello ", isFinal: true)])
        r.attachSink()
        #expect(await r.coordinator.toggle() == .started)
        #expect(await r.coordinator.toggle() == .stopped("hello"))
        let ev = r.log.events
        let finishing = try #require(ev.firstIndex(of: "finishing:sink"))
        let engineFinish = try #require(ev.firstIndex(of: "engine.finish"))
        let ended = try #require(ev.firstIndex(of: "sink.runEnded"))
        #expect(finishing < engineFinish && engineFinish < ended)
        #expect(r.log.count("finishing:sink") == 1)
    }
}
