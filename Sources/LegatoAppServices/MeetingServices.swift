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

/// Why ``MeetingServices`` refused to do something.
public enum MeetingServicesError: Error, Equatable, LocalizedError {
    /// A meeting is recording: the heavy models stay off until it ends.
    case recording

    public var errorDescription: String? {
        switch self {
        case .recording: "Not while a meeting is recording. Try again when it has ended."
        }
    }
}

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
        /// Why this meeting has no live speakers although they are on (the model is still downloading); `nil` otherwise.
        public var speakersNote: String? = nil

        /// These engines with `engine` in place of the live one (the end-to-end run's scripted engine).
        public func replacing(engine replacement: any DictationEngine) -> Engines {
            Engines(
                engine: replacement, engineID: replacement.id, preferredLocales: preferredLocales, diarizer: diarizer,
                enhancer: enhancer, voiceProcessing: voiceProcessing, fallbackReason: fallbackReason, cleaningNote: cleaningNote,
                speakersNote: speakersNote)
        }

        /// The language the engine prepares for: the meeting's language, or the one language the engine
        /// settings name, else `nil` (the engine chooses). Pass it as the session's `locale`.
        public var locale: Locale? { preferredLocales.count == 1 ? preferredLocales[0] : nil }
    }

    /// A meeting's session, and what to tell the user about the microphone while it runs.
    public struct MixedMeeting: Sendable {
        public let session: MeetingSession
        /// E.g. that LocalVQE fell back to the raw microphone, or that the speaker model is downloading. Ends when
        /// the meeting does.
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

    /// Called when what the heavy steps of a meeting are doing changed; nil stage: they are not running or waiting.
    public var onProgress: (@MainActor (UUID, ProcessingStage?) -> Void)?
    private var stages: [UUID: ProcessingStage] = [:]

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
    /// enhancer when the echo-and-noise setting is LocalVQE.
    ///
    /// A speaker or LocalVQE model that is wanted but not installed (a fresh install) starts downloading in the
    /// background now, and this meeting goes on without it: without live speakers (``Engines/speakersNote``
    /// says so), and, for LocalVQE, with Apple's voice processing on the Mac or the raw mic on the phone
    /// (``Engines/cleaningNote``). The next meeting has it.
    public func engines(for platform: ModelPlatform = .current, locale: Locale? = nil) async -> Engines {
        let live = await registry.liveEngine(localeOverride: locale)
        let mode = settings.echoNoise
        let diarizer = settings.liveDiarization ? await registry.liveDiarizer() : nil
        let enhancer = mode == .localVQE ? await registry.micEnhancer() : nil
        if settings.liveDiarization, diarizer == nil { await download(.liveSpeakers, fallback: FluidAudioModels.sortformerID) }
        if mode == .localVQE, enhancer == nil { await download(.echoNoiseCancellation, fallback: FluidAudioModels.localVqeID) }
        let reason: String? = switch live.fallback {
        case .assetsNotInstalled: "The picked speech model is not installed, so meetings use Apple Speech."
        case .unknownModel: "The picked speech model is not available, so meetings use Apple Speech."
        case nil: nil
        }
        // LocalVQE chosen but not there yet: Apple's voice processing stands in on the Mac.
        let standIn = platform == .macOS && mode == .localVQE && enhancer == nil
        let cleaningNote: String? =
            if mode == .localVQE, enhancer == nil {
                standIn
                    ? "Echo and noise cancellation is downloading, so Apple voice processing cleans the microphone for now."
                    : "Echo and noise cancellation is downloading, so the raw microphone is used for now."
            } else { nil }
        return Engines(
            engine: live.engine, engineID: live.engine.id, preferredLocales: live.preferredLocales, diarizer: diarizer,
            enhancer: enhancer, voiceProcessing: platform == .macOS && (mode == .appleVoiceProcessing || standIn),
            fallbackReason: reason, cleaningNote: cleaningNote,
            speakersNote: settings.liveDiarization && diarizer == nil
                ? "The speaker model is downloading, so speakers appear from the next meeting." : nil)
    }

    /// Starts installing the model for `role` (the pick, else `fallback`) in the background, or joins the
    /// install already running. Returns at once.
    private func download(_ role: ModelRole, fallback: String) async {
        let id = await registry.meetingModelID(role: role, fallback: fallback)
        let manager = registry.models
        Task.detached(priority: .utility) {
            for await _ in await manager.install(id) {}
        }
    }

    /// A new meeting set up from `engines`: its language, and the default summary sections ticked.
    public func newMeeting(
        id: UUID = UUID(), title: String, date: Date = Date(), engines: Engines
    ) -> Meeting {
        Meeting(
            id: id, title: title, date: date, engineID: engines.engineID, locale: engines.locale?.identifier,
            sections: settings.defaultSectionIDs)
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
        let notes = [engines.cleaningNote, engines.speakersNote].compactMap { $0 }
        var notices = AsyncStream<String> { continuation in
            for note in notes { continuation.yield(note) }
            continuation.finish()
        }
        if let enhancer = engines.enhancer {
            let stage = MicCleaningStage(enhancer: enhancer, clock: clock)
            micSource = stage.mic(mic)
            systemSource = system.map(stage.reference)
            let cleaning = stage.notices
            notices = AsyncStream { continuation in
                let relay = Task {
                    for note in notes { continuation.yield(note) }
                    for await note in cleaning { continuation.yield(note) }
                    continuation.finish()
                }
                continuation.onTermination = { _ in relay.cancel() }
            }
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

    /// The on-device backend for Summarize (and the automatic summary), as the stored choice resolves. Never Claude.
    public func summaryBackend() async -> (any LLMBackend)? {
        await cleanup.resolve(preference: settings.backend.preference, background: background).backend
    }

    /// The Claude backend. Used only by ``summarizeWithClaude(meetingID:)``.
    public func claudeBackend() -> any LLMBackend { makeClaude() }

    // MARK: Processing

    /// What the heavy steps of a meeting are doing: waiting in the queue, or running (which step, how far). Nil when
    /// they are neither.
    public func stage(of id: UUID) -> ProcessingStage? { stages[id] }

    private func setStage(_ id: UUID, _ stage: ProcessingStage?) {
        guard stages[id] != stage else { return }
        stages[id] = stage
        onProgress?(id, stage)
    }

    /// A step began or moved on: what the pipeline says goes to the stage, in order.
    private func apply(_ event: PipelineStepEvent, to id: UUID) {
        switch event {
        case .started(let step): setStage(id, .running(step))
        case .progress(let step, let fraction):
            if let current = stages[id] { setStage(id, current.reporting(fraction, for: step)) }
        }
    }

    /// The pipeline whose steps report to the meeting's stage.
    private func pipeline(reportingFor id: UUID) -> MeetingPipeline {
        pipeline().reportingEvents { [weak self] event in await self?.apply(event, to: id) }
    }

    /// Runs `work` with the meeting's stage at `stage`; afterwards the meeting is waiting again if it was queued
    /// before, else it has no stage.
    private func running<T>(_ id: UUID, _ stage: ProcessingStage, _ work: () async throws -> T) async rethrows -> T {
        let before = stages[id]
        setStage(id, stage)
        defer { setStage(id, before == .queued ? .queued : nil) }
        return try await work()
    }

    /// A meeting records (true) or not. Nothing heavy runs while one does: a heavy step already running when a
    /// recording starts is cut short (its meeting stays queued and runs again, from the step it was in, once
    /// the machine is idle after the meeting), and the manual actions refuse to start.
    public func setRecording(_ isRecording: Bool) {
        let started = recording.value.withLock { was -> Bool in
            defer { was = isRecording }
            return isRecording && !was
        }
        if started {
            let scheduler = self.scheduler
            Task { await scheduler.cancelRunning() }
        }
    }

    private var isRecording: Bool { recording.value.withLock { $0 } }

    /// The after-stop chain: m4a, post-pass, speakers, and the on-device summary when it is automatic. `onStep`
    /// reports each finished step.
    /// Run it inside a background task on the phone; see ``MeetingPipeline``.
    public func pipeline(onStep: @escaping @Sendable (Meeting.Step) -> Void = { _ in }) -> MeetingPipeline {
        let registry = self.registry, cleanup = self.cleanup, settings = self.settings
        let background = self.background
        return MeetingPipeline(
            store: store,
            audio: { MeetingAudioWriter(folder: $0) },
            transcriber: { await registry.postPassTranscriber() },
            backend: { await cleanup.resolve(preference: settings.backend.preference, background: background).backend },
            sections: { settings.sections(for: $0) },
            summarizeAutomatically: { settings.summarizeAutomatically },
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
        setStage(id, stages[id] ?? .queued)
        if settings.idleProcessing { await scheduler.enqueue(id) } else { await scheduler.processNow(id) }
        return outcome
    }

    /// "Process now": the heavy steps of this meeting without waiting for an idle machine (never during a recording).
    public func processNow(_ id: UUID) async {
        setStage(id, stages[id] ?? .queued)
        await scheduler.processNow(id)
    }

    /// "Improve transcript": the post-pass again, then the summary again when there was one (or it is automatic).
    /// - Throws: ``MeetingServicesError/recording`` while a meeting records (it would free the live model).
    @discardableResult
    public func improveTranscript(meetingID: UUID) async throws -> MeetingPipeline.Outcome {
        guard !isRecording else { throw MeetingServicesError.recording }
        return try await running(meetingID, .running(nil)) {
            try await pipeline(reportingFor: meetingID).improveTranscript(meetingID: meetingID)
        }
    }

    /// Summarize, and Regenerate: the summary with the on-device backend (the meeting's ticked sections, notes,
    /// speakers and language). It shows as the meeting's `.summary` stage while it runs.
    /// - Throws: ``MeetingServicesError/recording`` while a meeting records; ``LLMError/unavailable(reason:)``
    ///   when no on-device model is usable.
    @discardableResult
    public func regenerate(meetingID: UUID) async throws -> URL {
        guard !isRecording else { throw MeetingServicesError.recording }
        guard let backend = await summaryBackend() else {
            throw LLMError.unavailable(reason: "No on-device model is available for a summary.")
        }
        return try await running(meetingID, .running(.summary)) {
            try await pipeline(reportingFor: meetingID).summarize(meetingID: meetingID, using: backend)
        }
    }

    /// The scheduler's job: the deferred steps. False (stay queued) when cut short or to be retried.
    private func runDeferred(_ id: UUID) async -> Bool {
        setStage(id, .running(nil))
        do {
            let outcome = try await pipeline(reportingFor: id).runDeferred(meetingID: id)
            // A step failed: the meeting stays queued and is tried again (a few times; see MeetingPipeline).
            setStage(id, outcome.willRetry ? .queued : nil)
            onProcessed?(id, outcome, nil)
            if outcome.willRetry { return false }
        } catch is CancellationError {
            setStage(id, .queued)  // cut short (a recording started): waiting again
            onProcessed?(id, nil, CancellationError())
            return false
        } catch {
            setStage(id, nil)
            onProcessed?(id, nil, error)
        }
        return true
    }

    /// Summarises one meeting with Claude, after the user asked for it, with the meeting's ticked sections.
    /// Writes `summaries/claude.md`.
    /// - Throws: ``MeetingServicesError/recording`` while a meeting records; ``LLMError/unavailable(reason:)``
    ///   when there is no key.
    @discardableResult
    public func summarizeWithClaude(meetingID: UUID) async throws -> URL {
        guard !isRecording else { throw MeetingServicesError.recording }
        let claude = claudeBackend()
        if case .unavailable(let reason) = await claude.availability { throw LLMError.unavailable(reason: reason) }
        return try await running(meetingID, .running(.summary)) {
            try await pipeline(reportingFor: meetingID).summarize(meetingID: meetingID, using: claude)
        }
    }
}
