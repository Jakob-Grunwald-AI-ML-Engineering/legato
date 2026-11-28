import Foundation
import Testing
@testable import LegatoVoiceIdentity

@Suite struct VoiceProfileTests {
    private func temporaryRoot() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("voice-tests-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    private func unit(_ values: [Float]) -> [Float] {
        let norm = sqrt(values.reduce(0) { $0 + $1 * $1 }); return values.map { $0 / norm }
    }
    private func profile(_ situation: String, _ route: VoiceInputRoute, _ embedding: [Float] = [1, 0], revision: String = "r") -> VoiceProfile {
        VoiceProfile(situationID: situation, situationName: situation, route: route, embedding: embedding, date: Date(), revision: revision)
    }

    @Test func legacyProfileMigratesToAloneOnUnknownRouteOnce() async throws {
        let root = try temporaryRoot()
        let embedding = (0..<192).map { Float($0) / 192 }
        try JSONSerialization.data(withJSONObject: ["revision": VoiceIdentityService.modelRevision, "embedding": embedding])
            .write(to: root.appendingPathComponent("profile.json"))
        #expect(VoiceIdentityService.hasStoredProfile(at: root))
        let set = try await VoiceIdentityService(root: root).profileSet()
        #expect(set.profiles.count == 1)
        #expect(set.profiles[0].situationID == VoiceSituation.alone.id && set.profiles[0].route == .unknown)
        #expect(set.profiles[0].embedding == embedding && set.profiles[0].revision == VoiceIdentityService.modelRevision)
        #expect(set.matchable(revision: VoiceIdentityService.modelRevision).count == 1)
        // Rewritten as the profile set; the old file is gone, and a fresh service reads the same voice.
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("profile.json").path))
        #expect(VoiceIdentityService.hasStoredProfile(at: root))
        let reloaded = try await VoiceIdentityService(root: root).profileSet()
        #expect(reloaded.profiles.map(\.embedding) == [embedding] && reloaded.profiles.map(\.route) == [.unknown])
        #expect(abs(reloaded.profiles[0].date.timeIntervalSince(set.profiles[0].date)) < 1)
    }

    @Test func bestScoreIsTheMaximumCosineOverProfiles() {
        let office = unit([1, 0, 0]), car = unit([0, 1, 0]), tv = unit([1, 1, 0])
        let vector = unit([0.2, 1, 0])
        let score = VoiceProfileSet.bestScore(vector, among: [office, car, tv])
        let expected = zip(car, vector).reduce(Float(0)) { $0 + $1.0 * $1.1 }
        #expect(score == expected)
        #expect(VoiceProfileSet.bestScore(vector, among: []) == nil)
        // Vectors of another size are never compared.
        #expect(VoiceProfileSet.bestScore(vector, among: [[1, 0]]) == nil)
    }

    @Test func matchableSkipsOtherRevisionsSizesAndNonFiniteVectors() {
        let good = [Float](repeating: 0.1, count: 192)
        var bad = good; bad[3] = .nan
        let set = VoiceProfileSet(profiles: [profile("a", .unknown, good), profile("b", .unknown, good, revision: "old"),
                                             profile("c", .unknown, [1, 0]), profile("d", .unknown, bad)])
        #expect(set.matchable(revision: "r") == [good])
    }

    @Test func sameSettingAndRouteReplacesOtherRouteAdds() {
        let builtIn = VoiceInputRoute(kind: "builtIn", name: "iPhone Microphone")
        let builtInRenamed = VoiceInputRoute(kind: "builtIn", name: "MacBook Pro Microphone")
        let airPods = VoiceInputRoute(kind: "bluetooth", name: "AirPods Pro")
        var set = VoiceProfileSet()
        set.upsert(profile("office", builtIn, [1, 0]))
        set.upsert(profile("office", airPods, [0, 1]))
        set.upsert(profile("car", builtIn, [1, 0]))
        #expect(set.profiles.count == 3)
        set.upsert(profile("office", builtInRenamed, [0.6, 0.8]))
        set.upsert(profile("office", VoiceInputRoute(kind: "bluetooth", name: "airpods pro "), [0.8, 0.6]))
        #expect(set.profiles.count == 3)
        #expect(set.profiles.filter { $0.situationID == "office" }.map(\.embedding) == [[0.6, 0.8], [0.8, 0.6]])
        set.upsert(profile("office", VoiceInputRoute(kind: "bluetooth", name: "AirPods Max"), [1, 0]))
        #expect(set.profiles.count == 4)
    }

    @Test func customSettingsAreUniqueAndOnlyTheyCanBeDeletedWithTheirProfiles() throws {
        var set = VoiceProfileSet()
        #expect(set.situations.map(\.name) == ["Alone", "Office", "Train", "Car", "Home with TV on", "In bed"])
        let added = set.addSituation(named: "  Café ")
        let cafe = try #require(added)
        #expect(cafe.name == "Café" && cafe.isCustom)
        #expect(set.addSituation(named: "café") == nil)
        #expect(set.addSituation(named: "office") == nil)
        #expect(set.addSituation(named: "   ") == nil)
        set.upsert(profile(cafe.id, .unknown))
        set.upsert(profile("office", .unknown))
        set.removeSituation(id: "office")
        #expect(set.profiles.count == 2)
        set.removeSituation(id: cafe.id)
        #expect(set.profiles.map(\.situationID) == ["office"])
        #expect(set.situations.count == VoiceSituation.suggested.count)
    }

    @Test func sidecarAndWAVRoundTrip() throws {
        let root = try temporaryRoot()
        let store = VoiceRecordingStore(root: root.appendingPathComponent("Recordings"))
        let samples: [Float] = (0..<16000).map { sin(Float($0) / 20) * 0.5 }
        let sidecar = VoiceRecordingSidecar(kind: .setting, situationID: "tv", situationName: "Home with TV on",
                                            route: VoiceInputRoute(kind: "bluetooth", name: "AirPods Pro"),
                                            date: Date(timeIntervalSince1970: 1_800_000_000), language: "de",
                                            intervals: [.init(kind: .reading, startMs: 0, endMs: 600, prompt: "Hallo Welt."),
                                                        .init(kind: .quiet, startMs: 700, endMs: 1000)])
        let folder = try store.save(samples: samples, sidecar: sidecar)
        let entries = store.list()
        #expect(entries.count == 1)
        #expect(entries[0].sidecar == sidecar && entries[0].folder.lastPathComponent == folder.lastPathComponent)
        #expect(abs(entries[0].seconds - 1) < 0.001)
        let decoded = try VoiceWAV.decode(Data(contentsOf: folder.appendingPathComponent(VoiceRecordingStore.audioName)))
        #expect(decoded.sampleRate == 16000 && decoded.samples.count == samples.count)
        #expect(zip(decoded.samples, samples).allSatisfy { abs($0 - $1) < 0.0001 })
        let archive = try store.archive([folder], name: "voice-test-\(UUID().uuidString)")
        #expect(try Data(contentsOf: archive).prefix(2) == Data("PK".utf8))
        try? FileManager.default.removeItem(at: archive)
        try store.deleteAll()
        #expect(store.list().isEmpty)
    }

    @Test func scriptsPlanAMinuteOfSetupAndFortySecondsWithTwoQuietPauses() {
        for language in ["en", "de"] {
            let setup = VoiceReadingScript.firstSetup(language: language)
            #expect(setup.steps.allSatisfy { $0.prompt != nil })
            #expect(setup.plannedSeconds >= 60 && setup.plannedSeconds < 75)
            let first = VoiceReadingScript.setting(language: language, cursor: 0)
            let reading = first.steps.filter { $0.prompt != nil }.reduce(0) { $0 + $1.seconds }
            #expect(reading >= 40 && reading < 55)
            #expect(first.steps.filter { $0.prompt == nil }.map(\.seconds) == [10, 10])
            #expect(first.steps.first?.prompt != nil && first.steps.last?.prompt != nil)
            // Settings never reuse the setup sentences, and the next recording moves on to other sentences.
            #expect(Set(first.steps.compactMap(\.prompt)).isDisjoint(with: setup.steps.compactMap(\.prompt)))
            let second = VoiceReadingScript.setting(language: language, cursor: first.nextCursor)
            #expect(Set(first.steps.compactMap(\.prompt)).isDisjoint(with: second.steps.compactMap(\.prompt)))
        }
        #expect(VoiceReadingPrompts.language(preferred: ["de-DE", "en"]) == "de")
        #expect(VoiceReadingPrompts.language(preferred: ["en-GB"]) == "en")
        #expect(VoiceReadingPrompts.language(preferred: ["fr-FR"]) == "en")
    }
}
