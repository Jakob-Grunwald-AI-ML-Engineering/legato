import Foundation
import LegatoAudio
import LegatoCore
import LegatoFluidAudio
import LegatoMeetings

/// A meeting's recorded audio: converted to m4a at stop, read lossless (CAF) by the heavy steps, then the CAF dropped.
public protocol MeetingAudioFinalizing: AudioSampleReader {
    /// Converts the recordings to m4a, keeping the CAFs. Safe to repeat.
    /// - Returns: the streams that could not be converted (their CAF is kept); empty when all went well.
    func finalizeAudio() async throws -> [TranscriptEvent.Stream]
    /// Deletes the lossless CAF of every stream that has an m4a. Called once the heavy steps are over.
    func discardLosslessAudio() async
    /// The file `stream` is recorded in now: its CAF, else its m4a; nil when there is neither.
    func recordingURL(of stream: TranscriptEvent.Stream) -> URL?
}

extension MeetingAudioWriter: MeetingAudioFinalizing {
    public func finalizeAudio() async throws -> [TranscriptEvent.Stream] {
        Array(finalize().failed.keys).sorted { $0.rawValue < $1.rawValue }
    }

    public func discardLosslessAudio() async { discardLossless() }
}

/// What a running pipeline says about its steps, for the banner: a step began, and how far it is.
public enum PipelineStepEvent: Sendable, Equatable {
    case started(Meeting.Step)
    /// 0 to 1. Only steps that can tell report it: the post-pass (windows), the speaker pass (the model's chunks)
    /// and the summary (chunks of the transcript, then the merge).
    case progress(Meeting.Step, Double)
}

/// The after-stop chain of a meeting, in two parts.
///
/// - ``runAudio(meetingID:)`` is cheap and runs at once when the meeting stops: the CAF tracks become m4a
///   (`mix.m4a` too), so the meeting plays from the m4a. The CAFs stay.
/// - ``runDeferred(meetingID:)`` is heavy and runs when the machine is idle (see ``ProcessingScheduler``): the
///   post-pass on the mix (Parakeet, if one is picked), the after-meeting speaker pass (if on and installed),
///   then `finished`. The on-device summary (the meeting's sections, notes, speakers and language) runs here only
///   when it is automatic; otherwise the user asks for it (``summarize(meetingID:using:)``) once they have named
///   the speakers. The post-pass and the speaker pass read the lossless CAF; once both are done or skipped the
///   CAFs are deleted. A meeting whose CAFs are gone is read from the m4a.
/// - **A failed step** (post-pass or speaker pass) keeps the CAFs and leaves the meeting `processing`, so the
///   next run tries it again (``Outcome/willRetry``); an automatic summary is still written from what there is,
///   and written again once a retry succeeds. After ``maxAttempts`` failed runs in a row the meeting is
///   `finished` with its CAFs kept, and "Improve transcript" is the way to try again.
///
/// ``run(meetingID:)`` is both, one after the other.
///
/// Every step is recorded on the ``Meeting`` (``Meeting/completedSteps``) as it finishes, so a run that was
/// interrupted (the app suspended or killed) continues after the last finished step when run again. The
/// pipeline throws `CancellationError` when cancelled and leaves the meeting `processing`. A step that is off
/// or has no model is skipped, and is looked at again on the next run.
///
/// It imports no UI framework. The phone app wraps a run in a background task and cancels it when iOS is
/// about to suspend the app; `onStep` reports progress.
public struct MeetingPipeline: Sendable {
    /// What a run did that the caller may want to show.
    /// Failed runs in a row after which the heavy steps are no longer retried by themselves.
    public static let maxAttempts = 3

    public struct Outcome: Sendable, Equatable {
        /// The backend that wrote the automatic summary; `nil` when none did.
        public var summaryBackendID: String?
        /// What was skipped or failed, in words for the log or the detail view.
        public var notes: [String] = []
        /// A step failed and the meeting stays `processing` for another run.
        public var willRetry = false
    }

    private let store: MeetingStore
    private let audio: @Sendable (URL) -> any MeetingAudioFinalizing
    private let transcriber: @Sendable () async -> (any BatchTranscriber)?
    private let backend: @Sendable () async -> (any LLMBackend)?
    private let sections: @Sendable (Meeting) -> [SummarySection]
    private let summarizeAutomatically: @Sendable () -> Bool
    private let batchDiarizer: @Sendable () async -> (any BatchDiarizer)?
    private let diarizationEnabled: @Sendable () -> Bool
    private let releaseDiarizer: @Sendable () async -> Void
    private let releaseModels: @Sendable () async -> Void
    private let releasePostPassModels: @Sendable () async -> Void
    private var onStep: @Sendable (Meeting.Step) -> Void
    private var onEvent: @Sendable (PipelineStepEvent) async -> Void = { _ in }

    /// - Parameters:
    ///   - audio: the recordings of the meeting whose folder is given.
    ///   - transcriber: the post-pass model, if one is installed.
    ///   - backend: the on-device summary backend, if one is usable. Never Claude.
    ///   - sections: the sections a meeting's summary holds (its ticks in the configured order); the default
    ///     sections when it returns none.
    ///   - summarizeAutomatically: the setting that adds the summary to the deferred steps.
    ///   - batchDiarizer: the after-meeting speaker model, if installed.
    ///   - diarizationEnabled: the setting for the after-meeting speaker pass.
    ///   - releaseDiarizer: frees the speaker model once its step is over.
    ///   - releaseModels: frees the live models before the post-pass model loads.
    ///   - releasePostPassModels: frees the post-pass model once the post-pass is over, before the next model loads.
    public init(
        store: MeetingStore,
        audio: @escaping @Sendable (URL) -> any MeetingAudioFinalizing,
        transcriber: @escaping @Sendable () async -> (any BatchTranscriber)?,
        backend: @escaping @Sendable () async -> (any LLMBackend)?,
        sections: @escaping @Sendable (Meeting) -> [SummarySection] = {
            SummarySection.resolve($0.sections ?? SummarySection.defaultIDs, in: SummarySection.builtIns)
        },
        summarizeAutomatically: @escaping @Sendable () -> Bool = { false },
        batchDiarizer: @escaping @Sendable () async -> (any BatchDiarizer)? = { nil },
        diarizationEnabled: @escaping @Sendable () -> Bool = { true },
        releaseDiarizer: @escaping @Sendable () async -> Void = {},
        releaseModels: @escaping @Sendable () async -> Void = { await releaseCachedNemotronModels() },
        releasePostPassModels: @escaping @Sendable () async -> Void = { await releaseCachedParakeetModels() },
        onStep: @escaping @Sendable (Meeting.Step) -> Void = { _ in }
    ) {
        self.store = store
        self.audio = audio
        self.transcriber = transcriber
        self.backend = backend
        self.sections = sections
        self.summarizeAutomatically = summarizeAutomatically
        self.batchDiarizer = batchDiarizer
        self.diarizationEnabled = diarizationEnabled
        self.releaseDiarizer = releaseDiarizer
        self.releaseModels = releaseModels
        self.releasePostPassModels = releasePostPassModels
        self.onStep = onStep
    }

    /// This pipeline, also calling `onStep` after each step finishes.
    public func reporting(_ onStep: @escaping @Sendable (Meeting.Step) -> Void) -> MeetingPipeline {
        var copy = self
        let previous = self.onStep
        copy.onStep = { previous($0); onStep($0) }
        return copy
    }

    /// This pipeline, also telling `onEvent` when each step starts and how far it is. Events come in the order
    /// they happen: `onEvent` has returned for one before the next is sent.
    public func reportingEvents(_ onEvent: @escaping @Sendable (PipelineStepEvent) async -> Void) -> MeetingPipeline {
        var copy = self
        let previous = self.onEvent
        copy.onEvent = { await previous($0); await onEvent($0) }
        return copy
    }

    // MARK: Chain

    /// The audio step, then the deferred steps. A meeting that is not `processing` or `interrupted` is left alone.
    @discardableResult
    public func run(meetingID: UUID) async throws -> Outcome {
        try await run(meetingID: meetingID, summary: summarizeAutomatically())
    }

    private func run(meetingID: UUID, summary: Bool) async throws -> Outcome {
        var outcome = try await runAudio(meetingID: meetingID)
        let rest = try await runDeferred(meetingID: meetingID, summary: summary)
        outcome.summaryBackendID = rest.summaryBackendID
        outcome.notes += rest.notes
        outcome.willRetry = rest.willRetry
        return outcome
    }

    /// Converts the recordings to m4a (the `.audio` step), unless that is done. The meeting stays `processing`:
    /// the heavy steps are still to come.
    @discardableResult
    public func runAudio(meetingID: UUID) async throws -> Outcome {
        var outcome = Outcome()
        guard let meeting = try await processable(meetingID), !meeting.completedSteps.contains(.audio) else { return outcome }
        await onEvent(.started(.audio))
        let failed = try await audio(await store.folder(for: meetingID)).finalizeAudio()
        if failed.isEmpty {
            try await complete(.audio, meetingID)
        } else {
            let names = failed.map { Self.trackName($0) }.joined(separator: " and ")
            outcome.notes.append("The \(names) audio could not be converted to m4a, so its CAF recording is kept.")
        }
        return outcome
    }

    /// The heavy steps that are not done yet, in order (post-pass, speakers, and the summary when it is
    /// automatic), then `finished`. Models are released as soon as their step is over: the live ones before the
    /// post-pass loads, the post-pass and speaker models after their steps.
    @discardableResult
    public func runDeferred(meetingID: UUID) async throws -> Outcome {
        try await runDeferred(meetingID: meetingID, summary: summarizeAutomatically())
    }

    /// - Parameter summary: write the summary (when it is not done, or a step improved the transcript).
    private func runDeferred(meetingID: UUID, summary: Bool) async throws -> Outcome {
        var outcome = Outcome()
        guard let meeting = try await processable(meetingID) else { return outcome }
        let recordings = audio(await store.folder(for: meetingID))
        var stepFailed = false
        // A step that succeeded after the summary was written (a retry): the summary is written again.
        var improved = false

        if !meeting.completedSteps.contains(.postPass), let batch = await transcriber() {
            await onEvent(.started(.postPass))
            try Task.checkCancellation()  // never free the live models for a job that was just cut short
            await releaseModels()
            do {
                let report = onEvent
                try await MeetingPostPass(store: store, reader: recordings, transcriber: batch)
                    .run(meetingID: meetingID, progress: { await report(.progress(.postPass, $0)) })
                try await complete(.postPass, meetingID)
                improved = true
            } catch is CancellationError {
                await releasePostPassModels()
                throw CancellationError()
            } catch {
                stepFailed = true
                outcome.notes.append("The post-pass failed, so the live transcript stays: \(error)")
            }
            // The next model needs the memory the batch model held.
            await releasePostPassModels()
        }

        if !meeting.completedSteps.contains(.diarize), diarizationEnabled(), let diarizer = await batchDiarizer() {
            switch try await diarize(meetingID, with: diarizer, recordings: recordings, outcome: &outcome) {
            case true?: improved = true
            case false?: stepFailed = true
            case nil: break
            }
        }

        if !stepFailed { await recordings.discardLosslessAudio() }

        if summary, !meeting.completedSteps.contains(.summary) || improved {
            await onEvent(.started(.summary))
            try await automaticSummary(meetingID, outcome: &outcome)
        }

        let failedRuns = stepFailed ? meeting.failedRuns + 1 : 0
        if stepFailed, failedRuns < Self.maxAttempts {
            try await store.update(id: meetingID) { $0.failedRuns = failedRuns }
            outcome.willRetry = true
            return outcome
        }
        try await store.update(id: meetingID) { m in
            m.failedRuns = failedRuns
            m.state = .finished
        }
        return outcome
    }

    /// "Improve transcript": the post-pass again (from the m4a, the CAF being gone), then the summary again when
    /// there was one (or it is automatic).
    @discardableResult
    public func improveTranscript(meetingID: UUID) async throws -> Outcome {
        guard let meeting = try await store.meeting(id: meetingID), meeting.state != .recording else { return Outcome() }
        let hadSummary = meeting.completedSteps.contains(.summary)
        try await store.update(id: meetingID) { m in
            m.state = .processing
            m.completedSteps.subtract([.postPass, .summary])
            m.failedRuns = 0
        }
        return try await run(meetingID: meetingID, summary: hadSummary || summarizeAutomatically())
    }

    /// A summary with `backend` (Summarize, Regenerate, "Summarize with Claude", and the automatic one): the
    /// meeting's ticked sections, its notes, its speakers' names and its language. Writes the backend's summary
    /// file with the sections it holds, and records the `.summary` step; a meeting that ticked nothing of its own
    /// keeps the sections it was summarised with, so a later change of the default does not make it stale. Its
    /// state is left alone. Returns the file.
    @discardableResult
    public func summarize(meetingID: UUID, using backend: any LLMBackend) async throws -> URL {
        let report = onEvent
        let meeting = try await store.meeting(id: meetingID)
        let segments = try await store.segments(for: meetingID)
        let notes = (try? await store.notes(for: meetingID)) ?? ""
        let picked = meeting.map(sections) ?? []
        let ticked = picked.isEmpty ? SummarySection.resolve(SummarySection.defaultIDs, in: SummarySection.builtIns) : picked
        let text = try await MeetingSummarizer(
            backend: backend, sections: ticked, notes: notes, language: meeting?.locale, speakers: meeting?.speakers ?? [:]
        ).summarize(segments: segments, progress: { await report(.progress(.summary, $0)) })
        let ids = ticked.map(\.id)
        try await store.saveSummary(text, backendID: backend.id, sections: ids, for: meetingID)
        try await store.update(id: meetingID) { m in
            if m.sections == nil { m.sections = ids }
        }
        try await complete(.summary, meetingID)
        return await store.summaryURL(for: meetingID, backendID: backend.id)
    }

    // MARK: Steps

    /// The meeting if it is waiting for processing.
    private func processable(_ meetingID: UUID) async throws -> Meeting? {
        guard let meeting = try await store.meeting(id: meetingID), meeting.state == .processing || meeting.state == .interrupted
        else { return nil }
        return meeting
    }

    private func automaticSummary(_ meetingID: UUID, outcome: inout Outcome) async throws {
        guard let model = await backend() else {
            outcome.notes.append("No on-device model is available for a summary.")
            return
        }
        do {
            try await summarize(meetingID: meetingID, using: model)
            outcome.summaryBackendID = model.id
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as LLMError {
            outcome.notes.append("The summary was not written: \(error)")
        }
    }

    /// The after-meeting speaker pass over the mix. The diarizer reads the mix recording from disk itself, so
    /// the meeting is never held in memory whole. It maps the offline clusters onto the people the live pass
    /// already found (keeping their names and merges), adds new people for the rest, and gives every segment
    /// its speaker from the new turns. A meeting with no mix recording (one from before the mix) is skipped.
    /// - Returns: true when the speakers were updated, false when the pass failed, nil when it was skipped.
    private func diarize(
        _ meetingID: UUID, with diarizer: any BatchDiarizer, recordings: any MeetingAudioFinalizing,
        outcome: inout Outcome
    ) async throws -> Bool? {
        let duration = (try? await recordings.duration(of: .mixed)) ?? 0
        guard duration > 0, let mix = recordings.recordingURL(of: .mixed) else { return nil }
        let turns: [SpeakerTurn]
        // The model reports from its own thread; one task passes the reports on in order.
        let (reports, reporter) = AsyncStream<Double>.makeStream()
        let report = onEvent
        let forwarding = Task { for await fraction in reports { await report(.progress(.diarize, fraction)) } }
        do {
            try Task.checkCancellation()
            await onEvent(.started(.diarize))
            turns = try await diarizer.diarize(file: mix, progress: { reporter.yield($0) })
            reporter.finish()
            await forwarding.value
            try Task.checkCancellation()
        } catch is CancellationError {
            reporter.finish()
            await releaseDiarizer()
            throw CancellationError()
        } catch {
            reporter.finish()
            await releaseDiarizer()
            outcome.notes.append("The speaker pass failed, so the speakers stay as they were: \(error)")
            return false
        }
        await releaseDiarizer()

        guard let meeting = try await store.meeting(id: meetingID) else { return nil }
        var directory = SpeakerDirectory(meeting: meeting)
        let mapped = SpeakerAssigner.mapOffline(
            turns, onto: try await store.liveTurns(for: meetingID), directory: &directory)

        try await store.saveOfflineTurns(mapped, for: meetingID)
        let segments = try await store.segments(for: meetingID)
        try await store.replaceSegments(SpeakerAssigner.assign(segments, turns: mapped), for: meetingID)  // already in order
        let people = directory.speakers
        // Only the speakers: the meeting may have been renamed, or its people edited, while this ran.
        try await store.update(id: meetingID) { m in
            for (id, info) in people where m.speakers[id] == nil && m.mergedSpeakers[id] == nil { m.speakers[id] = info }
        }
        try await complete(.diarize, meetingID)
        return true
    }

    private static func trackName(_ stream: TranscriptEvent.Stream) -> String {
        switch stream {
        case .mic: "mic"
        case .system: "system"
        case .mixed: "mix"
        }
    }

    private func complete(_ step: Meeting.Step, _ meetingID: UUID) async throws {
        guard try await store.update(id: meetingID, { $0.completedSteps.insert(step) }) != nil else { return }
        onStep(step)
    }

}
