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

/// Polls an async `condition` until it holds or `timeout` passes.
private func eventually(timeout: Duration, _ condition: @Sendable () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return await condition()
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
        // The heavy step most tests here watch is the automatic summary; the app's default is off (tests below).
        settings.summarizeAutomatically = true
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

    @Test func aNewMeetingCarriesItsLanguageAndTheDefaultTicks() async throws {
        let rig = Rig()
        let mine = rig.settings.addSection(heading: "Mine", instruction: "p")
        rig.settings.defaultSectionIDs = [mine.id, "decisions"]
        let services = rig.services()
        let german = await services.engines(locale: Locale(identifier: "de-DE"))
        let meeting = services.newMeeting(title: "Sync", engines: german)
        #expect(meeting.locale == "de-DE")
        #expect(meeting.sections == ["decisions", mine.id], "in the configured order")
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
        // A15: until LocalVQE is downloaded the Mac falls back to Apple voice processing, not to the raw mic.
        #expect(missing.voiceProcessing, "LocalVQE is chosen but not downloaded: Apple voice processing stands in")
        #expect(missing.cleaningNote?.contains("Apple voice processing") == true)
        let phone = await Rig().services().engines(for: .iOS)  // a fresh install: the first call starts the download
        #expect(!phone.voiceProcessing && phone.cleaningNote?.contains("raw microphone") == true, "the phone has no stand-in")

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

    // MARK: Models missing on a fresh install

    private func installed(_ rig: Rig, _ id: String) async -> Bool {
        if case .installed = await rig.models.manager.state(of: id) { return true }
        return false
    }

    @Test func aMeetingWithLiveSpeakersOnStartsDownloadingTheMissingModelAndGoesOnWithout() async throws {
        let rig = Rig()
        let engines = await rig.services().engines(for: .macOS)
        #expect(engines.diarizer == nil, "this meeting runs without live speakers")
        #expect(engines.speakersNote?.localizedCaseInsensitiveContains("speaker") == true)
        #expect(await eventually(timeout: .seconds(3)) { await installed(rig, FluidAudioModels.sortformerID) }, "downloaded in the background")
        let next = await rig.services().engines(for: .macOS)
        #expect(next.diarizer != nil && next.speakersNote == nil, "the next meeting has live speakers")
    }

    @Test func aMissingLocalVqeIsDownloadedWhenAMeetingStarts() async throws {
        let rig = Rig()
        _ = await rig.services().engines(for: .macOS)
        #expect(await eventually(timeout: .seconds(3)) { await installed(rig, FluidAudioModels.localVqeID) })
        #expect(await rig.services().engines(for: .macOS).enhancer != nil)
    }

    @Test func nothingIsDownloadedForWhatIsSwitchedOff() async throws {
        let rig = Rig()
        rig.settings.liveDiarization = false
        rig.settings.echoNoise = .appleVoiceProcessing
        let engines = await rig.services().engines(for: .macOS)
        #expect(engines.speakersNote == nil)
        try await Task.sleep(for: .milliseconds(150))
        #expect(await !installed(rig, FluidAudioModels.sortformerID))
        #expect(await !installed(rig, FluidAudioModels.localVqeID))
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
        #expect(url.path.hasSuffix("/summaries/claude.md"))
        #expect(rig.claude.calls.withLock { $0 } == 1)
        #expect(Set(try await rig.store.summaries(for: id).map(\.backendID)) == ["fake-fm", "claude"])
        #expect(try await rig.store.summaries(for: id).first?.backendID == "claude", "newest first")
    }

    @Test func theOldCustomPromptNowRunsAsTheMigratedMyNotesSection() async throws {
        let rig = Rig()
        rig.settings.customPrompt = "Only list decisions."
        let id = UUID()
        try await rig.store.create(Meeting(
            id: id, title: "Sync", date: Date(), duration: 10, engineID: "live", sections: rig.settings.defaultSectionIDs,
            state: .processing))
        try await rig.store.appendSegment(MeetingSegment(stream: .mic, text: "we ship friday", start: 0, end: 3), to: id)
        let capture = PromptCapture()
        let services = MeetingServices(
            models: rig.models, store: rig.store, settings: rig.settings, keyStore: rig.keys,
            cleanup: CleanupRegistry(models: rig.models.manager, foundationModels: capture))
        _ = try await services.pipeline().run(meetingID: id)
        let sent = try #require(capture.instructions.withLock { $0.first })
        #expect(sent.contains("## My notes\nOnly list decisions."))
        #expect(!sent.contains("## Summary"), "the migrated prompt replaced the default, as before")
    }

    // MARK: Summary on click

    @Test func theAutomaticSummaryIsOffByDefault() {
        let settings = MeetingSettings(defaults: UserDefaults(suiteName: "legato.meeting-services.\(UUID().uuidString)")!)
        #expect(!settings.summarizeAutomatically)
    }

    @Test func withTheSettingOffTheChainFinishesWithoutCallingTheModel() async throws {
        let rig = Rig()
        rig.settings.summarizeAutomatically = false
        let id = try await seedProcessing(rig)
        let outcome = try await rig.services(claudeBackend: rig.claude).pipeline().run(meetingID: id)
        #expect(outcome.summaryBackendID == nil)
        #expect(rig.foundation.calls.withLock { $0 } == 0)
        #expect(try await rig.store.summaries(for: id).isEmpty)
        let meeting = try #require(try await rig.store.meeting(id: id))
        #expect(meeting.state == .finished)
        #expect(!meeting.completedSteps.contains(.summary))
    }

    @Test func summarizeOnAFinishedMeetingUsesItsTickedSectionsAndTheOnDeviceBackend() async throws {
        let rig = Rig()
        rig.settings.summarizeAutomatically = false
        let id = try await seedProcessing(rig)
        let services = rig.services(claudeBackend: rig.claude)
        _ = try await services.pipeline().run(meetingID: id)
        try await rig.store.update(id: id) { $0.sections = ["open-questions"] }
        let url = try await services.regenerate(meetingID: id)
        #expect(url.path.hasSuffix("/summaries/fake-fm.md"))
        #expect(try await rig.store.summaries(for: id).map(\.sections) == [["open-questions"]])
        #expect(rig.claude.calls.withLock { $0 } == 0)
        #expect(try await rig.store.meeting(id: id)?.completedSteps.contains(.summary) == true)
    }
}

/// Its first answer takes two seconds, unless the task is cancelled first; later answers come at once.
private final class BlockingLLM: LLMBackend {
    let id = "blocking"
    let calls = Mutex(0)
    var maxPromptCharacters: Int? { nil }
    var availability: LLMAvailability { get async { .available } }
    func respond(instructions: String, prompt: String) async throws -> String {
        let n = calls.withLock { $0 += 1; return $0 }
        if n == 1 { try await Task.sleep(for: .seconds(2)) }
        return "## Summary\nblocking"
    }
}

/// Its first answer waits up to ten seconds and records whether it was cancelled; later answers come at once.
private final class HoldingLLM: LLMBackend {
    let id = "holding"
    let calls = Mutex(0)
    let cancelled = Mutex(0)
    var maxPromptCharacters: Int? { nil }
    var availability: LLMAvailability { get async { .available } }
    func respond(instructions: String, prompt: String) async throws -> String {
        let n = calls.withLock { $0 += 1; return $0 }
        if n == 1 {
            do { try await Task.sleep(for: .seconds(10)) } catch {
                cancelled.withLock { $0 += 1 }
                throw error
            }
        }
        return "## Summary\nholding"
    }
}

/// How many heavy model calls run at once, across the fakes.
private final class HeavyMeter: Sendable {
    private let state = Mutex((now: 0, max: 0))
    var max: Int { state.withLock { $0.max } }
    func enter() { state.withLock { $0.now += 1; $0.max = Swift.max($0.max, $0.now) } }
    func leave() { state.withLock { $0.now -= 1 } }
}

/// A post-pass model on the meter. With `holdFirst` its first call waits for ``release()``; with `fails` every
/// call fails.
private final class MeteredTranscriber: BatchTranscriber {
    let id = "metered-batch"
    let meter: HeavyMeter
    let fails: Bool
    let calls = Mutex(0)
    private let held: Mutex<Bool>
    init(meter: HeavyMeter, holdFirst: Bool = false, fails: Bool = false) {
        self.meter = meter
        self.fails = fails
        held = Mutex(holdFirst)
    }
    func release() { held.withLock { $0 = false } }
    func transcribe(samples: [Float], stream: TranscriptEvent.Stream) async throws -> [TranscriptEvent] {
        meter.enter()
        defer { meter.leave() }
        let first = calls.withLock { $0 += 1; return $0 == 1 }
        try await Task.sleep(for: .milliseconds(50))
        while first, held.withLock({ $0 }) { try await Task.sleep(for: .milliseconds(5)) }
        if fails { throw LLMError.failed("boom") }
        return [TranscriptEvent(stream: stream, text: "accurate", isFinal: true, range: 0..<2)]
    }
}

/// An on-device summary model on the meter.
private final class MeteredLLM: LLMBackend {
    let id = "metered"
    let meter: HeavyMeter
    init(meter: HeavyMeter) { self.meter = meter }
    var maxPromptCharacters: Int? { nil }
    var availability: LLMAvailability { get async { .available } }
    func respond(instructions: String, prompt: String) async throws -> String {
        meter.enter()
        defer { meter.leave() }
        try await Task.sleep(for: .milliseconds(20))
        return "## Summary\nmetered"
    }
}

/// Two seconds of a silent mix, already converted.
private struct SilentRecordings: MeetingAudioFinalizing {
    func duration(of stream: TranscriptEvent.Stream) async throws -> TimeInterval { stream == .mixed ? 2 : 0 }
    func samples(of stream: TranscriptEvent.Stream, in range: Range<TimeInterval>) async throws -> [Float] {
        [Float](repeating: 0, count: Int((min(range.upperBound, 2) - range.lowerBound) * 16_000))
    }
    func finalizeAudio() async throws -> [TranscriptEvent.Stream] { [] }
    func discardLosslessAudio() async {}
    func recordingURL(of stream: TranscriptEvent.Stream) -> URL? { nil }
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
    let fedSamples = Mutex(0)
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

    @Test func aJobRunningWhenARecordingStartsIsStoppedAndRunsAgainAfterTheMeeting() async throws {
        let rig = Rig()
        let blocking = BlockingLLM()
        let services = MeetingServices(
            models: rig.models, store: rig.store, settings: rig.settings, keyStore: rig.keys,
            cleanup: CleanupRegistry(models: rig.models.manager, foundationModels: blocking),
            sampler: { .idle }, immediateProcessing: false, pollInterval: nil)
        let id = try await seed(rig)
        try await services.processAfterStop(id)
        let tick = Task { await services.scheduler.tick() }
        #expect(await eventually { blocking.calls.withLock { $0 } == 1 }, "the summary is being written")

        services.setRecording(true)
        await tick.value
        #expect(try await finished(rig, id) == false, "the heavy step stopped for the recording")
        #expect(await services.scheduler.queued == [id], "and waits to run again")

        services.setRecording(false)
        await services.scheduler.tick()
        #expect(try await finished(rig, id))
        #expect(try await rig.store.summaries(for: id).map(\.backendID) == ["blocking"])
    }

    // MARK: What the heavy steps are doing (the banner's source)

    @Test func theStageFollowsAMeetingFromQueuedThroughItsStepsToGone() async throws {
        let rig = Rig()
        let services = rig.services()
        let id = try await seed(rig)
        let seen = Mutex<[ProcessingStage?]>([])
        services.onProgress = { changed, stage in if changed == id { seen.withLock { $0.append(stage) } } }

        #expect(services.stage(of: id) == nil)
        try await services.processAfterStop(id)
        #expect(services.stage(of: id) == .queued, "waiting for an idle machine is not working")

        await services.scheduler.tick()  // the machine is busy: still only waiting
        #expect(services.stage(of: id) == .queued)
        #expect(!seen.withLock { $0 }.contains { $0?.isRunning == true }, "nothing claimed to run while waiting")

        rig.load.value = IdleSample(cpuLoad: 0.9, secondsSinceInput: 61)
        await services.scheduler.tick()
        let stages = seen.withLock { $0 }
        #expect(stages.first == .queued)
        #expect(stages.contains(.running(.summary)), "the summary step says it started")
        #expect(stages.contains(.running(.summary, progress: 0.5)), "and how far it is: one chunk, then the merge")
        #expect(stages.last == .some(nil), "gone once the steps are done")
        #expect(services.stage(of: id) == nil)
    }

    @Test func aJobCutShortByARecordingGoesBackToWaiting() async throws {
        let rig = Rig()
        let blocking = BlockingLLM()
        let services = MeetingServices(
            models: rig.models, store: rig.store, settings: rig.settings, keyStore: rig.keys,
            cleanup: CleanupRegistry(models: rig.models.manager, foundationModels: blocking),
            sampler: { .idle }, immediateProcessing: false, pollInterval: nil)
        let id = try await seed(rig)
        try await services.processAfterStop(id)
        let tick = Task { await services.scheduler.tick() }
        #expect(await eventually(timeout: .seconds(2)) { await MainActor.run { services.stage(of: id)?.isRunning == true } })

        services.setRecording(true)
        await tick.value
        #expect(services.stage(of: id) == .queued, "the banner says waiting again, not still working")
    }

    @Test func processNowQueuesAMeetingTheServiceDidNotKnowYet() async throws {
        let rig = Rig()
        let services = rig.services()
        let id = try await seed(rig)
        await services.processNow(id)
        #expect(services.stage(of: id) == .queued)
    }

    @Test func regenerateReportsTheSummaryStepWhileItRunsAndThenNothing() async throws {
        let rig = Rig()
        let services = rig.services()
        let id = UUID()
        try await rig.store.create(Meeting(id: id, title: "Done", date: Date(), duration: 10, engineID: "live", state: .finished, completedSteps: [.audio, .summary]))
        try await rig.store.appendSegment(MeetingSegment(stream: .mixed, text: "we ship friday", start: 0, end: 3), to: id)
        let seen = Mutex<[ProcessingStage?]>([])
        services.onProgress = { changed, stage in if changed == id { seen.withLock { $0.append(stage) } } }
        try await services.regenerate(meetingID: id)
        #expect(seen.withLock { $0 }.first == .running(.summary))
        #expect(seen.withLock { $0 }.last == .some(nil))
        #expect(services.stage(of: id) == nil)
    }

    @Test func manualProcessingIsRefusedWhileAMeetingRecords() async throws {
        let rig = Rig()
        let services = rig.services(claudeBackend: rig.claude)
        let id = UUID()
        try await rig.store.create(Meeting(id: id, title: "Done", date: Date(), duration: 10, engineID: "live", state: .finished, completedSteps: [.audio, .summary]))
        try await rig.store.appendSegment(MeetingSegment(stream: .mixed, text: "we ship friday", start: 0, end: 3), to: id)
        services.setRecording(true)
        await #expect(throws: MeetingServicesError.recording) { try await services.improveTranscript(meetingID: id) }
        await #expect(throws: MeetingServicesError.recording) { try await services.regenerate(meetingID: id) }
        await #expect(throws: MeetingServicesError.recording) { try await services.summarizeWithClaude(meetingID: id) }
        #expect(try await rig.store.meeting(id: id)?.state == .finished, "nothing was started")
        #expect(try await rig.store.summaries(for: id).isEmpty)
        #expect(rig.foundation.calls.withLock { $0 } == 0 && rig.claude.calls.withLock { $0 } == 0)

        services.setRecording(false)
        try await services.regenerate(meetingID: id)
        #expect(try await rig.store.summaries(for: id).map(\.backendID) == ["fake-fm"])
    }

    // MARK: Manual and automatic jobs share one lane

    private func finishedMeeting(_ rig: Rig) async throws -> UUID {
        let id = UUID()
        try await rig.store.create(Meeting(id: id, title: "Done", date: Date(), duration: 10, engineID: "live", state: .finished, completedSteps: [.audio, .postPass, .summary]))
        try await rig.store.appendSegment(MeetingSegment(stream: .mixed, text: "we ship friday", start: 0, end: 3), to: id)
        return id
    }

    private func meteredPipeline(_ rig: Rig, _ transcriber: MeteredTranscriber, _ llm: MeteredLLM) -> @MainActor () -> MeetingPipeline {
        let store = rig.store
        return {
            MeetingPipeline(
                store: store, audio: { _ in SilentRecordings() }, transcriber: { transcriber }, backend: { llm },
                summarizeAutomatically: { true }, releaseModels: {}, releasePostPassModels: {})
        }
    }

    @Test func aManualSummaryRunningWhenARecordingStartsIsCancelledAndRunsAgainAfterTheMeeting() async throws {
        let rig = Rig()
        let llm = HoldingLLM()
        let services = MeetingServices(
            models: rig.models, store: rig.store, settings: rig.settings, keyStore: rig.keys,
            cleanup: CleanupRegistry(models: rig.models.manager, foundationModels: llm),
            sampler: { .idle }, immediateProcessing: false, pollInterval: nil)
        let id = try await finishedMeeting(rig)
        let summary = Task { try await services.regenerate(meetingID: id) }
        #expect(await eventually(timeout: .seconds(2)) { llm.calls.withLock { $0 } == 1 }, "the summary is being written")

        services.setRecording(true)
        #expect(await eventually(timeout: .seconds(2)) { llm.cancelled.withLock { $0 } == 1 }, "the summary stopped for the recording")
        #expect(try await rig.store.summaries(for: id).isEmpty)

        services.setRecording(false)
        let url = try await summary.value
        #expect(url.path.hasSuffix("/summaries/holding.md"), "it ran again once the meeting ended")
        #expect(llm.calls.withLock { $0 } == 2)
    }

    @Test func aManualImproveAndADeferredJobOnTheSameMeetingNeverRunAtOnce() async throws {
        let rig = Rig()
        let services = rig.services()
        let meter = HeavyMeter()
        let transcriber = MeteredTranscriber(meter: meter, holdFirst: true)
        let llm = MeteredLLM(meter: meter)
        services.pipelineOverride = meteredPipeline(rig, transcriber, llm)
        let id = try await seed(rig)
        try await services.processAfterStop(id)
        rig.load.value = .idle
        let deferred = Task { await services.scheduler.tick() }
        #expect(await eventually(timeout: .seconds(2)) { transcriber.calls.withLock { $0 } == 1 }, "the deferred post-pass runs")

        let improve = Task { try await services.improveTranscript(meetingID: id) }
        try await Task.sleep(for: .milliseconds(300))
        transcriber.release()
        await deferred.value
        _ = try await improve.value
        #expect(transcriber.calls.withLock { $0 } == 2, "both ran")
        #expect(meter.max == 1, "one heavy model at a time")
    }

    @Test func aManualJobEndingNeverOverwritesTheStageOfTheJobThatRuns() async throws {
        let rig = Rig()
        let services = rig.services()
        let meter = HeavyMeter()
        let transcriber = MeteredTranscriber(meter: meter, holdFirst: true)
        services.pipelineOverride = meteredPipeline(rig, transcriber, MeteredLLM(meter: meter))
        let id = try await seed(rig)
        try await services.processAfterStop(id)
        rig.load.value = .idle
        let deferred = Task { await services.scheduler.tick() }
        #expect(await eventually(timeout: .seconds(2)) { transcriber.calls.withLock { $0 } == 1 })
        #expect(services.stage(of: id) == .running(.postPass))

        let ended = Mutex(false)
        let regenerate = Task {
            _ = try await services.regenerate(meetingID: id)
            ended.withLock { $0 = true }
        }
        _ = await eventually(timeout: .milliseconds(500)) { ended.withLock { $0 } }
        #expect(services.stage(of: id)?.isRunning == true, "the deferred job still runs, and its stage says so")

        transcriber.release()
        await deferred.value
        try await regenerate.value
        #expect(services.stage(of: id) == nil, "both are done")
    }

    @Test func anImproveThatWillRetryQueuesTheMeetingAgain() async throws {
        let rig = Rig()
        let services = rig.services()
        let meter = HeavyMeter()
        services.pipelineOverride = meteredPipeline(rig, MeteredTranscriber(meter: meter, fails: true), MeteredLLM(meter: meter))
        let id = try await finishedMeeting(rig)
        let outcome = try await services.improveTranscript(meetingID: id)
        #expect(outcome.willRetry)
        #expect(await services.scheduler.queued == [id], "queued to be tried again")
        #expect(services.stage(of: id) == .queued)
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
