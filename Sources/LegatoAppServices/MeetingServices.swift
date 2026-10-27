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

/// What an app needs to record, process and summarise meetings, built on its ``ModelServices``: the engines
/// for a meeting, the post-pass model, the on-device summary backend and the after-stop chain.
///
/// The automatic chain never uses Claude. Claude runs only through ``summarizeWithClaude(meetingID:)``,
/// which the user asks for per meeting.
@MainActor
public final class MeetingServices {
    /// The live engines for one meeting.
    public struct Engines: Sendable {
        /// The engine for the microphone stream.
        public let mic: any DictationEngine
        /// The engine for the system-audio stream (a separate instance); `nil` where there is one stream (iOS).
        public let system: (any DictationEngine)?
        /// The id recorded on the meeting (`Meeting.engineID`).
        public let engineID: String
        public let preferredLocales: [Locale]
        /// Why Apple Speech runs although another model is picked, for the UI; `nil` otherwise.
        public let fallbackReason: String?

        /// The language the engines prepare for: the one language the engine settings name, else `nil`
        /// (the engine chooses). Pass it as ``MeetingInput/locale``.
        public var locale: Locale? { preferredLocales.count == 1 ? preferredLocales[0] : nil }
    }

    public let settings: MeetingSettings
    public let store: MeetingStore

    private let registry: EngineRegistry
    private let cleanup: CleanupRegistry
    private let background: CleanupRegistry.BackgroundCleanup
    private let makeClaude: @Sendable () -> any LLMBackend

    /// - Parameters:
    ///   - cleanup: the registry the summary backend resolves through; the models' own by default.
    ///   - background: what the summary does while the GPU is not usable (the phone in the background).
    ///   - claudeBackend: replaces the Claude backend (tests); nil builds a ``ClaudeBackend`` over `keyStore`.
    public init(
        models: ModelServices, store: MeetingStore, settings: MeetingSettings, keyStore: any APIKeyStore,
        claudeSession: URLSession? = nil, cleanup: CleanupRegistry? = nil,
        claudeBackend: (any LLMBackend)? = nil, background: CleanupRegistry.BackgroundCleanup = .cpu
    ) {
        self.store = store
        self.settings = settings
        self.registry = models.engines
        self.cleanup = cleanup ?? models.cleanup
        self.background = background
        self.makeClaude = { claudeBackend ?? claudeSession.map { ClaudeBackend(keyStore: keyStore, session: $0) } ?? ClaudeBackend(keyStore: keyStore) }
    }

    // MARK: Engines

    /// The engines for a meeting on `platform`: the live dictation pick, one instance per stream on the
    /// Mac and one on iOS. Parakeet EOU serves one session at a time, so on the Mac it becomes Apple Speech
    /// for both streams, with a reason for the UI.
    public func engines(for platform: ModelPlatform = .current) async -> Engines {
        let first = await registry.liveEngine()
        guard platform == .macOS else {
            return Engines(
                mic: first.engine, system: nil, engineID: first.engine.id, preferredLocales: first.preferredLocales,
                fallbackReason: nil)
        }
        if let id = first.modelID, Self.isEOU(id) {
            return Engines(
                mic: AppleSpeechEngine(), system: AppleSpeechEngine(), engineID: "apple-speech",
                preferredLocales: first.preferredLocales,
                fallbackReason: "Parakeet EOU can transcribe only one stream at a time, so meetings use Apple Speech for both.")
        }
        let second = await registry.liveEngine()
        return Engines(
            mic: first.engine, system: second.engine, engineID: first.engine.id,
            preferredLocales: first.preferredLocales, fallbackReason: nil)
    }

    private static func isEOU(_ modelID: String) -> Bool {
        EouChunk.allCases.contains { FluidAudioModels.eouID($0) == modelID }
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

    /// The after-stop chain: post-pass, m4a, on-device summary. `onStep` reports each finished step.
    /// Run it inside a background task on the phone; see ``MeetingPipeline``.
    public func pipeline(onStep: @escaping @Sendable (Meeting.Step) -> Void = { _ in }) -> MeetingPipeline {
        let registry = self.registry, cleanup = self.cleanup, settings = self.settings
        let background = self.background
        return MeetingPipeline(
            store: store,
            audio: { MeetingAudioWriter(folder: $0) },
            transcriber: { await registry.postPassTranscriber() },
            backend: { await cleanup.resolve(preference: settings.backend.preference, background: background).backend },
            prompt: { settings.customPrompt },
            onStep: onStep)
    }

    /// Summarises one meeting with Claude, after the user asked for it. Writes `summary-claude.md`.
    /// - Throws: ``LLMError/unavailable(reason:)`` when there is no key.
    @discardableResult
    public func summarizeWithClaude(meetingID: UUID) async throws -> URL {
        let claude = claudeBackend()
        if case .unavailable(let reason) = await claude.availability { throw LLMError.unavailable(reason: reason) }
        return try await pipeline().summarize(meetingID: meetingID, using: claude)
    }
}
