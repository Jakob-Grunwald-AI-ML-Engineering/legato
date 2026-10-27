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

/// The after-stop chain of a meeting, in two parts.
///
/// - ``runAudio(meetingID:)`` is cheap and runs at once when the meeting stops: the CAF tracks become m4a
///   (`mix.m4a` too), so the meeting plays from the m4a.
/// - ``runDeferred(meetingID:)`` is heavy and runs when the machine is idle (see ``ProcessingScheduler``): the
///   post-pass on the mix (Parakeet, if one is picked), the after-meeting speaker pass (if on and installed),
///   the on-device summary with the meeting's template, notes, speakers and language, then `finished`.
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
    public struct Outcome: Sendable, Equatable {
        /// The backend that wrote the automatic summary; `nil` when none did.
        public var summaryBackendID: String?
        /// What was skipped or failed, in words for the log or the detail view.
        public var notes: [String] = []
    }

    /// Seconds of the mix read into memory at a time.
    private static let readWindow: TimeInterval = 300

    private let store: MeetingStore
    private let audio: @Sendable (URL) -> any MeetingAudioFinalizing
    private let transcriber: @Sendable () async -> (any BatchTranscriber)?
    private let backend: @Sendable () async -> (any LLMBackend)?
    private let templates: @Sendable () -> [SummaryTemplate]
    private let batchDiarizer: @Sendable () async -> (any EnrollmentBatchDiarizer)?
    private let diarizationEnabled: @Sendable () -> Bool
    private let releaseDiarizer: @Sendable () async -> Void
    private let releaseModels: @Sendable () async -> Void
    private let releasePostPassModels: @Sendable () async -> Void
    private var onStep: @Sendable (Meeting.Step) -> Void

    /// - Parameters:
    ///   - audio: the recordings of the meeting whose folder is given.
    ///   - transcriber: the post-pass model, if one is installed.
    ///   - backend: the on-device summary backend, if one is usable. Never Claude.
    ///   - templates: the user's own summary templates; a meeting's template is looked up among the built-ins and these.
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
        templates: @escaping @Sendable () -> [SummaryTemplate] = { [] },
        batchDiarizer: @escaping @Sendable () async -> (any EnrollmentBatchDiarizer)? = { nil },
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
        self.templates = templates
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

    // MARK: Chain

    /// The audio step, then the deferred steps. A meeting that is not `processing` or `interrupted` is left alone.
    @discardableResult
    public func run(meetingID: UUID) async throws -> Outcome {
        var outcome = try await runAudio(meetingID: meetingID)
        let rest = try await runDeferred(meetingID: meetingID)
        outcome.summaryBackendID = rest.summaryBackendID
        outcome.notes += rest.notes
        return outcome
    }

    /// Converts the recordings to m4a (the `.audio` step), unless that is done. The meeting stays `processing`:
    /// the heavy steps are still to come.
    @discardableResult
    public func runAudio(meetingID: UUID) async throws -> Outcome {
        var outcome = Outcome()
        guard let meeting = try await processable(meetingID), !meeting.completedSteps.contains(.audio) else { return outcome }
        let failed = try await audio(await store.folder(for: meetingID)).finalizeAudio()
        if failed.isEmpty {
            try await complete(.audio, meetingID)
        } else {
            let names = failed.map { Self.trackName($0) }.joined(separator: " and ")
            outcome.notes.append("The \(names) audio could not be converted to m4a, so its CAF recording is kept.")
        }
        return outcome
    }

    /// The heavy steps that are not done yet, in order (post-pass, speakers, summary), then `finished`.
    /// Models are released as soon as their step is over: the live ones before the post-pass loads, the
    /// post-pass and speaker models after their steps.
    @discardableResult
    public func runDeferred(meetingID: UUID) async throws -> Outcome {
        var outcome = Outcome()
        guard let meeting = try await processable(meetingID) else { return outcome }
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
            // The next model needs the memory the batch model held.
            await releasePostPassModels()
        }

        if !meeting.completedSteps.contains(.diarize), diarizationEnabled(), let diarizer = await batchDiarizer() {
            try await diarize(meetingID, with: diarizer, recordings: recordings, outcome: &outcome)
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

    /// An explicit summary with `backend` (the per-meeting "Summarize with Claude", and Regenerate): the
    /// meeting's template, its notes, its speakers' names and its language. Writes the backend's own summary
    /// file and changes nothing else about the meeting. Returns the file.
    @discardableResult
    public func summarize(meetingID: UUID, using backend: any LLMBackend) async throws -> URL {
        let meeting = try await store.meeting(id: meetingID)
        let segments = try await store.segments(for: meetingID)
        let notes = (try? await store.notes(for: meetingID)) ?? ""
        let template = SummaryTemplate.find(meeting?.templateID ?? SummaryTemplate.summaryID, custom: templates()) ?? .summary
        let text = try await MeetingSummarizer(
            backend: backend, template: template, notes: notes, language: meeting?.locale, speakers: meeting?.speakers ?? [:]
        ).summarize(segments: segments)
        try await store.saveSummary(text, backendID: backend.id, templateID: template.id, for: meetingID)
        return await store.summaryURL(for: meetingID, templateID: template.id, backendID: backend.id)
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
            try await complete(.summary, meetingID)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as LLMError {
            outcome.notes.append("The summary was not written: \(error)")
        }
    }

    /// The after-meeting speaker pass over the mix. It maps the offline clusters onto the people the live
    /// pass already found (keeping their names and merges), adds new people for the rest, and gives every segment its speaker from the new turns. A meeting with no
    /// mix recording (one from before the mix) is skipped.
    private func diarize(
        _ meetingID: UUID, with diarizer: any EnrollmentBatchDiarizer, recordings: any MeetingAudioFinalizing,
        outcome: inout Outcome
    ) async throws {
        let duration = (try? await recordings.duration(of: .mixed)) ?? 0
        guard duration > 0 else { return }
        let result: BatchDiarization
        do {
            let samples = try await Self.read(.mixed, duration: duration, from: recordings)
            result = try await diarizer.diarize(samples: samples, enrollment: nil)
        } catch is CancellationError {
            await releaseDiarizer()
            throw CancellationError()
        } catch {
            await releaseDiarizer()
            outcome.notes.append("The speaker pass failed, so the speakers stay as they were: \(error)")
            return
        }
        await releaseDiarizer()

        guard let meeting = try await store.meeting(id: meetingID) else { return }
        var directory = SpeakerDirectory(meeting.speakers)
        let mapped = SpeakerAssigner.mapOffline(
            result.turns, onto: try await store.liveTurns(for: meetingID), directory: &directory)

        try await store.saveOfflineTurns(mapped, for: meetingID)
        let segments = try await store.segments(for: meetingID)
        try await store.replaceSegments(SpeakerAssigner.assign(segments, turns: mapped), for: meetingID)  // already in order
        let people = directory.speakers
        // Only the speakers: the meeting may have been renamed, or its people edited, while this ran.
        try await store.update(id: meetingID) { m in
            for (id, info) in people where m.speakers[id] == nil { m.speakers[id] = info }
        }
        try await complete(.diarize, meetingID)
    }

    /// All of `stream` as one array, read a window at a time.
    private static func read(_ stream: TranscriptEvent.Stream, duration: TimeInterval, from reader: any AudioSampleReader) async throws -> [Float] {
        var samples: [Float] = []
        samples.reserveCapacity(Int(duration * 16_000))
        var start: TimeInterval = 0
        while start < duration {
            try Task.checkCancellation()
            let end = min(duration, start + readWindow)
            samples += try await reader.samples(of: stream, in: start..<end)
            start = end
        }
        return samples
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

    private func finish(_ meetingID: UUID) async throws {
        try await store.update(id: meetingID) { $0.state = .finished }
    }
}
