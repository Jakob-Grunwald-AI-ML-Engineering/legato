import Foundation
import LegatoAudio
import LegatoCore
import LegatoFluidAudio
import LegatoMeetings

/// A meeting's recorded audio, read for the post-pass and then converted from CAF to m4a.
public protocol MeetingAudioFinalizing: AudioSampleReader {
    /// Converts the recordings to m4a. Safe to repeat: with nothing left to convert it does nothing.
    /// - Returns: the streams that could not be converted (their CAF is kept); empty when all went well.
    func finalizeAudio() async throws -> [TranscriptEvent.Stream]
}

extension MeetingAudioWriter: MeetingAudioFinalizing {
    public func finalizeAudio() async throws -> [TranscriptEvent.Stream] {
        Array(finalize().failed.keys).sorted { $0.rawValue < $1.rawValue }
    }
}

/// The after-stop chain of a meeting: post-pass, CAF to m4a, automatic summary, then `finished`.
///
/// Every step is recorded on the ``Meeting`` (``Meeting/completedSteps``) as it finishes, so a run that was
/// interrupted (the app suspended or killed) continues after the last finished step when run again. The
/// pipeline throws `CancellationError` when cancelled and leaves the meeting `processing`.
///
/// It imports no UI framework. The phone app wraps ``run(meetingID:)`` in a background task and cancels it
/// when iOS is about to suspend the app; `onStep` reports progress.
public struct MeetingPipeline: Sendable {
    /// What a run did that the caller may want to show.
    public struct Outcome: Sendable, Equatable {
        /// The backend that wrote the automatic summary; `nil` when none did.
        public var summaryBackendID: String?
        /// What was skipped or failed, in words for the log or the detail view.
        public var notes: [String] = []
    }

    private let store: MeetingStore
    private let audio: @Sendable (URL) -> any MeetingAudioFinalizing
    private let transcriber: @Sendable () async -> (any BatchTranscriber)?
    private let backend: @Sendable () async -> (any LLMBackend)?
    private let prompt: @Sendable () -> String
    private let releaseModels: @Sendable () async -> Void
    private let releasePostPassModels: @Sendable () async -> Void
    private let onStep: @Sendable (Meeting.Step) -> Void

    /// - Parameters:
    ///   - audio: the recordings of the meeting whose folder is given.
    ///   - transcriber: the post-pass model, if one is installed.
    ///   - backend: the on-device summary backend, if one is usable. Never Claude.
    ///   - prompt: the custom summary prompt; empty means the default.
    ///   - releaseModels: frees the live models before the post-pass model loads.
    ///   - releasePostPassModels: frees the post-pass model once the post-pass is over, before the summary model loads.
    public init(
        store: MeetingStore,
        audio: @escaping @Sendable (URL) -> any MeetingAudioFinalizing,
        transcriber: @escaping @Sendable () async -> (any BatchTranscriber)?,
        backend: @escaping @Sendable () async -> (any LLMBackend)?,
        prompt: @escaping @Sendable () -> String,
        releaseModels: @escaping @Sendable () async -> Void = { await releaseCachedNemotronModels() },
        releasePostPassModels: @escaping @Sendable () async -> Void = { await releaseCachedParakeetModels() },
        onStep: @escaping @Sendable (Meeting.Step) -> Void = { _ in }
    ) {
        self.store = store
        self.audio = audio
        self.transcriber = transcriber
        self.backend = backend
        self.prompt = prompt
        self.releaseModels = releaseModels
        self.releasePostPassModels = releasePostPassModels
        self.onStep = onStep
    }

    /// This pipeline, also calling `onStep` after each step finishes.
    public func reporting(_ onStep: @escaping @Sendable (Meeting.Step) -> Void) -> MeetingPipeline {
        let previous = self.onStep
        return MeetingPipeline(
            store: store, audio: audio, transcriber: transcriber, backend: backend, prompt: prompt,
            releaseModels: releaseModels, releasePostPassModels: releasePostPassModels,
            onStep: { previous($0); onStep($0) })
    }

    // MARK: Chain

    /// Runs the steps of a `processing` or `interrupted` meeting that are not done yet. Any other meeting is
    /// left alone.
    @discardableResult
    public func run(meetingID: UUID) async throws -> Outcome {
        var outcome = Outcome()
        guard let meeting = try await store.meeting(id: meetingID), meeting.state == .processing || meeting.state == .interrupted
        else { return outcome }
        let recordings = audio(await store.folder(for: meetingID))

        if !meeting.completedSteps.contains(.postPass), let batch = await transcriber() {
            await releaseModels()
            do {
                try await MeetingPostPass(store: store, reader: recordings, transcriber: batch).run(meetingID: meetingID)
                try await complete(.postPass, meetingID)
            } catch is CancellationError {
                await releasePostPassModels()
                throw CancellationError()
            } catch {
                outcome.notes.append("The post-pass failed, so the live transcript stays: \(error)")
            }
            // The summary model needs the memory the batch model held.
            await releasePostPassModels()
        }

        if !meeting.completedSteps.contains(.audio) {
            let failed = try await recordings.finalizeAudio()
            if failed.isEmpty {
                try await complete(.audio, meetingID)
            } else {
                let names = failed.map { $0 == .mic ? "mic" : "system" }.joined(separator: " and ")
                outcome.notes.append("The \(names) audio could not be converted to m4a, so its CAF recording is kept.")
            }
        }

        if !meeting.completedSteps.contains(.summary) {
            try await automaticSummary(meetingID, outcome: &outcome)
        }

        try await finish(meetingID)
        return outcome
    }

    /// "Improve transcript": the post-pass again (from the m4a), then the summary again.
    @discardableResult
    public func improveTranscript(meetingID: UUID) async throws -> Outcome {
        guard let meeting = try await store.meeting(id: meetingID), meeting.state != .recording else { return Outcome() }
        try await store.update(id: meetingID) { m in
            m.state = .processing
            m.completedSteps.subtract([.postPass, .summary])
        }
        return try await run(meetingID: meetingID)
    }

    /// An explicit summary with `backend` (the per-meeting "Summarize with Claude"). Writes the backend's
    /// own summary file and changes nothing else about the meeting. Returns the file.
    @discardableResult
    public func summarize(meetingID: UUID, using backend: any LLMBackend) async throws -> URL {
        let segments = try await store.segments(for: meetingID)
        let text = try await MeetingSummarizer(backend: backend, prompt: prompt()).summarize(segments: segments)
        try await store.saveSummary(text, backendID: backend.id, for: meetingID)
        return await store.summaryURL(for: meetingID, backendID: backend.id)
    }

    // MARK: Steps

    private func automaticSummary(_ meetingID: UUID, outcome: inout Outcome) async throws {
        guard let model = await backend() else {
            outcome.notes.append("No on-device model is available for a summary.")
            return
        }
        do {
            try await summarize(meetingID: meetingID, using: model)
            outcome.summaryBackendID = model.id
            try await complete(.summary, meetingID)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as LLMError {
            outcome.notes.append("The summary was not written: \(error)")
        }
    }

    private func complete(_ step: Meeting.Step, _ meetingID: UUID) async throws {
        guard try await store.update(id: meetingID, { $0.completedSteps.insert(step) }) != nil else { return }
        onStep(step)
    }

    private func finish(_ meetingID: UUID) async throws {
        try await store.update(id: meetingID) { $0.state = .finished }
    }
}
