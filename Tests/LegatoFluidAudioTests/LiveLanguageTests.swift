import Foundation
import LegatoCore
import Synchronization
import Testing
@testable import LegatoFluidAudio

@Suite struct LiveLanguageTests {
    @Test func variantsOfferOnlyTheirOwnVocabulary() {
        let models = makeManager(id: "unused", installer: FakeInstaller())
        #expect(NemotronEngine(variant: .latin, models: models).liveLanguageCodes == ["en", "es", "fr", "it", "pt", "de"])
        #expect(NemotronEngine(variant: .multilingual, models: models).liveLanguageCodes == ["en", "es", "fr", "it", "pt", "de", "zh", "ja"])
    }

    @Test func anUnpreparedEngineNeverLoadsModelsToChangeLanguage() async {
        let models = makeManager(id: "unused", installer: FakeInstaller())
        let engine = NemotronEngine(variant: .latin, models: models)
        #expect(await engine.setLanguage(Locale(identifier: "de-DE")) == false)
        #expect(await engine.setLanguage(Locale(identifier: "ja-JP")) == false)
        #expect(await engine.setLanguage(nil) == false)
    }

    @Test func theLatestChoiceBeforeSpeechWins() async throws {
        let updates = LiveLanguageUpdates()
        updates.request(Locale(identifier: "de-DE"))
        updates.request(Locale(identifier: "fr-FR"))
        let backend = ScriptedBackend(wordsAt: [1600: "hello"])
        var driver = SegmentDriver(endpointer: SilenceEndpointer(silenceMs: 100), mapper: PartialEventMapper(),
                                   clamp: LanguageClamp(preferred: []), languageUpdates: updates)
        try await driver.run(chunks([(1600, 0.1), (1600, 0)]), backend: backend) { _ in }
        #expect(backend.snapshot.applied == ["fr-FR"])
    }

    @Test func aHintBeforeFirstSpeechUsesTheExistingBackend() async throws {
        let updates = LiveLanguageUpdates()
        updates.request(Locale(identifier: "de-DE"))
        let backend = ScriptedBackend(wordsAt: [1600: "hello"])
        var driver = SegmentDriver(endpointer: SilenceEndpointer(silenceMs: 100), mapper: PartialEventMapper(),
                                   clamp: LanguageClamp(preferred: []), languageUpdates: updates)
        var events: [TranscriptEvent] = []
        try await driver.run(chunks([(1600, 0.1), (1600, 0)]), backend: backend) { events.append($0) }
        #expect(backend.snapshot.applied == ["de-DE"])
        #expect(events.filter(\.isFinal).map(\.range) == [0..<0.2])
        #expect(backend.snapshot.processCalls == 2)
    }

    @Test func changesWaitForTheBoundaryAndAutoClearsTheOldClamp() async throws {
        let updates = LiveLanguageUpdates()
        let backend = SwitchingBackend(updates: updates)
        var driver = SegmentDriver(endpointer: SilenceEndpointer(silenceMs: 100), mapper: PartialEventMapper(),
            clamp: LanguageClamp(preferred: [Locale(identifier: "de-DE"), Locale(identifier: "en-US")]), languageUpdates: updates)
        var events: [TranscriptEvent] = []
        try await driver.run(chunks([(1600, 0.1), (1600, 0), (1600, 0.1), (1600, 0), (1600, 0.1), (1600, 0)]),
                             backend: backend) { events.append($0) }
        #expect(backend.hintsAtProcess == [[], [], ["fr-FR"], ["fr-FR"], ["fr-FR", "auto"], ["fr-FR", "auto"]])
        #expect(backend.base.snapshot.applied == ["fr-FR", "auto"], "the old preferred languages must never repin")
        #expect(events.filter(\.isFinal).map(\.range) == [0..<0.2, 0.2..<0.4, 0.4..<0.6])
    }
}

private final class SwitchingBackend: StreamingBackend, Sendable {
    let base = ScriptedBackend(wordsAt: [1600: "word"], detected: "zh-CN")
    let updates: LiveLanguageUpdates
    private let calls = Mutex([[String]]())
    var hintsAtProcess: [[String]] { calls.withLock { $0 } }
    init(updates: LiveLanguageUpdates) { self.updates = updates }
    func process(_ samples: [Float]) async throws {
        let count = calls.withLock { $0.append(base.snapshot.applied); return $0.count }
        if count == 1 { updates.request(Locale(identifier: "fr-FR")) }
        if count == 3 { updates.request(nil) }
        try await base.process(samples)
    }
    func partial() async -> String { await base.partial() }
    func commit() async throws -> String { try await base.commit() }
    func detectedLanguage() async -> String? { await base.detectedLanguage() }
    func applyLanguage(_ hint: String) async { await base.applyLanguage(hint) }
}
