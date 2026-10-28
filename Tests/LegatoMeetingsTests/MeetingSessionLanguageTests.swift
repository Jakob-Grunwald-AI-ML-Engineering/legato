import Foundation
import LegatoCore
import Synchronization
import Testing
@testable import LegatoMeetings

@Suite struct MeetingSessionLanguageTests {
    @Test func acceptedChangesPersistWithoutPreparingOrFinishingAgain() async throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(root: root)
        let engine = LanguageEngine()
        let source = ScriptedSource()
        let meeting = Meeting(title: "Language", date: Date(), engineID: "fake", locale: "en-US")
        let session = MeetingSession(meeting: meeting, sources: [MeetingSource(stream: .mic, source: source)],
            engine: engine, locale: Locale(identifier: "en-US"), store: store, sink: RecordingSink(), convert: { $0 }, clock: { ProcessInfo.processInfo.systemUptime })
        #expect(session.liveLanguageCodes == ["en", "de"])
        #expect(await session.setLanguage(Locale(identifier: "de-DE")) == false, "not before the session starts")
        try await session.start()
        try #require(await session.setLanguage(Locale(identifier: "de-DE")))
        #expect(await eventually { (try? await store.meeting(id: meeting.id))?.locale == "de-DE" })
        #expect(await session.setLanguage(Locale(identifier: "ja-JP")) == false)
        #expect(await session.setLanguage(nil))
        #expect(await eventually { (try? await store.meeting(id: meeting.id))?.locale == nil })
        source.push(tone(1600))
        #expect(source.startCount == 1)
        #expect(engine.base.preparedLocales.map { $0?.identifier } == ["en-US"])
        #expect(engine.base.finishCount == 0)
        let stopped = await session.stop()
        #expect(stopped.locale == nil)
        #expect(await session.setLanguage(Locale(identifier: "de-DE")) == false)
        #expect(engine.choices == ["de-DE", "auto"])
    }

    @Test func aChangeCompletingAfterStopCannotRewriteTheSavedMeeting() async throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(root: root)
        let (gate, release) = AsyncStream<Void>.makeStream()
        let engine = LanguageEngine(pause: gate)
        let meeting = Meeting(title: "Stopped", date: Date(), engineID: "fake", locale: "en-US")
        let session = MeetingSession(meeting: meeting, sources: [], engine: engine, store: store,
            sink: RecordingSink(), convert: { $0 }, clock: { ProcessInfo.processInfo.systemUptime })
        try await session.start()
        let change = Task { await session.setLanguage(Locale(identifier: "de-DE")) }
        #expect(await eventually { engine.waiting })
        _ = await session.stop()
        release.yield()
        release.finish()
        #expect(await change.value == false)
        #expect(try await store.meeting(id: meeting.id)?.locale == "en-US")
        #expect(engine.base.preparedLocales.count == 1)
    }

    @Test func anEngineWithoutTheCapabilityKeepsItsCurrentLocale() async throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(root: root)
        let engine = RecordingEngine()
        let meeting = Meeting(title: "Fixed", date: Date(), engineID: "fake", locale: "en-US")
        let session = MeetingSession(meeting: meeting, sources: [], engine: engine, store: store, sink: RecordingSink(), convert: { $0 }, clock: { ProcessInfo.processInfo.systemUptime })
        try await session.start()
        #expect(session.liveLanguageCodes == nil)
        #expect(await session.setLanguage(Locale(identifier: "de-DE")) == false)
        #expect(try await store.meeting(id: meeting.id)?.locale == "en-US")
        _ = await session.stop()
    }
}

private final class LanguageEngine: LiveLanguageConfigurableEngine, Sendable {
    let base = RecordingEngine()
    var id: String { base.id }
    let liveLanguageCodes = ["en", "de"]
    private let log = Mutex([String]())
    private let paused = Mutex(false)
    private let pause: AsyncStream<Void>?
    var waiting: Bool { paused.withLock { $0 } }
    init(pause: AsyncStream<Void>? = nil) { self.pause = pause }
    var choices: [String] { log.withLock { $0 } }
    func setLanguage(_ locale: Locale?) async -> Bool {
        guard locale == nil || liveLanguageCodes.contains(locale?.language.languageCode?.identifier ?? "") else { return false }
        if let pause {
            paused.withLock { $0 = true }
            for await _ in pause { break }
        }
        log.withLock { $0.append(locale?.identifier ?? "auto") }
        return true
    }
    func installAssets(locale: Locale?) -> AsyncStream<Double> { base.installAssets(locale: locale) }
    func prepare(locale: Locale?) async throws -> AudioFormatSpec { try await base.prepare(locale: locale) }
    func transcribe(_ input: AsyncStream<AudioChunk>) -> AsyncThrowingStream<TranscriptEvent, Error> { base.transcribe(input) }
    func finish() async throws { try await base.finish() }
}
