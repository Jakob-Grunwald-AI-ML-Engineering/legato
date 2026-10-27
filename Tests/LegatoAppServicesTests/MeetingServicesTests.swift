import Foundation
import LegatoClaude
import LegatoCore
import LegatoFluidAudio
import LegatoMLX
import LegatoMeetings
import LegatoModels
import Synchronization
import Testing
@testable import LegatoAppServices

/// Installs at once and is installed ever after.
private final class InstantInstaller: ModelInstaller {
    let folderName: String
    init(folderName: String) { self.folderName = folderName }
    func installFolder(root: URL) -> URL { root.appending(path: folderName, directoryHint: .isDirectory) }
    func isInstalled(root: URL) async -> Bool {
        FileManager.default.fileExists(atPath: installFolder(root: root).appending(path: "complete").path)
    }
    func install(root: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        let folder = installFolder(root: root)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: folder.appending(path: "complete"))
    }
    func warm(root: URL) async throws {}
}

private final class FakeLLM: LLMBackend {
    let id: String
    let calls = Mutex(0)
    init(id: String) { self.id = id }
    var maxPromptCharacters: Int? { nil }
    var availability: LLMAvailability { get async { .available } }
    func respond(instructions: String, prompt: String) async throws -> String {
        calls.withLock { $0 += 1 }
        return "## Summary\n\(id)"
    }
}

private func sameInstance(_ a: any DictationEngine, _ b: (any DictationEngine)?) -> Bool {
    guard let b, let x = a as? AnyObject, let y = b as? AnyObject else { return false }
    return x === y
}

private let nemotron = "nemotron-multilingual-560"
private let parakeetEOU = "parakeet-eou-320"

private final class SamplerBox: Sendable {
    private let state: Mutex<IdleSample>
    init(_ sample: IdleSample) { state = Mutex(sample) }
    var value: IdleSample { get { state.withLock { $0 } } set { state.withLock { $0 = newValue } } }
}

@MainActor
private struct Rig {
    let root = FileManager.default.temporaryDirectory.appending(path: "legato-meeting-services-\(UUID().uuidString)")
    let models: ModelServices
    let modelDefaults: UserDefaults
    let store: MeetingStore
    let settings: MeetingSettings
    let keys = InMemoryAPIKeyStore(apiKey: "sk-test")
    let foundation = FakeLLM(id: "fake-fm")
    let claude = FakeLLM(id: "claude")

    init() {
        let suite = "legato.meeting-services.\(UUID().uuidString)"
        let catalog = ModelServices(root: root, defaults: UserDefaults(suiteName: suite + ".a")!, platform: .macOS).catalog
        let installers = Dictionary(uniqueKeysWithValues: catalog.map { ($0.id, InstantInstaller(folderName: $0.id)) })
        modelDefaults = UserDefaults(suiteName: suite + ".b")!
        models = ModelServices(root: root, defaults: modelDefaults, platform: .macOS, installers: installers)
        store = MeetingStore(root: root.appending(path: "Meetings"))
        settings = MeetingSettings(defaults: UserDefaults(suiteName: suite + ".c")!)
    }

    let load = SamplerBox(IdleSample(cpuLoad: 0.9, secondsSinceInput: 1))

    func services(claudeBackend: (any LLMBackend)? = nil) -> MeetingServices {
        let load = self.load
        return MeetingServices(
            models: models, store: store, settings: settings, keyStore: keys,
            cleanup: CleanupRegistry(models: models.manager, foundationModels: foundation),
            claudeBackend: claudeBackend, sampler: { load.value }, immediateProcessing: false, pollInterval: nil)
    }

    func install(_ id: String) async {
        for await _ in await models.manager.install(id) {}
    }

    func pick(_ id: String, role: ModelRole = .liveDictation) async throws {
        try await models.manager.select(id, role: role)
    }
}

@MainActor @Suite struct MeetingServicesTests {
    // MARK: Engines

    @Test func oneEngineServesTheWholeMeetingEvenWhenEOUIsPicked() async throws {
        let rig = Rig()
        try await rig.pick(parakeetEOU)
        for platform in [ModelPlatform.macOS, .iOS] {
            let engines = await rig.services().engines(for: platform)
            #expect(engines.engine.id == parakeetEOU, "no more Apple Speech rule for EOU")
            #expect(engines.engineID == parakeetEOU)
            #expect(engines.fallbackReason == nil)
        }
    }

    @Test func oneNemotronInstanceHearsTheMix() async throws {
        let rig = Rig()
        try await rig.pick(nemotron)
        let engines = await rig.services().engines(for: .macOS)
        #expect(engines.engine.id == nemotron)
        #expect(engines.fallbackReason == nil)
    }

    @Test func nothingPickedMeansAppleSpeechWithoutAReason() async {
        let rig = Rig()
        for platform in [ModelPlatform.macOS, .iOS] {
            let engines = await rig.services().engines(for: platform)
            #expect(engines.engine.id == "apple-speech")
            #expect(engines.fallbackReason == nil)
        }
    }

    @Test func aPickedModelThatIsNotInstalledSaysWhyAppleSpeechRuns() async throws {
        let rig = Rig()
        SelectionStore(defaults: rig.modelDefaults).set("nemotron-multilingual-1120", for: .liveDictation)
        let engines = await rig.services().engines(for: .macOS)
        #expect(engines.engine.id == "apple-speech")
        #expect(engines.fallbackReason?.contains("not installed") == true)
    }

    @Test func enginesPrepareForTheSingleChosenLanguageElseNone() async throws {
        let rig = Rig()
        try await rig.pick(nemotron)
        #expect(await rig.services().engines(for: .macOS).locale == nil)

        rig.models.engineSettings.preferredLocales = [Locale(identifier: "de-DE")]
        #expect(await rig.services().engines(for: .macOS).locale == Locale(identifier: "de-DE"))
        #expect(await rig.services().engines(for: .iOS).locale == Locale(identifier: "de-DE"))

        rig.models.engineSettings.preferredLocales = [Locale(identifier: "de-DE"), Locale(identifier: "en-US")]
        #expect(await rig.services().engines(for: .macOS).locale == nil)
    }

    @Test func aMeetingLanguageOverridesTheGlobalLanguagesForThatMeetingOnly() async throws {
        let rig = Rig()
        try await rig.pick(nemotron)
        rig.models.engineSettings.preferredLocales = [Locale(identifier: "de-DE"), Locale(identifier: "en-US")]
        let french = await rig.services().engines(for: .macOS, locale: Locale(identifier: "fr-FR"))
        #expect(french.locale == Locale(identifier: "fr-FR"))
        #expect(french.preferredLocales.map(\.identifier) == ["fr-FR"])
        #expect(french.engine.id == nemotron)
        #expect(rig.models.engineSettings.preferredLocales.map(\.identifier) == ["de-DE", "en-US"])
    }

    @Test func aNewMeetingCarriesItsLanguageAndTheDefaultTemplate() async throws {
        let rig = Rig()
        let mine = rig.settings.addTemplate(name: "Mine", prompt: "p")
        rig.settings.defaultTemplateID = mine.id
        let services = rig.services()
        let german = await services.engines(locale: Locale(identifier: "de-DE"))
        let meeting = services.newMeeting(title: "Sync", engines: german)
        #expect(meeting.locale == "de-DE")
        #expect(meeting.templateID == mine.id)
        #expect(meeting.engineID == "apple-speech")
        let auto = services.newMeeting(title: "Auto", engines: await services.engines())
        #expect(auto.locale == nil, "Auto leaves the language to the engine")
    }

    @Test func theLiveDiarizerComesWithTheEngineWhenOnAndInstalled() async throws {
        let rig = Rig()
        #expect(await rig.services().engines().diarizer == nil, "not installed")
        await rig.install(FluidAudioModels.sortformerID)
        #expect(rig.settings.liveDiarization)
        #expect(await rig.services().engines().diarizer != nil)
        rig.settings.liveDiarization = false
        #expect(await rig.services().engines().diarizer == nil, "switched off")
    }

    @Test func theMicEnhancerFollowsTheEchoAndNoiseChoice() async throws {
        let rig = Rig()
        let missing = await rig.services().engines(for: .macOS)
        #expect(missing.enhancer == nil)
        #expect(missing.cleaningNote?.contains("raw microphone") == true, "LocalVQE is chosen but not downloaded")

        await rig.install(FluidAudioModels.localVqeID)
        let on = await rig.services().engines(for: .macOS)
        #expect(on.enhancer != nil && on.cleaningNote == nil && !on.voiceProcessing)
        #expect(await rig.services().engines(for: .iOS).enhancer != nil, "the phone denoises too")

        rig.settings.echoNoise = .appleVoiceProcessing
        let apple = await rig.services().engines(for: .macOS)
        #expect(apple.enhancer == nil && apple.voiceProcessing && apple.cleaningNote == nil)
        #expect(await rig.services().engines(for: .iOS).voiceProcessing == false, "Apple voice processing is a Mac feature")

        rig.settings.echoNoise = .off
        let off = await rig.services().engines(for: .macOS)
        #expect(off.enhancer == nil && !off.voiceProcessing && off.cleaningNote == nil)
    }

    // MARK: Backends

    @Test func theSummaryBackendComesFromTheCleanupRegistryAndIsNeverClaude() async throws {
        let rig = Rig()
        for choice in CleanupBackendChoice.allCases {
            rig.settings.backend = choice
            let backend = await rig.services(claudeBackend: rig.claude).summaryBackend()
            #expect(backend?.id == "fake-fm", "\(choice)")
        }
    }

    @Test func noPostPassModelMeansNoTranscriber() async {
        let rig = Rig()
        #expect(await rig.services().postPassTranscriber() == nil)
    }

    @Test func claudeIsTheClaudeBackend() {
        let rig = Rig()
        #expect(rig.services().claudeBackend() is ClaudeBackend)
    }

    // MARK: Chains

    private func seedProcessing(_ rig: Rig) async throws -> UUID {
        let id = UUID()
        try await rig.store.create(Meeting(id: id, title: "Sync", date: Date(), duration: 10, engineID: "live", state: .processing))
        try await rig.store.appendSegment(MeetingSegment(stream: .mic, text: "we ship friday", start: 0, end: 3), to: id)
        return id
    }

    @Test func theAutomaticChainWritesTheOnDeviceSummaryAndNeverCallsClaude() async throws {
        let rig = Rig()
        let id = try await seedProcessing(rig)
        let outcome = try await rig.services(claudeBackend: rig.claude).pipeline().run(meetingID: id)
        #expect(outcome.summaryBackendID == "fake-fm")
        #expect(try await rig.store.summaries(for: id).map(\.backendID) == ["fake-fm"])
        #expect(rig.claude.calls.withLock { $0 } == 0)
        #expect(try await rig.store.meeting(id: id)?.state == .finished)
    }

    @Test func summarizeWithClaudeWritesItsOwnSummaryOnly() async throws {
        let rig = Rig()
        let id = try await seedProcessing(rig)
        let services = rig.services(claudeBackend: rig.claude)
        _ = try await services.pipeline().run(meetingID: id)
        let url = try await services.summarizeWithClaude(meetingID: id)
        #expect(url.path.hasSuffix("/summaries/summary/claude.md"))
        #expect(rig.claude.calls.withLock { $0 } == 1)
        #expect(Set(try await rig.store.summaries(for: id).map(\.backendID)) == ["fake-fm", "claude"])
        #expect(try await rig.store.summaries(for: id).first?.backendID == "claude", "newest first")
    }

    @Test func theOldCustomPromptNowRunsAsTheMigratedDefaultTemplate() async throws {
        let rig = Rig()
        rig.settings.customPrompt = "Only list decisions."
        let id = UUID()
        try await rig.store.create(Meeting(
            id: id, title: "Sync", date: Date(), duration: 10, engineID: "live", templateID: rig.settings.defaultTemplateID,
            state: .processing))
        try await rig.store.appendSegment(MeetingSegment(stream: .mic, text: "we ship friday", start: 0, end: 3), to: id)
        let capture = PromptCapture()
        let services = MeetingServices(
            models: rig.models, store: rig.store, settings: rig.settings, keyStore: rig.keys,
            cleanup: CleanupRegistry(models: rig.models.manager, foundationModels: capture))
        _ = try await services.pipeline().run(meetingID: id)
        #expect(capture.instructions.withLock { $0.first } == "Only list decisions.")
    }
}

private final class PromptCapture: LLMBackend {
    let id = "capture"
    let instructions = Mutex<[String]>([])
    var maxPromptCharacters: Int? { nil }
    var availability: LLMAvailability { get async { .available } }
    func respond(instructions: String, prompt: String) async throws -> String {
        self.instructions.withLock { $0.append(instructions) }
        return "ok"
    }
}

// MARK: - The mixed session

private let spec16k = AudioFormatSpec(sampleRate: 16_000, channelCount: 1)

private final class HandSource: AudioSource {
    private let continuation = Mutex<AsyncStream<AudioChunk>.Continuation?>(nil)
    func start(format: AudioFormatSpec) async throws -> AsyncStream<AudioChunk> {
        let (stream, cont) = AsyncStream<AudioChunk>.makeStream()
        continuation.withLock { $0 = cont }
        return stream
    }
    func route() async throws -> AsyncStream<AudioChunk> { AsyncStream { $0.finish() } }
    func detach() async {}
    func stop() async { continuation.withLock { $0?.finish(); $0 = nil } }
    func push(_ samples: [Float]) { continuation.withLock { _ = $0?.yield(AudioChunk(samples: samples, format: spec16k)) } }
}

private final class QuietEngine: DictationEngine {
    let id = "quiet"
    let prepared = Mutex<[Locale?]>([])
    func installAssets(locale: Locale?) -> AsyncStream<Double> { AsyncStream { $0.finish() } }
    func prepare(locale: Locale?) async throws -> AudioFormatSpec {
        prepared.withLock { $0.append(locale) }
        return spec16k
    }
    func transcribe(_ input: AsyncStream<AudioChunk>) -> AsyncThrowingStream<TranscriptEvent, Error> {
        let (stream, cont) = AsyncThrowingStream<TranscriptEvent, Error>.makeStream()
        let task = Task { for await _ in input {}; cont.finish() }
        cont.onTermination = { _ in task.cancel() }
        return stream
    }
    func finish() async throws {}
}

private final class HalvingEnhancer: MicEnhancer {
    let references = Mutex<[Bool]>([])
    func enhance(mic: [Float], reference: [Float]?) async -> [Float] {
        references.withLock { $0.append(reference != nil) }
        return mic.map { $0 * 0.5 }
    }
    func flush() async -> [Float] { [] }
    func state() async -> MicEnhancerState { .active }
}

private final class ScriptedDiarizer: SpeakerDiarizer {
    let enrolled = Mutex<[[Float]]>([])
    let fedSamples = Mutex(0)
    func enroll(samples: [Float]) async throws -> String { enrolled.withLock { $0.append(samples) }; return "slot0" }
    func feed(_ chunk: AudioChunk) async throws { fedSamples.withLock { $0 += chunk.samples.count } }
    func turns() async -> [SpeakerTurn] { [] }
    func finish() async throws -> [SpeakerTurn] { [] }
}

private final class TrackSink: MeetingAudioSink {
    private let tracks = Mutex<[TranscriptEvent.Stream: [Float]]>([:])
    func samples(_ stream: TranscriptEvent.Stream) -> [Float]? { tracks.withLock { $0[stream] } }
    func write(_ chunk: AudioChunk, stream: TranscriptEvent.Stream) async throws {
        tracks.withLock { $0[stream, default: []] += chunk.samples }
    }
    func writeSilence(seconds: TimeInterval, stream: TranscriptEvent.Stream) async throws {
        tracks.withLock { $0[stream, default: []] += [Float](repeating: 0, count: Int(seconds * 16_000)) }
    }
    func finish() async throws {}
}

@MainActor @Suite struct MeetingServicesSessionTests {
    private func engines(
        diarizer: (any SpeakerDiarizer)? = nil, enhancer: (any MicEnhancer)? = nil, engine: any DictationEngine = QuietEngine(),
        locale: Locale? = nil, note: String? = nil
    ) -> MeetingServices.Engines {
        MeetingServices.Engines(
            engine: engine, engineID: engine.id, preferredLocales: locale.map { [$0] } ?? [], diarizer: diarizer,
            enhancer: enhancer, voiceProcessing: false, fallbackReason: nil, cleaningNote: note)
    }

    private func run(
        _ services: MeetingServices, _ engines: MeetingServices.Engines, withSystem: Bool, sink: TrackSink
    ) async throws -> (Meeting, MeetingServices.MixedMeeting) {
        let now = Mutex<TimeInterval>(0)
        let mic = HandSource(), system = HandSource()
        let meeting = services.newMeeting(title: "Sync", engines: engines)
        let made = services.makeSession(
            meeting: meeting, mic: mic, system: withSystem ? system : nil, engines: engines, sink: sink,
            clock: { now.withLock { $0 } })
        try await made.session.start()
        now.withLock { $0 = 0.5 }
        mic.push([Float](repeating: 0.4, count: 8_000))
        _ = await eventually { (sink.samples(.mic)?.count ?? 0) >= 8_000 }
        now.withLock { $0 = 1 }
        if withSystem {
            system.push([Float](repeating: 0.2, count: 16_000))
            _ = await eventually { (sink.samples(.system)?.count ?? 0) >= 16_000 }
            try await Task.sleep(for: .milliseconds(50))  // the copy for the enhancer is on its way
        }
        mic.push([Float](repeating: 0.4, count: 8_000))
        let wrote = await eventually { (sink.samples(.mic)?.count ?? 0) >= 16_000 && (!withSystem || (sink.samples(.system)?.count ?? 0) >= 16_000) }
        #expect(wrote)
        return (await made.session.stop(), made)
    }

    @Test func theMacMeetingMixesMicAndSystemIntoOneEngineWithTheMicCleanedAgainstTheSystemAudio() async throws {
        let rig = Rig()
        let enhancer = HalvingEnhancer()
        let diarizer = ScriptedDiarizer()
        let sink = TrackSink()
        let (meeting, _) = try await run(
            rig.services(), engines(diarizer: diarizer, enhancer: enhancer), withSystem: true, sink: sink)

        // Three tracks: the cleaned mic, the system audio as it came, and the mix the engine heard.
        #expect(sink.samples(.mic)?.count == 16_000 && sink.samples(.mic)?.allSatisfy { abs($0 - 0.2) < 1e-6 } == true)
        #expect(sink.samples(.system)?.allSatisfy { abs($0 - 0.2) < 1e-6 } == true)
        let mix = try #require(sink.samples(.mixed))
        #expect(mix.count == 16_000, "the mix is as long as the meeting")
        #expect(mix.suffix(1_600).allSatisfy { abs($0 - 0.4) < 1e-5 }, "0.2 cleaned mic + 0.2 system, once both are in; the mixer never waits for a late source")
        #expect(diarizer.fedSamples.withLock { $0 } == 16_000, "the diarizer hears the same mix")
        #expect(diarizer.enrolled.withLock { $0.isEmpty }, "no voice enrolment")
        #expect(enhancer.references.withLock { $0.contains(true) }, "the system audio reached the enhancer as the reference")
        #expect(meeting.state == .processing && abs(meeting.duration - 1) < 0.001)
    }

    @Test func thePhoneMeetingHasOneSourceDenoisedWithNoReferenceAndNoMixTrack() async throws {
        let rig = Rig()
        let enhancer = HalvingEnhancer()
        let sink = TrackSink()
        _ = try await run(rig.services(), engines(enhancer: enhancer), withSystem: false, sink: sink)
        #expect(sink.samples(.mic)?.allSatisfy { abs($0 - 0.2) < 1e-6 } == true)
        #expect(sink.samples(.mixed) == nil, "with one source the mic recording is the mix")
        #expect(enhancer.references.withLock { $0.allSatisfy { !$0 } }, "denoise only")
    }

    @Test func withoutAnEnhancerTheRawMicIsUsedAndTheNoteReachesTheUser() async throws {
        let rig = Rig()
        let sink = TrackSink()
        let (_, made) = try await run(rig.services(), engines(note: "LocalVQE is not downloaded"), withSystem: true, sink: sink)
        #expect(sink.samples(.mic)?.allSatisfy { abs($0 - 0.4) < 1e-6 } == true)
        var notices: [String] = []
        for await n in made.notices { notices.append(n) }
        #expect(notices == ["LocalVQE is not downloaded"])
    }

    @Test func theMeetingsLanguageIsWhatTheEngineIsPreparedFor() async throws {
        let rig = Rig()
        let engine = QuietEngine()
        let sink = TrackSink()
        _ = try await run(rig.services(), engines(engine: engine, locale: Locale(identifier: "de-DE")), withSystem: false, sink: sink)
        #expect(engine.prepared.withLock { $0 } == [Locale(identifier: "de-DE")])
    }
}

// MARK: - When the heavy steps run

@MainActor @Suite struct MeetingServicesSchedulingTests {
    private func seed(_ rig: Rig) async throws -> UUID {
        let id = UUID()
        try await rig.store.create(Meeting(id: id, title: "Sync", date: Date(), duration: 10, engineID: "live", state: .processing))
        try await rig.store.appendSegment(MeetingSegment(stream: .mixed, text: "we ship friday", start: 0, end: 3), to: id)
        return id
    }

    private func finished(_ rig: Rig, _ id: UUID) async throws -> Bool {
        try await rig.store.meeting(id: id)?.state == .finished
    }

    @Test func atStopTheAudioRunsAtOnceAndTheRestWaitsForIdle() async throws {
        let rig = Rig()
        let services = rig.services()
        let id = try await seed(rig)
        let processed = Mutex(0)
        services.onProcessed = { _, _, _ in processed.withLock { $0 += 1 } }

        try await services.processAfterStop(id)
        var meeting = try #require(try await rig.store.meeting(id: id))
        #expect(meeting.completedSteps == [.audio])
        #expect(meeting.state == .processing)
        #expect(await services.scheduler.queued == [id])

        await services.scheduler.tick()  // the machine is busy
        #expect(try await rig.store.summaries(for: id).isEmpty)

        rig.load.value = IdleSample(cpuLoad: 0.9, secondsSinceInput: 61)
        await services.scheduler.tick()
        meeting = try #require(try await rig.store.meeting(id: id))
        #expect(meeting.state == .finished)
        #expect(meeting.completedSteps == [.audio, .summary])
        #expect(try await rig.store.summaries(for: id).map(\.backendID) == ["fake-fm"])
        #expect(processed.withLock { $0 } == 1)
        #expect(await services.scheduler.queued.isEmpty)
    }

    @Test func nothingHeavyRunsWhileAMeetingRecords() async throws {
        let rig = Rig()
        let services = rig.services()
        let id = try await seed(rig)
        rig.load.value = .idle
        services.setRecording(true)
        try await services.processAfterStop(id)
        await services.scheduler.tick()
        #expect(try await finished(rig, id) == false)
        #expect(try await rig.store.meeting(id: id)?.completedSteps == [.audio], "the audio still converted")

        services.setRecording(false)
        await services.scheduler.tick()
        #expect(try await finished(rig, id))
    }

    @Test func processNowSkipsTheWaitButNotTheRecording() async throws {
        let rig = Rig()
        let services = rig.services()
        let id = try await seed(rig)
        try await services.processAfterStop(id)  // busy machine: waits
        await services.scheduler.tick()
        #expect(try await finished(rig, id) == false)

        services.setRecording(true)
        await services.processNow(id)
        await services.scheduler.tick()
        #expect(try await finished(rig, id) == false, "not while recording")

        services.setRecording(false)
        await services.scheduler.tick()
        #expect(try await finished(rig, id), "the bypass was remembered")
    }

    @Test func withIdleProcessingOffTheHeavyStepsFollowTheStopAtOnce() async throws {
        let rig = Rig()
        rig.settings.idleProcessing = false
        let services = rig.services()
        let id = try await seed(rig)
        try await services.processAfterStop(id)
        await services.scheduler.tick()
        #expect(try await finished(rig, id))
    }

    @Test func aMeetingCutShortLeavesTheQueueAlone() async throws {
        let rig = Rig()
        let services = rig.services()
        let id = try await seed(rig)
        rig.load.value = .idle
        try await services.processAfterStop(id)
        await services.scheduler.cancelRunning()  // nothing is running: harmless
        await services.scheduler.tick()
        #expect(try await finished(rig, id))
    }
}
