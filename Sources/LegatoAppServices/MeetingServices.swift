import Foundation
import LegatoAppleSpeech
import LegatoAudio
import LegatoClaude
import LegatoCore
import LegatoEngines
import LegatoFluidAudio
import LegatoMLX
import LegatoMeetings
import LegatoModels
import Synchronization

private final class RecordingFlag: Sendable { let value = Mutex(false) }

/// What an app needs to record, process and summarise meetings, built on its ``ModelServices``: the live engine
/// for a meeting, its speaker and microphone-cleaning models, the mixed session, the post-pass model, the
/// on-device summary backend, and the after-stop chain with the scheduler that waits for an idle machine.
///
/// The automatic chain never uses Claude. Claude runs only through ``summarizeWithClaude(meetingID:)``,
/// which the user asks for per meeting.
@MainActor
public final class MeetingServices {
    /// What one meeting runs on.
    public struct Engines: Sendable {
        /// The one live engine, which hears the mix of every source.
        public let engine: any DictationEngine
        /// The id recorded on the meeting (`Meeting.engineID`).
        public let engineID: String
        public let preferredLocales: [Locale]
        /// The streaming diarizer for the mix; `nil` when live diarization is off or its model is not installed.
        public let diarizer: (any SpeakerDiarizer)?
        /// LocalVQE for the meeting mic; `nil` unless the echo-and-noise setting is LocalVQE and its model is installed.
        public let enhancer: (any MicEnhancer)?
        /// The mic should use Apple's voice processing (the Mac, when that is the echo-and-noise choice).
        public let voiceProcessing: Bool
        /// Why Apple Speech runs although another model is picked, for the UI; `nil` otherwise.
        public let fallbackReason: String?
        /// Why the mic is not cleaned although LocalVQE is chosen (its model is missing), for the UI; `nil` otherwise.
        public let cleaningNote: String?

        /// These engines with `engine` in place of the live one (the end-to-end run's scripted engine).
        public func replacing(engine replacement: any DictationEngine) -> Engines {
            Engines(
                engine: replacement, engineID: replacement.id, preferredLocales: preferredLocales, diarizer: diarizer,
                enhancer: enhancer, voiceProcessing: voiceProcessing, fallbackReason: fallbackReason, cleaningNote: cleaningNote)
        }

        /// The language the engine prepares for: the meeting's language, or the one language the engine
        /// settings name, else `nil` (the engine chooses). Pass it as the session's `locale`.
        public var locale: Locale? { preferredLocales.count == 1 ? preferredLocales[0] : nil }
    }

    /// A meeting's session, and what to tell the user about the microphone while it runs.
    public struct MixedMeeting: Sendable {
        public let session: MeetingSession
        /// E.g. that LocalVQE fell back to the raw microphone. Ends when the meeting does.
        public let notices: AsyncStream<String>
    }

    public let settings: MeetingSettings
    public let store: MeetingStore
    /// Runs the heavy after-meeting steps one at a time once the machine is idle.
    public private(set) lazy var scheduler = ProcessingScheduler(
        clock: { ProcessInfo.processInfo.systemUptime }, sample: sampler, isRecording: { [recording] in recording.value.withLock { $0 } },
        immediate: immediateProcessing, pollInterval: pollInterval,
        work: { [weak self] id in await self?.runDeferred(id) ?? true })
    /// Called when the deferred steps of a meeting ended: with their outcome, or the error that stopped them
    /// (`CancellationError` when cut short: the meeting stays queued).
    public var onProcessed: (@MainActor (UUID, MeetingPipeline.Outcome?, (any Error)?) -> Void)?

    private let registry: EngineRegistry
    private let cleanup: CleanupRegistry
    private let background: CleanupRegistry.BackgroundCleanup
    private let makeClaude: @Sendable () -> any LLMBackend
    private let sampler: @Sendable () -> IdleSample
    private let immediateProcessing: Bool
    private let pollInterval: Duration?
    private let recording = RecordingFlag()

    /// - Parameters:
    ///   - cleanup: the registry the summary backend resolves through; the models' own by default.
    ///   - background: what the summary does while the GPU is not usable (the phone in the background).
    ///   - claudeBackend: replaces the Claude backend (tests); nil builds a ``ClaudeBackend`` over `keyStore`.
    ///   - sampler: the machine's load and input idleness (the Mac's real one; the phone's always idle).
    ///   - immediateProcessing: run the heavy steps without waiting for idleness (the debug launch argument).
    ///   - pollInterval: how often the scheduler looks while meetings wait; nil only when a test drives it.
    public init(
        models: ModelServices, store: MeetingStore, settings: MeetingSettings, keyStore: any APIKeyStore,
        claudeSession: URLSession? = nil, cleanup: CleanupRegistry? = nil,
        claudeBackend: (any LLMBackend)? = nil, background: CleanupRegistry.BackgroundCleanup = .cpu,
        sampler: @escaping @Sendable () -> IdleSample = { .idle },
        immediateProcessing: Bool = ProcessingScheduler.launchImmediate, pollInterval: Duration? = .seconds(5)
    ) {
        self.store = store
        self.settings = settings
        self.registry = models.engines
        self.cleanup = cleanup ?? models.cleanup
        self.background = background
        self.sampler = sampler
        self.immediateProcessing = immediateProcessing
        self.pollInterval = pollInterval
        self.makeClaude = { claudeBackend ?? claudeSession.map { ClaudeBackend(keyStore: keyStore, session: $0) } ?? ClaudeBackend(keyStore: keyStore) }
    }

    // MARK: Engines and session

    /// What a meeting on `platform` runs on: ONE live engine (in `locale` when the meeting has a language of
    /// its own, else the engine settings' languages), the live diarizer when that setting is on, and the mic
    /// enhancer when the echo-and-noise setting is LocalVQE. A model that is not installed is simply absent.
    public func engines(for platform: ModelPlatform = .current, locale: Locale? = nil) async -> Engines {
        let live = await registry.liveEngine(localeOverride: locale)
        let mode = settings.echoNoise
        let diarizer = settings.liveDiarization ? await registry.liveDiarizer() : nil
        let enhancer = mode == .localVQE ? await registry.micEnhancer() : nil
        let reason: String? = switch live.fallback {
        case .assetsNotInstalled: "The picked speech model is not installed, so meetings use Apple Speech."
        case .unknownModel: "The picked speech model is not available, so meetings use Apple Speech."
        case nil: nil
        }
        return Engines(
            engine: live.engine, engineID: live.engine.id, preferredLocales: live.preferredLocales, diarizer: diarizer,
            enhancer: enhancer, voiceProcessing: platform == .macOS && mode == .appleVoiceProcessing,
            fallbackReason: reason,
            cleaningNote: mode == .localVQE && enhancer == nil
                ? "Echo and noise cancellation is not downloaded yet, so the raw microphone is used." : nil)
    }

    /// A new meeting set up from `engines`: its language, and the default summary template.
    public func newMeeting(
        id: UUID = UUID(), title: String, date: Date = Date(), engines: Engines
    ) -> Meeting {
        Meeting(
            id: id, title: title, date: date, engineID: engines.engineID, locale: engines.locale?.identifier,
            templateID: settings.defaultTemplateID)
    }

    /// The mixed session for `meeting`: `mic` (and `system`, on the Mac) summed into one signal for the one
    /// live engine, the live diarizer fed the same mix and the mic
    /// cleaned by LocalVQE with the system audio as its echo reference (on the phone, with no reference). When
    /// the enhancer falls back the raw mic is used and ``MixedMeeting/notices`` says so.
    ///
    /// The session records each source and, with two, the mix; the sink gets `.mic`, `.system` and `.mixed`.
    public func makeSession(
        meeting: Meeting, mic: any AudioSource, system: (any AudioSource)? = nil, engines: Engines,
        sink: any MeetingAudioSink, convert: @escaping MeetingAudioConverter = { $0 },
        clock: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) -> MixedMeeting {
        var micSource = mic
        var systemSource = system
        var notices = AsyncStream<String> { continuation in
            if let note = engines.cleaningNote { continuation.yield(note) }
            continuation.finish()
        }
        if let enhancer = engines.enhancer {
            let stage = MicCleaningStage(enhancer: enhancer, clock: clock)
            micSource = stage.mic(mic)
            systemSource = system.map(stage.reference)
            notices = stage.notices
        }
        var sources = [MeetingSource(stream: .mic, source: micSource)]
        if let systemSource { sources.append(MeetingSource(stream: .system, source: systemSource)) }
        let session = MeetingSession(
            meeting: meeting, sources: sources, engine: engines.engine, locale: engines.locale, diarizer: engines.diarizer,
            store: store, sink: sink, convert: convert, clock: clock)
        return MixedMeeting(session: session, notices: notices)
    }

    // MARK: Backends

    /// The accuracy-pass model, or `nil` when none is installed.
    public func postPassTranscriber() async -> (any BatchTranscriber)? {
        await registry.postPassTranscriber()
    }

    /// The on-device backend for the automatic summary, as the stored choice resolves. Never Claude.
    public func summaryBackend() async -> (any LLMBackend)? {
        await cleanup.resolve(preference: settings.backend.preference, background: background).backend
    }

    /// The Claude backend. Used only by ``summarizeWithClaude(meetingID:)``.
    public func claudeBackend() -> any LLMBackend { makeClaude() }

    // MARK: Processing

    /// A meeting records (true) or not. Nothing heavy runs while one does.
    public func setRecording(_ isRecording: Bool) {
        recording.value.withLock { $0 = isRecording }
    }

    /// The after-stop chain: m4a, post-pass, speakers, on-device summary. `onStep` reports each finished step.
    /// Run it inside a background task on the phone; see ``MeetingPipeline``.
    public func pipeline(onStep: @escaping @Sendable (Meeting.Step) -> Void = { _ in }) -> MeetingPipeline {
        let registry = self.registry, cleanup = self.cleanup, settings = self.settings
        let background = self.background
        return MeetingPipeline(
            store: store,
            audio: { MeetingAudioWriter(folder: $0) },
            transcriber: { await registry.postPassTranscriber() },
            backend: { await cleanup.resolve(preference: settings.backend.preference, background: background).backend },
            templates: { settings.customTemplates },
            batchDiarizer: { await registry.batchDiarizer() },
            diarizationEnabled: { settings.offlineDiarization },
            onStep: onStep)
    }

    /// What happens when a meeting stops, or when a meeting that was cut short is picked up again: the audio
    /// step runs now (the meeting plays at once), and the heavy steps are queued for an idle machine, or run
    /// at once when idle processing is off.
    @discardableResult
    public func processAfterStop(_ id: UUID) async throws -> MeetingPipeline.Outcome {
        let outcome = try await pipeline().runAudio(meetingID: id)
        if settings.idleProcessing { await scheduler.enqueue(id) } else { await scheduler.processNow(id) }
        return outcome
    }

    /// "Process now": the heavy steps of this meeting without waiting for an idle machine (never during a recording).
    public func processNow(_ id: UUID) async {
        await scheduler.processNow(id)
    }

    /// The scheduler's job: the deferred steps. False (stay queued) when cut short.
    private func runDeferred(_ id: UUID) async -> Bool {
        do {
            let outcome = try await pipeline().runDeferred(meetingID: id)
            onProcessed?(id, outcome, nil)
        } catch is CancellationError {
            onProcessed?(id, nil, CancellationError())
            return false
        } catch {
            onProcessed?(id, nil, error)
        }
        return true
    }

    /// Summarises one meeting with Claude, after the user asked for it. Writes `summaries/summary/claude.md`.
    /// - Throws: ``LLMError/unavailable(reason:)`` when there is no key.
    @discardableResult
    public func summarizeWithClaude(meetingID: UUID) async throws -> URL {
        let claude = claudeBackend()
        if case .unavailable(let reason) = await claude.availability { throw LLMError.unavailable(reason: reason) }
        return try await pipeline().summarize(meetingID: meetingID, using: claude)
    }
}
