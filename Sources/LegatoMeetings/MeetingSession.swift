import Foundation
import LegatoCore

/// Converts a source's audio to the recording format (16 kHz mono). Injected so this module stays free of AVFoundation.
public typealias MeetingAudioConverter = @Sendable (AudioChunk) -> AudioChunk

/// One captured stream of a meeting: where its audio comes from and the engine that transcribes it.
public struct MeetingInput: Sendable {
    public var stream: TranscriptEvent.Stream
    public var source: any AudioSource
    public var engine: any DictationEngine

    public init(stream: TranscriptEvent.Stream, source: any AudioSource, engine: any DictationEngine) {
        self.stream = stream
        self.source = source
        self.engine = engine
    }
}

/// Everything a live meeting view shows, republished on every change.
public struct MeetingSnapshot: Sendable, Equatable {
    public var meeting: Meeting
    /// Finished segments (echoes included, flagged), ordered by start.
    public var segments: [MeetingSegment]
    /// The tentative text of each stream's segment in progress.
    public var volatile: [TranscriptEvent.Stream: String]
    public var mutedStreams: Set<TranscriptEvent.Stream>
    /// A stream whose engine failed; its audio is still recorded.
    public var engineErrors: [TranscriptEvent.Stream: String]
    /// The recording sink failed; audio may be missing.
    public var audioError: String?
    /// Saving segments or the meeting failed.
    public var saveError: String?
}

/// A running meeting: one or more ``MeetingInput``s captured together.
///
/// - Each source's audio goes to its engine in the engine's own format, and through `convert` to the
///   ``MeetingAudioSink``.
/// - Muting a stream feeds **silence** to both its engine and the sink (so the recording stays on one
///   timeline) and records the muted range on the ``Meeting``.
/// - Events are re-tagged with their input's stream (Apple Speech always tags `.mic`) and timed from the
///   event's range, else from `clock` (seconds since the meeting began).
/// - Finished segments are marked by ``EchoDeduper`` and saved to the ``MeetingStore`` as they arrive.
public actor MeetingSession {
    /// Latest state; only the newest unread snapshot is kept.
    public nonisolated let snapshots: AsyncStream<MeetingSnapshot>
    private let snapshotSink: AsyncStream<MeetingSnapshot>.Continuation

    private var meeting: Meeting
    private let inputs: [MeetingInput]
    private let store: MeetingStore
    private let sink: any MeetingAudioSink
    private let convert: MeetingAudioConverter
    private let clock: @Sendable () -> TimeInterval

    private var segments: [MeetingSegment] = []
    private var volatile: [TranscriptEvent.Stream: String] = [:]
    /// When the segment in progress was first heard, per stream.
    private var firstHeard: [TranscriptEvent.Stream: TimeInterval] = [:]
    /// When each currently muted stream was muted.
    private var mutedSince: [TranscriptEvent.Stream: TimeInterval] = [:]
    private var engineErrors: [TranscriptEvent.Stream: String] = [:]
    private var audioError: String?
    private var saveError: String?

    private var feeds: [TranscriptEvent.Stream: AsyncStream<AudioChunk>.Continuation] = [:]
    private var sourceTasks: [Task<Void, Never>] = []
    private var engineTasks: [Task<Void, Never>] = []
    /// Saves run one after another, in the order they were queued.
    private var saveTail: Task<Void, Never>?
    private var started = false
    private var stopped = false

    public init(
        meeting: Meeting, inputs: [MeetingInput], store: MeetingStore, sink: any MeetingAudioSink,
        convert: @escaping MeetingAudioConverter, clock: @escaping @Sendable () -> TimeInterval
    ) {
        self.meeting = meeting
        self.inputs = inputs
        self.store = store
        self.sink = sink
        self.convert = convert
        self.clock = clock
        (snapshots, snapshotSink) = AsyncStream.makeStream(of: MeetingSnapshot.self, bufferingPolicy: .bufferingNewest(1))
    }

    /// Prepares every engine, starts every source, and saves the meeting as `recording`.
    /// If any input fails to start, the ones already running are stopped and the error is rethrown.
    public func start() async throws {
        guard !started else { return }
        started = true
        do {
            for input in inputs { try await begin(input) }
        } catch {
            await teardown()
            throw error
        }
        meeting.state = .recording
        try await store.create(meeting)
        publish()
    }

    /// Mutes or unmutes one stream. Manual and automatic mute both come through here.
    public func setMuted(_ muted: Bool, stream: TranscriptEvent.Stream) {
        if muted {
            guard mutedSince[stream] == nil else { return }
            mutedSince[stream] = clock()
        } else if let since = mutedSince.removeValue(forKey: stream) {
            meeting.mutedRanges.append(MutedRange(stream: stream, start: since, end: clock()))
            saveMeeting()
        }
        publish()
    }

    /// Ends capture, drains the engines, closes any open mute and finishes the recording. The meeting is
    /// saved as `processing`, ready for the after-stop chain.
    @discardableResult
    public func stop() async -> Meeting {
        guard !stopped else { return meeting }
        stopped = true
        await teardown()

        let now = clock()
        for (stream, since) in mutedSince.sorted(by: { $0.value < $1.value }) {
            meeting.mutedRanges.append(MutedRange(stream: stream, start: since, end: now))
        }
        mutedSince = [:]
        meeting.duration = now
        meeting.state = .processing
        saveMeeting()
        await saveTail?.value
        do { try await sink.finish() } catch { audioError = "\(error)" }
        publish()
        snapshotSink.finish()
        return meeting
    }

    // MARK: Inputs

    private func begin(_ input: MeetingInput) async throws {
        let stream = input.stream
        let format = try await input.engine.prepare(locale: nil)
        let chunks = try await input.source.start(format: format)
        let (engineAudio, feed) = AsyncStream<AudioChunk>.makeStream()
        feeds[stream] = feed
        let results = input.engine.transcribe(engineAudio)

        sourceTasks.append(Task { [self] in
            for await chunk in chunks { await route(chunk, stream: stream) }
        })
        engineTasks.append(Task { [self] in
            do {
                for try await event in results { handle(event, from: stream) }
            } catch {
                engineFailed(stream, error)
            }
        })
    }

    /// Stops sources, lets the engines deliver what is left, then ends them.
    private func teardown() async {
        for input in inputs { await input.source.stop() }
        for task in sourceTasks { await task.value }
        for feed in feeds.values { feed.finish() }
        feeds = [:]
        for input in inputs { try? await input.engine.finish() }
        for task in engineTasks { await task.value }
        sourceTasks = []
        engineTasks = []
    }

    private func route(_ chunk: AudioChunk, stream: TranscriptEvent.Stream) async {
        let muted = mutedSince[stream] != nil
        let toEngine = muted ? AudioChunk(samples: [Float](repeating: 0, count: chunk.samples.count), format: chunk.format) : chunk
        feeds[stream]?.yield(toEngine)
        do {
            if muted {
                let perSecond = chunk.format.sampleRate * Double(max(1, chunk.format.channelCount))
                try await sink.writeSilence(seconds: Double(chunk.samples.count) / perSecond, stream: stream)
            } else {
                try await sink.write(convert(chunk), stream: stream)
            }
        } catch {
            audioError = "\(error)"
            publish()
        }
    }

    private func engineFailed(_ stream: TranscriptEvent.Stream, _ error: any Error) {
        engineErrors[stream] = "\(error)"
        volatile[stream] = nil
        publish()
    }

    // MARK: Events

    private func handle(_ event: TranscriptEvent, from stream: TranscriptEvent.Stream) {
        let text = event.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard event.isFinal else {
            volatile[stream] = text.isEmpty ? nil : text
            if !text.isEmpty, firstHeard[stream] == nil { firstHeard[stream] = clock() }
            publish()
            return
        }
        volatile[stream] = nil
        let heardAt = firstHeard.removeValue(forKey: stream)
        guard !text.isEmpty else { return publish() }

        let start: TimeInterval, end: TimeInterval
        if let range = event.range {
            (start, end) = (range.lowerBound, range.upperBound)
        } else {
            end = clock()
            start = min(heardAt ?? end, end)
        }
        segments.append(MeetingSegment(stream: stream, text: text, start: start, end: end))

        let before = segments
        segments = EchoDeduper.mark(segments)
        let earlierChanged = zip(before.dropLast(), segments).contains { $0.echo != $1.echo }
        if earlierChanged {
            saveAll(segments)
        } else if let newest = segments.last {
            save { [store, id = meeting.id] in try await store.appendSegment(newest, to: id) }
        }
        publish()
    }

    // MARK: Saving and publishing

    private func saveAll(_ all: [MeetingSegment]) {
        save { [store, id = meeting.id] in try await store.replaceSegments(all, for: id) }
    }

    private func saveMeeting() {
        let snapshot = meeting
        save { [store] in try await store.update(snapshot) }
    }

    private func save(_ work: @escaping @Sendable () async throws -> Void) {
        let previous = saveTail
        saveTail = Task { [self] in
            await previous?.value
            do { try await work() } catch { saveFailed(error) }
        }
    }

    private func saveFailed(_ error: any Error) {
        saveError = "\(error)"
        publish()
    }

    private func publish() {
        snapshotSink.yield(
            MeetingSnapshot(
                meeting: meeting, segments: MeetingStore.ordered(segments), volatile: volatile,
                mutedStreams: Set(mutedSince.keys), engineErrors: engineErrors, audioError: audioError,
                saveError: saveError))
    }
}
