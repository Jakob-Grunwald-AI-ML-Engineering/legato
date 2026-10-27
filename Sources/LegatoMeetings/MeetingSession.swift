import Foundation
import LegatoCore
import Synchronization

/// Converts a source's audio to the recording format (16 kHz mono). Injected so this module stays free of AVFoundation.
public typealias MeetingAudioConverter = @Sendable (AudioChunk) -> AudioChunk

/// One captured stream of a meeting: where its audio comes from and the engine that transcribes it.
public struct MeetingInput: Sendable {
    public var stream: TranscriptEvent.Stream
    public var source: any AudioSource
    public var engine: any DictationEngine
    /// The locale the engine prepares for; `nil` lets it choose.
    public var locale: Locale?

    public init(
        stream: TranscriptEvent.Stream, source: any AudioSource, engine: any DictationEngine, locale: Locale? = nil
    ) {
        self.stream = stream
        self.source = source
        self.engine = engine
        self.locale = locale
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
/// - **One timeline.** The meeting begins when the first source has started (`t0`). A source that starts
///   later has its lead (`offset`) written to the sink as silence and added to its engine's ranges, and a
///   source that restarts (it reports ``ResumableAudioSource/resumptions``) has the missing time filled with
///   silence, so every recording and every segment time is seconds since `t0`.
/// - Each source's audio goes to its engine in the engine's own format, and through `convert` to the
///   ``MeetingAudioSink``.
/// - Muting a stream feeds **silence** to both its engine and the sink (so the recording stays on one
///   timeline) and records the muted range on the ``Meeting``.
/// - Events are re-tagged with their input's stream (Apple Speech always tags `.mic`) and timed from the
///   event's range (plus the stream's offset), else from `clock`.
/// - An engine that fails or lags never holds the recording back: its feed keeps only the newest ~30 s and
///   is ended when the engine fails, while the sink keeps writing.
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
    private let feedCapacity: Int
    /// The clock value at the meeting's beginning; nil until the first source has started.
    private nonisolated let origin = Mutex<TimeInterval?>(nil)

    private var segments: [MeetingSegment] = []
    private var volatile: [TranscriptEvent.Stream: String] = [:]
    /// When the segment in progress was first heard, per stream.
    private var firstHeard: [TranscriptEvent.Stream: TimeInterval] = [:]
    /// When each currently muted stream was muted.
    private var mutedSince: [TranscriptEvent.Stream: TimeInterval] = [:]
    private var engineErrors: [TranscriptEvent.Stream: String] = [:]
    private var audioError: String?
    private var saveError: String?

    /// Seconds each stream began after the meeting did.
    private var offsets: [TranscriptEvent.Stream: TimeInterval] = [:]
    /// Seconds of the meeting timeline each stream's recording covers (offset, audio and silence).
    private var covered: [TranscriptEvent.Stream: TimeInterval] = [:]
    private var engineFormats: [TranscriptEvent.Stream: AudioFormatSpec] = [:]
    private var feeds: [TranscriptEvent.Stream: AsyncStream<AudioChunk>.Continuation] = [:]
    private var sourceTasks: [Task<Void, Never>] = []
    private var engineTasks: [Task<Void, Never>] = []
    private var resumeTasks: [Task<Void, Never>] = []
    /// Saves run one after another, in the order they were queued.
    private var saveTail: Task<Void, Never>?
    private var started = false
    private var stopped = false
    private var tearingDown = false

    /// - Parameters:
    ///   - clock: an increasing clock in seconds, on any origin. The meeting begins when the first source has
    ///     started; times are measured from there.
    ///   - feedCapacity: how many chunks an engine's feed holds before the oldest are dropped (~30 s).
    public init(
        meeting: Meeting, inputs: [MeetingInput], store: MeetingStore, sink: any MeetingAudioSink,
        convert: @escaping MeetingAudioConverter, clock: @escaping @Sendable () -> TimeInterval,
        feedCapacity: Int = 1_500
    ) {
        self.meeting = meeting
        meetingID = meeting.id
        self.inputs = inputs
        self.store = store
        self.sink = sink
        self.convert = convert
        self.clock = clock
        self.feedCapacity = max(1, feedCapacity)
        (snapshots, snapshotSink) = AsyncStream.makeStream(of: MeetingSnapshot.self, bufferingPolicy: .bufferingNewest(1))
    }

    /// The meeting this session records.
    public nonisolated let meetingID: UUID

    /// Seconds since the meeting began; 0 before it has. The same timeline as the segments and mute ranges.
    public nonisolated var elapsed: TimeInterval {
        guard let t0 = origin.withLock({ $0 }) else { return 0 }
        return max(0, clock() - t0)
    }

    /// Prepares every engine, starts every source, and saves the meeting as `recording`.
    /// If anything fails, the sources already running are stopped and the error is rethrown.
    public func start() async throws {
        guard !started else { return }
        started = true
        var running: [(input: MeetingInput, chunks: AsyncStream<AudioChunk>, startedAt: TimeInterval)] = []
        do {
            var formats: [TranscriptEvent.Stream: AudioFormatSpec] = [:]
            for input in inputs { formats[input.stream] = try await input.engine.prepare(locale: input.locale) }
            for input in inputs {
                let chunks = try await input.source.start(format: formats[input.stream] ?? AudioFormatSpec(sampleRate: 16_000, channelCount: 1))
                running.append((input, chunks, clock()))
            }
            engineFormats = formats
            let t0 = running.first?.startedAt ?? clock()
            origin.withLock { $0 = t0 }
            meeting.state = .recording
            try await store.create(meeting)
            for entry in running { try await begin(entry.input, chunks: entry.chunks, offset: max(0, entry.startedAt - t0)) }
        } catch {
            await teardown()
            throw error
        }
        publish()
    }

    /// Fills what a stream's recording is missing, up to now, with silence (to its engine and the sink).
    /// A source that restarts calls this through ``ResumableAudioSource/resumptions``; shortfalls under
    /// ``MeetingSilence/tolerance`` are jitter and ignored. Chunks delivered right after the restart may land
    /// just ahead of the silence, which shifts them by no more than their own length.
    public func fillGap(stream: TranscriptEvent.Stream) async {
        guard started, !stopped, !tearingDown, let have = covered[stream] else { return }
        let missing = MeetingSilence.deficit(elapsed: elapsed, delivered: have)
        guard missing > 0 else { return }
        covered[stream] = have + missing
        if let format = engineFormats[stream], let feed = feeds[stream] {
            let perSecond = Int(format.sampleRate) * max(1, format.channelCount)
            var left = Int(missing * Double(perSecond))
            while left > 0 {
                let n = min(left, perSecond)
                feed.yield(AudioChunk(samples: [Float](repeating: 0, count: n), format: format))
                left -= n
            }
        }
        await writeSilence(missing, stream: stream)
    }

    /// Mutes or unmutes one stream. Manual and automatic mute both come through here.
    public func setMuted(_ muted: Bool, stream: TranscriptEvent.Stream) {
        if muted {
            guard mutedSince[stream] == nil else { return }
            mutedSince[stream] = elapsed
        } else if let since = mutedSince.removeValue(forKey: stream) {
            meeting.mutedRanges.append(MutedRange(stream: stream, start: since, end: elapsed))
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

        let now = elapsed
        for (stream, since) in mutedSince.sorted(by: { $0.value < $1.value }) {
            meeting.mutedRanges.append(MutedRange(stream: stream, start: since, end: now))
        }
        mutedSince = [:]
        meeting.duration = now
        meeting.state = .processing
        await saveTail?.value
        do {
            let (ranges, duration, state) = (meeting.mutedRanges, meeting.duration, meeting.state)
            if let merged = try await store.update(id: meeting.id, { m in
                m.mutedRanges = ranges
                m.duration = duration
                m.state = state
            }) { meeting = merged }
        } catch { saveError = "\(error)" }
        do { try await sink.finish() } catch { audioError = "\(error)" }
        publish()
        snapshotSink.finish()
        return meeting
    }

    // MARK: Inputs

    private func begin(_ input: MeetingInput, chunks: AsyncStream<AudioChunk>, offset: TimeInterval) async throws {
        let stream = input.stream
        offsets[stream] = offset
        covered[stream] = offset
        if offset > 0 { await writeSilence(offset, stream: stream) }

        // Newest audio wins: an engine that lags drops the oldest rather than growing without bound.
        let (engineAudio, feed) = AsyncStream<AudioChunk>.makeStream(bufferingPolicy: .bufferingNewest(feedCapacity))
        feeds[stream] = feed
        let results = input.engine.transcribe(engineAudio)

        sourceTasks.append(Task { [self] in
            for await chunk in chunks { await route(chunk, stream: stream) }
            await sourceEnded(stream)
        })
        engineTasks.append(Task { [self] in
            do {
                for try await event in results { handle(event, from: stream) }
            } catch {
                engineFailed(stream, error)
            }
        })
        if let source = input.source as? any ResumableAudioSource {
            let resumptions = source.resumptions
            resumeTasks.append(Task { [self] in
                for await _ in resumptions { await fillGap(stream: stream) }
            })
        }
    }

    /// Stops sources, lets the engines deliver what is left, then ends them.
    private func teardown() async {
        tearingDown = true
        for input in inputs { await input.source.stop() }
        for task in sourceTasks { await task.value }
        for task in resumeTasks { task.cancel() }
        for feed in feeds.values { feed.finish() }
        feeds = [:]
        for input in inputs { try? await input.engine.finish() }
        for task in engineTasks { await task.value }
        sourceTasks = []
        engineTasks = []
        resumeTasks = []
    }

    private func route(_ chunk: AudioChunk, stream: TranscriptEvent.Stream) async {
        let muted = mutedSince[stream] != nil
        let perSecond = chunk.format.sampleRate * Double(max(1, chunk.format.channelCount))
        let seconds = Double(chunk.samples.count) / perSecond
        covered[stream, default: 0] += seconds
        let toEngine = muted ? AudioChunk(samples: [Float](repeating: 0, count: chunk.samples.count), format: chunk.format) : chunk
        feeds[stream]?.yield(toEngine)
        do {
            if muted {
                try await sink.writeSilence(seconds: seconds, stream: stream)
            } else {
                try await sink.write(convert(chunk), stream: stream)
            }
        } catch {
            audioError = "\(error)"
            publish()
        }
    }

    private func writeSilence(_ seconds: TimeInterval, stream: TranscriptEvent.Stream) async {
        do { try await sink.writeSilence(seconds: seconds, stream: stream) } catch {
            audioError = "\(error)"
            publish()
        }
    }

    /// A source's chunk stream ended without the meeting asking for it (a failed restart): the recording of
    /// that stream stops there.
    private func sourceEnded(_ stream: TranscriptEvent.Stream) {
        guard !tearingDown else { return }
        let name = stream == .mic ? "microphone" : "system audio"
        let message = "The \(name) stopped delivering audio, so the rest of it is not recorded."
        audioError = audioError.map { $0.contains(message) ? $0 : "\($0) \(message)" } ?? message
        publish()
    }

    private func engineFailed(_ stream: TranscriptEvent.Stream, _ error: any Error) {
        engineErrors[stream] = "\(error)"
        volatile[stream] = nil
        // No one reads this feed any more; the sink keeps recording the audio.
        feeds.removeValue(forKey: stream)?.finish()
        publish()
    }

    // MARK: Events

    private func handle(_ event: TranscriptEvent, from stream: TranscriptEvent.Stream) {
        let text = event.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard event.isFinal else {
            volatile[stream] = text.isEmpty ? nil : text
            if !text.isEmpty, firstHeard[stream] == nil { firstHeard[stream] = elapsed }
            publish()
            return
        }
        volatile[stream] = nil
        let heardAt = firstHeard.removeValue(forKey: stream)
        guard !text.isEmpty else { return publish() }

        let start: TimeInterval, end: TimeInterval
        if let range = event.range {
            // The engine counted from its first sample; the stream began `offset` after the meeting.
            let offset = offsets[stream] ?? 0
            (start, end) = (range.lowerBound + offset, range.upperBound + offset)
        } else {
            end = elapsed
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

    /// Writes only the fields the session owns, onto the meeting as it is on disk now (a rename survives).
    private func saveMeeting() {
        let (ranges, duration, state) = (meeting.mutedRanges, meeting.duration, meeting.state)
        save { [store, id = meeting.id] in
            try await store.update(id: id) { m in
                m.mutedRanges = ranges
                m.duration = duration
                m.state = state
            }
        }
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
