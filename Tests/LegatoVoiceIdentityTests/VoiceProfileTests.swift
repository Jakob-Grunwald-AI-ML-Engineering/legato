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
            #expect(abs(setup.plannedSeconds - VoiceReadingScript.setupReadingSeconds) <= 5)
            let first = VoiceReadingScript.setting(language: language, cursor: 0)
            let reading = first.steps.filter { $0.prompt != nil }.reduce(0) { $0 + $1.seconds }
            #expect(abs(reading - VoiceReadingScript.settingReadingSeconds) <= 5)
            #expect(first.steps.filter { $0.prompt == nil }.map(\.seconds) == [10, 10])
            #expect(first.steps.first?.prompt != nil && first.steps.last?.prompt != nil)
            // Reading steps run on past their estimate before moving on by themselves; quiet steps do not.
            #expect(first.steps.allSatisfy {
                $0.maximumSeconds == ($0.prompt == nil ? $0.seconds : $0.seconds * VoiceReadingScript.readingTolerance)
            })
        }
        #expect(VoiceReadingPrompts.language(preferred: ["de-DE", "en"]) == "de")
        #expect(VoiceReadingPrompts.language(preferred: ["en-GB"]) == "en")
        #expect(VoiceReadingPrompts.language(preferred: ["fr-FR"]) == "en")
    }

    @Test func successiveSettingRecordingsReadOtherSentencesThanEachOtherAndTheSetup() {
        for language in ["en", "de"] {
            let setup = Set(VoiceReadingScript.firstSetup(language: language).steps.compactMap(\.prompt))
            let pool = VoiceReadingPrompts.rotation(language: language).count
            var cursor = 0, seen = Set<String>(), read = 0
            // Alone again, Car, a custom setting…: each starts where the last one stopped, until the pool comes round.
            while read + 6 <= pool {
                let script = VoiceReadingScript.setting(language: language, cursor: cursor)
                let prompts = script.steps.compactMap(\.prompt)
                #expect(Set(prompts).isDisjoint(with: setup))
                #expect(Set(prompts).isDisjoint(with: seen))
                seen.formUnion(prompts); read += prompts.count
                #expect(script.nextCursor == (cursor + prompts.count) % pool)
                cursor = script.nextCursor
            }
            #expect(seen.count == read && read >= pool - 6)
        }
    }

    @Test func enrollmentKeepsARecordingOnlyWhenItsProfileIsSaved() async throws {
        let root = try temporaryRoot()
        let service = VoiceIdentityService(root: root)
        func kept(_ samples: [Float]) -> (samples: [Float], sidecar: VoiceRecordingSidecar) {
            (samples, VoiceRecordingSidecar(kind: .setting, situationID: "car", situationName: "Car", route: .unknown, language: "en",
                                            intervals: [.init(kind: .reading, startMs: 0, endMs: Double(samples.count) / 16)]))
        }
        // A silent recording is rejected and leaves nothing behind.
        let silent = [Float](repeating: 0, count: 10 * 16000)
        await #expect(throws: VoiceIdentityError.self) {
            try await service.enroll(reading: [silent], situation: .alone, route: .unknown, keeping: kept(silent))
        }
        #expect(service.recordings.list().isEmpty)
        // A recording that passes the checks but cannot become a profile (no model in this folder) is not kept either.
        let speech = (0..<(10 * 16000)).map { sin(Float($0) / 7) * 0.2 }
        await #expect(throws: VoiceIdentityError.self) {
            try await service.enroll(reading: [speech], situation: .alone, route: .unknown, keeping: kept(speech))
        }
        #expect(service.recordings.list().isEmpty)
        #expect(!VoiceIdentityService.hasStoredProfile(at: root))
    }
}

/// The recording's schedule runs on recorded audio, with reading steps that end when the reader stops.
@Suite struct VoiceCaptureScheduleTests {
    private let rate = 16000.0
    private func speech(_ seconds: Double, level: Float = 0.1) -> [Float] {
        (0..<Int(seconds * 16000)).map { sin(Float($0) * 0.09) * level * 1.41 }
    }
    private func silence(_ seconds: Double) -> [Float] { [Float](repeating: 0.0005, count: Int(seconds * 16000)) }
    private func script(_ steps: [VoiceScriptStep]) -> VoiceReadingScript { VoiceReadingScript(language: "en", steps: steps, nextCursor: 0) }

    @Test func quietStepsLastTheirAudioTimeAndLaterAudioIsNotTaken() {
        var schedule = VoiceCaptureSchedule(script: script([.init(kind: .quiet, seconds: 10), .init(kind: .quiet, seconds: 10)]))
        // However the audio arrives (tiny chunks, one large burst), the steps end at 10 s and 20 s of audio.
        for _ in 0..<500 { schedule.consume(silence(0.01)) }
        #expect(schedule.stepIndex == 0 && schedule.quietRemaining == 5)
        let taken = schedule.consume(silence(30))
        #expect(schedule.isFinished && taken == Int(15 * rate) && schedule.sampleCount == Int(20 * rate))
        #expect(schedule.intervals.map(\.kind) == [.quiet, .quiet])
        #expect(schedule.intervals.map(\.endMs) == [10_000, 20_000])
        // A quiet label starts after the settle second, so a late last word is not called background.
        #expect(schedule.intervals.map(\.startMs) == [1_000, 11_000])
        #expect(schedule.progress == 1)
    }

    @Test func aReadingStepEndsWhenTheReaderStopsNotOnAShortPause() {
        var schedule = VoiceCaptureSchedule(script: script([.init(kind: .reading("One."), seconds: 8), .init(kind: .reading("Two."), seconds: 8)]))
        schedule.consume(silence(0.3))
        schedule.consume(speech(2.5)); schedule.consume(silence(0.6)); schedule.consume(speech(3))
        // Speech with a breath in it keeps the sentence going.
        #expect(schedule.stepIndex == 0)
        schedule.consume(silence(1.5))
        // About 1.2 s of silence after the sentence moves on: 0.3 + 2.5 + 0.6 + 3 + 1.2 s.
        #expect(schedule.stepIndex == 1)
        let end = schedule.intervals[0].endMs
        #expect(abs(end - 7_600) <= 40)
        #expect(schedule.intervals[0] == .init(kind: .reading, startMs: 0, endMs: end, prompt: "One."))
    }

    @Test func anEarlyPauseDoesNotEndASentenceBeforeHalfItsEstimate() {
        var schedule = VoiceCaptureSchedule(script: script([.init(kind: .reading("Long."), seconds: 10), .init(kind: .quiet, seconds: 10)]))
        schedule.consume(speech(1)); schedule.consume(silence(2.5))
        #expect(schedule.stepIndex == 0)
        schedule.consume(silence(2))
        // Half the estimate (5 s) has passed and the reader is silent: on to the pause.
        #expect(schedule.stepIndex == 1 && abs(schedule.intervals[0].endMs - 5_000) <= 40)
    }

    @Test func steadyNoiseRunsAReadingStepToItsTolerantMaximum() {
        var schedule = VoiceCaptureSchedule(script: script([.init(kind: .reading("Car."), seconds: 9), .init(kind: .quiet, seconds: 10)]))
        // A loud, steady room (the TV on) never reads as the reader stopping; the step still ends.
        schedule.consume(speech(13, level: 0.05))
        #expect(schedule.stepIndex == 0)
        schedule.consume(speech(2, level: 0.05))
        #expect(schedule.stepIndex == 1)
        #expect(abs(schedule.intervals[0].endMs - 9 * VoiceReadingScript.readingTolerance * 1000) <= 40)
    }

    @Test func aQuietPauseLearnsANoisyRoomSoTheNextSentenceEndsWhenTheReaderStops() {
        var schedule = VoiceCaptureSchedule(script: script([.init(kind: .quiet, seconds: 10), .init(kind: .reading("Car."), seconds: 8),
                                                           .init(kind: .quiet, seconds: 10)]))
        schedule.consume(speech(10, level: 0.02))
        #expect(schedule.stepIndex == 1)
        schedule.consume(speech(3, level: 0.2)); schedule.consume(speech(1.5, level: 0.02))
        #expect(schedule.stepIndex == 2)
        #expect(abs(schedule.intervals[1].endMs - 14_200) <= 40)
    }

    @Test func nextSentenceEndsTheSentenceButNotInItsFirstSecond() {
        var schedule = VoiceCaptureSchedule(script: script([.init(kind: .reading("A."), seconds: 8), .init(kind: .reading("B."), seconds: 8),
                                                           .init(kind: .quiet, seconds: 10)]))
        schedule.consume(speech(2))
        schedule.requestAdvance(); schedule.consume(speech(0.1))
        #expect(schedule.stepIndex == 1)
        // A double tap does not skip the next sentence.
        schedule.requestAdvance(); schedule.consume(speech(0.5))
        #expect(schedule.stepIndex == 1)
        schedule.consume(speech(1)); schedule.requestAdvance(); schedule.consume(speech(0.05))
        #expect(schedule.stepIndex == 2)
        // Next sentence does nothing in a pause.
        schedule.requestAdvance(); schedule.consume(silence(1))
        #expect(schedule.stepIndex == 2 && schedule.quietRemaining == 9)
    }

    @Test func progressOnlyMovesForward() {
        var schedule = VoiceCaptureSchedule(script: VoiceReadingScript.setting(language: "en", cursor: 0))
        var last = 0.0
        while !schedule.isFinished {
            schedule.consume(speech(0.25))
            #expect(schedule.progress >= last)
            last = schedule.progress
        }
        #expect(last == 1)
    }
}
