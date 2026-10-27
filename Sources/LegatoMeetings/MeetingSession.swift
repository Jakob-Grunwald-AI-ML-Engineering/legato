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

/// One captured source of a meeting in mixed mode: where its audio comes from. The sources are summed by a
/// ``MeetingMixer`` into the one signal a single engine transcribes.
public struct MeetingSource: Sendable {
    public var stream: TranscriptEvent.Stream
    public var source: any AudioSource

    public init(stream: TranscriptEvent.Stream, source: any AudioSource) {
        self.stream = stream
        self.source = source
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
    /// The meeting is paused: every source is silent.
    public var isPaused: Bool
    /// The speaker diarizer failed; the transcript carries on without (more) speaker labels.
    public var diarizerError: String?
}

/// A running meeting, in one of two modes.
///
/// - **Mixed** (``init(meeting:sources:engine:locale:diarizer:enrollment:store:sink:convert:clock:feedCapacity:)``):
///   several ``MeetingSource``s are summed by a ``MeetingMixer`` and ONE engine transcribes the mix, so the
///   transcript is one continuous stream of `.mixed` segments. The mix is cut every 100 ms, a little behind the
///   clock so late chunks still make it, and the last partial frame is added at the stop: the mix is as long as
///   the meeting. An optional ``SpeakerDiarizer`` is fed the same mix from its own task; its turns become
///   people (``Meeting/speakers``) and give the segments their speakers, the newest ones revised for
///   ``SpeakerAssigner/recentWindow`` seconds because a diarizer lags.
/// - **One engine per stream** (``init(meeting:inputs:store:sink:convert:clock:feedCapacity:)``): the
///   original mode. Each ``MeetingInput`` has its own engine and `.mic` / `.system` segments.
///
/// Both modes share what follows.
///
/// - **Pause** silences every source (and the mix) and records one ``PausedRange``; **mute** silences one
///   stream and records a ``MutedRange``; the two are independent. **Discard** stops everything and removes the
///   meeting's folder.
/// - **Sink tracks.** Each source is recorded on its own track. With several sources in mixed mode the mix is
///   written to the `.mixed` track too; with one source its track is the mix.
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

    /// One engine and the stream of audio it transcribes: a source's own stream, or `.mixed`.
    private struct EngineSlot {
        var channel: TranscriptEvent.Stream
        var engine: any DictationEngine
        var locale: Locale?
    }

    /// How far behind the clock the mix runs, so a chunk that arrives a little late still makes its frame.
    private static let mixLatency: TimeInterval = 0.2
    private static let mixTick: Duration = .milliseconds(50)

    private var meeting: Meeting
    private let sources: [MeetingSource]
    private let slots: [EngineSlot]
    private let isMixed: Bool
    private let diarizer: (any SpeakerDiarizer)?
    private let enrollment: [Float]?
    private let store: MeetingStore
    private let sink: any MeetingAudioSink
    private let convert: MeetingAudioConverter
    private let clock: @Sendable () -> TimeInterval
    private let feedCapacity: Int
    /// The clock value at the meeting's beginning; nil until the first source has started.
    private nonisolated let origin = Mutex<TimeInterval?>(nil)

    private var mixer: MeetingMixer?
    private var mixFormat: AudioFormatSpec?
    private var tickerTask: Task<Void, Never>?
    private var diarizerTask: Task<Void, Never>?
    private var diarizerFeed: AsyncStream<AudioChunk>.Continuation?
    private var directory: SpeakerDirectory
    /// Diarizer cluster id → person id, for the live turns.
    private var clusterPerson: [String: PersonID] = [:]
    private var enrolledCluster: String?
    private var liveTurns: [SpeakerTurn] = []
    private var diarizerError: String?
    /// When the meeting was paused, while it is.
    private var pausedSince: TimeInterval?
    private var discarded = false

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

    /// One engine per stream.
    /// - Parameters:
    ///   - clock: an increasing clock in seconds, on any origin. The meeting begins when the first source has
    ///     started; times are measured from there.
    ///   - feedCapacity: how many chunks an engine's feed holds before the oldest are dropped (~30 s).
    public init(
        meeting: Meeting, inputs: [MeetingInput], store: MeetingStore, sink: any MeetingAudioSink,
        convert: @escaping MeetingAudioConverter, clock: @escaping @Sendable () -> TimeInterval,
        feedCapacity: Int = 1_500
    ) {
        self.init(
            meeting: meeting, sources: inputs.map { MeetingSource(stream: $0.stream, source: $0.source) },
            slots: inputs.map { EngineSlot(channel: $0.stream, engine: $0.engine, locale: $0.locale) }, isMixed: false,
            diarizer: nil, enrollment: nil, store: store, sink: sink, convert: convert, clock: clock,
            feedCapacity: feedCapacity)
    }

    /// Mixed mode: `sources` are summed and `engine` transcribes the mix.
    /// - Parameters:
    ///   - locale: the language `engine` prepares for; nil lets it choose.
    ///   - diarizer: tells speakers apart in the mix while the meeting runs; nil leaves segments without speakers.
    ///   - enrollment: the user's voice sample (16 kHz mono) to teach the diarizer; its speaker becomes "You".
    ///   - feedCapacity: as for the other initializer; the mix feed holds a fifth as many (100 ms) frames.
    public init(
        meeting: Meeting, sources: [MeetingSource], engine: any DictationEngine, locale: Locale? = nil,
        diarizer: (any SpeakerDiarizer)? = nil, enrollment: [Float]? = nil, store: MeetingStore,
        sink: any MeetingAudioSink, convert: @escaping MeetingAudioConverter,
        clock: @escaping @Sendable () -> TimeInterval, feedCapacity: Int = 1_500
    ) {
        self.init(
            meeting: meeting, sources: sources, slots: [EngineSlot(channel: .mixed, engine: engine, locale: locale)],
            isMixed: true, diarizer: diarizer, enrollment: enrollment, store: store, sink: sink, convert: convert,
            clock: clock, feedCapacity: feedCapacity)
    }

    private init(
        meeting: Meeting, sources: [MeetingSource], slots: [EngineSlot], isMixed: Bool,
        diarizer: (any SpeakerDiarizer)?, enrollment: [Float]?, store: MeetingStore, sink: any MeetingAudioSink,
        convert: @escaping MeetingAudioConverter, clock: @escaping @Sendable () -> TimeInterval, feedCapacity: Int
    ) {
        self.meeting = meeting
        meetingID = meeting.id
        self.sources = sources
        self.slots = slots
        self.isMixed = isMixed
        self.diarizer = diarizer
        self.enrollment = enrollment
        self.directory = SpeakerDirectory(meeting.speakers)
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
    /// If anything fails, or the calling task is cancelled (checked after each engine and source, since a
    /// model load cannot be interrupted), the sources already running are stopped and the error is rethrown.
    public func start() async throws {
        guard !started else { return }
        started = true
        var running: [(source: MeetingSource, chunks: AsyncStream<AudioChunk>, startedAt: TimeInterval)] = []
        do {
            var formats: [TranscriptEvent.Stream: AudioFormatSpec] = [:]
            for slot in slots {
                formats[slot.channel] = try await slot.engine.prepare(locale: slot.locale)
                // A model load cannot be interrupted; once it returns, a cancelled start stops here.
                try Task.checkCancellation()
            }
            if let diarizer, let enrollment {
                // Without the enrolled voice the diarizer still works; "You" is then found by other means.
                do { enrolledCluster = try await diarizer.enroll(samples: enrollment) } catch { diarizerError = "\(error)" }
            }
            for entry in sources {
                try Task.checkCancellation()
                let format = formats[isMixed ? .mixed : entry.stream] ?? AudioFormatSpec(sampleRate: 16_000, channelCount: 1)
                let chunks = try await entry.source.start(format: format)
                running.append((entry, chunks, clock()))
            }
            try Task.checkCancellation()
            engineFormats = formats
            if isMixed, let format = formats[.mixed] {
                mixFormat = format
                mixer = MeetingMixer(sampleRate: format.sampleRate)
            }
            let t0 = running.first?.startedAt ?? clock()
            origin.withLock { $0 = t0 }
            meeting.state = .recording
            try await store.create(meeting)
            for slot in slots { beginEngine(slot) }
            for entry in running { await beginSource(entry.source, chunks: entry.chunks, offset: max(0, entry.startedAt - t0)) }
            if isMixed {
                startTicker()
                startDiarizer()
            }
        } catch {
            await teardown(mixEnd: nil)
            throw error
        }
        publish()
    }

    /// Fills what a stream's recording is missing, up to now, with silence (to its engine and the sink).
    /// A source that restarts calls this through ``ResumableAudioSource/resumptions``; shortfalls under
    /// ``MeetingSilence/tolerance`` are jitter and ignored. Chunks delivered right after the restart may land
    /// just ahead of the silence, which shifts them by no more than their own length. In mixed mode the engine
    /// hears the mix, which is silent there by itself; only the source's own recording needs the silence.
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
            mixer?.mute(stream, at: elapsed)
        } else if let since = mutedSince.removeValue(forKey: stream) {
            mixer?.unmute(stream, at: elapsed)
            meeting.mutedRanges.append(MutedRange(stream: stream, start: since, end: elapsed))
            saveMeeting()
        }
        publish()
    }

    /// Silences every source until ``resume()``. The recording keeps running (silence on every track), so the
    /// timeline holds; the pause is recorded as one ``PausedRange``, separate from the per-stream mutes.
    public func pause() {
        guard started, !stopped, pausedSince == nil else { return }
        pausedSince = elapsed
        mixer?.pause(at: elapsed)
        publish()
    }

    public func resume() {
        guard !stopped, let since = pausedSince else { return }
        pausedSince = nil
        mixer?.resume(at: elapsed)
        meeting.pausedRanges.append(PausedRange(start: since, end: elapsed))
        saveMeeting()
        publish()
    }

    /// Ends capture, drains the engines, closes any open mute or pause and finishes the recording. The meeting
    /// is saved as `processing`, ready for the after-stop chain.
    @discardableResult
    public func stop() async -> Meeting {
        guard !stopped else { return meeting }
        stopped = true
        let now = elapsed
        await teardown(mixEnd: now)

        for (stream, since) in mutedSince.sorted(by: { $0.value < $1.value }) {
            meeting.mutedRanges.append(MutedRange(stream: stream, start: since, end: now))
        }
        mutedSince = [:]
        if let since = pausedSince {
            meeting.pausedRanges.append(PausedRange(start: since, end: now))
            pausedSince = nil
        }
        meeting.duration = now
        meeting.state = .processing
        meeting.speakers = directory.speakers
        await saveTail?.value
        do {
            let (muted, paused, duration, state, speakers) =
                (meeting.mutedRanges, meeting.pausedRanges, meeting.duration, meeting.state, meeting.speakers)
            if let merged = try await store.update(id: meeting.id, { m in
                m.mutedRanges = muted
                m.pausedRanges = paused
                m.duration = duration
                m.state = state
                for (id, info) in speakers where m.speakers[id] == nil { m.speakers[id] = info }
            }) {
                meeting = merged
                directory = SpeakerDirectory(merged.speakers)
            }
        } catch { saveError = "\(error)" }
        do { try await sink.finish() } catch { audioError = "\(error)" }
        publish()
        snapshotSink.finish()
        return meeting
    }

    /// Stops the capture and removes the meeting: its folder and everything recorded or saved in it. Nothing
    /// of the meeting is kept, and a later ``stop()`` does nothing.
    public func discard() async {
        guard !discarded else { return }
        discarded = true
        if !stopped {
            stopped = true
            if started { await teardown(mixEnd: nil) }
        }
        await saveTail?.value
        try? await sink.finish()  // close the files before their folder goes
        try? await store.deleteMeeting(id: meeting.id)
        snapshotSink.finish()
    }

    // MARK: Inputs

    private func beginEngine(_ slot: EngineSlot) {
        let channel = slot.channel
        // Newest audio wins: an engine that lags drops the oldest rather than growing without bound.
        let capacity = channel == .mixed ? max(1, feedCapacity / 5) : feedCapacity
        let (engineAudio, feed) = AsyncStream<AudioChunk>.makeStream(bufferingPolicy: .bufferingNewest(capacity))
        feeds[channel] = feed
        let results = slot.engine.transcribe(engineAudio)
        engineTasks.append(Task { [self] in
            do {
                for try await event in results { handle(event, from: channel) }
            } catch {
                engineFailed(channel, error)
            }
        })
    }

    private func beginSource(_ input: MeetingSource, chunks: AsyncStream<AudioChunk>, offset: TimeInterval) async {
        let stream = input.stream
        offsets[stream] = offset
        covered[stream] = offset
        if offset > 0 { await writeSilence(offset, stream: stream) }

        sourceTasks.append(Task { [self] in
            for await chunk in chunks { await route(chunk, stream: stream) }
            await sourceEnded(stream)
        })
        if let source = input.source as? any ResumableAudioSource {
            let resumptions = source.resumptions
            resumeTasks.append(Task { [self] in
                for await _ in resumptions { await fillGap(stream: stream) }
            })
        }
    }

    /// Stops sources, lets the engines deliver what is left, then ends them. `mixEnd` is where the mix ends
    /// (the meeting's length); nil abandons whatever of the mix has not been cut.
    private func teardown(mixEnd: TimeInterval?) async {
        tearingDown = true
        for entry in sources { await entry.source.stop() }
        for task in sourceTasks { await task.value }
        for task in resumeTasks { task.cancel() }
        tickerTask?.cancel()
        await tickerTask?.value
        tickerTask = nil
        if let mixEnd { await emitMix(flushingTo: mixEnd) }
        for feed in feeds.values { feed.finish() }
        feeds = [:]
        diarizerFeed?.finish()
        diarizerFeed = nil
        for slot in slots { try? await slot.engine.finish() }
        for task in engineTasks { await task.value }
        await diarizerTask?.value
        sourceTasks = []
        engineTasks = []
        resumeTasks = []
        diarizerTask = nil
    }

    private func route(_ chunk: AudioChunk, stream: TranscriptEvent.Stream) async {
        let silenced = mutedSince[stream] != nil || pausedSince != nil
        let perSecond = chunk.format.sampleRate * Double(max(1, chunk.format.channelCount))
        let seconds = Double(chunk.samples.count) / perSecond
        covered[stream, default: 0] += seconds
        if isMixed {
            // The mixer silences what was muted or paused when the audio was heard, by its timestamp.
            mixer?.append(chunk.samples, from: stream, at: elapsed)
        } else {
            let toEngine = silenced ? AudioChunk(samples: [Float](repeating: 0, count: chunk.samples.count), format: chunk.format) : chunk
            feeds[stream]?.yield(toEngine)
        }
        do {
            if silenced {
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

    private func engineFailed(_ channel: TranscriptEvent.Stream, _ error: any Error) {
        engineErrors[channel] = "\(error)"
        volatile[channel] = nil
        // No one reads this feed any more; the sink keeps recording the audio.
        feeds.removeValue(forKey: channel)?.finish()
        publish()
    }

    // MARK: The mix

    private func startTicker() {
        tickerTask = Task { [self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.mixTick)
                if Task.isCancelled { break }
                await emitMix(flushingTo: nil)
            }
        }
    }

    /// Cuts the mix up to `end` (the meeting's length, partial last frame included), or while running up to a
    /// little behind now, and sends it to the engine, the diarizer and the sink.
    private func emitMix(flushingTo end: TimeInterval?) async {
        guard let format = mixFormat else { return }
        let frames: [[Float]]
        if let end {
            frames = mixer?.flush(to: end) ?? []
        } else {
            frames = mixer?.advance(to: max(0, elapsed - Self.mixLatency)) ?? []
        }
        for samples in frames {
            let chunk = AudioChunk(samples: samples, format: format)
            feeds[.mixed]?.yield(chunk)
            diarizerFeed?.yield(chunk)
            // With one source, its own track is the mix.
            guard sources.count > 1 else { continue }
            do { try await sink.write(convert(chunk), stream: .mixed) } catch {
                audioError = "\(error)"
                publish()
            }
        }
    }

    // MARK: Speakers

    private func startDiarizer() {
        guard let diarizer else { return }
        let (audio, feed) = AsyncStream<AudioChunk>.makeStream(bufferingPolicy: .bufferingNewest(max(1, feedCapacity / 5)))
        diarizerFeed = feed
        diarizerTask = Task { [self] in
            do {
                for await chunk in audio {
                    try await diarizer.feed(chunk)
                    diarizerTurns(await diarizer.turns())
                }
                diarizerTurns(try await diarizer.finish())
            } catch {
                diarizerFailed(error)
            }
        }
    }

    private func diarizerFailed(_ error: any Error) {
        diarizerError = "\(error)"
        publish()
    }

    /// New turns from the diarizer: map its clusters to people, save the turns, and re-assign the segments
    /// that ended in the last few seconds (a diarizer lags, so it revises its newest turns).
    private func diarizerTurns(_ clusters: [SpeakerTurn]) {
        let before = directory
        let mapped = clusters.map { turn in
            SpeakerTurn(speaker: person(for: turn.speaker), start: turn.start, end: turn.end)
        }
        // People first, then the segments that name them: a reader that sees an id can look it up.
        if directory != before {
            meeting.speakers = directory.speakers
            saveMeeting()
        }
        if mapped != liveTurns {
            liveTurns = mapped
            save { [store, id = meeting.id] in try await store.saveLiveTurns(mapped, for: id) }
        }
        let relabelled = SpeakerAssigner.relabelRecent(segments, turns: mapped, now: elapsed)
        if relabelled != segments {
            segments = relabelled
            saveAll(segments)
        }
        publish()
    }

    private func person(for cluster: String) -> PersonID {
        if let known = clusterPerson[cluster] { return known }
        let id = directory.add(isYou: cluster == enrolledCluster)
        clusterPerson[cluster] = id
        return id
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
            // The engine counted from its first sample; the stream began `offset` after the meeting (the
            // mix, which the engine hears from the meeting's first moment, has none).
            let offset = offsets[stream] ?? 0
            (start, end) = (range.lowerBound + offset, range.upperBound + offset)
        } else {
            end = elapsed
            start = min(heardAt ?? end, end)
        }
        var segment = MeetingSegment(stream: stream, text: text, start: start, end: end)
        if isMixed { segment.speaker = SpeakerAssigner.speaker(start: start, end: end, turns: liveTurns) }
        segments.append(segment)

        if isMixed {
            if let newest = segments.last { save { [store, id = meeting.id] in try await store.appendSegment(newest, to: id) } }
        } else {
            let before = segments
            segments = EchoDeduper.mark(segments)
            let earlierChanged = zip(before.dropLast(), segments).contains { $0.echo != $1.echo }
            if earlierChanged {
                saveAll(segments)
            } else if let newest = segments.last {
                save { [store, id = meeting.id] in try await store.appendSegment(newest, to: id) }
            }
        }
        publish()
    }

    // MARK: Saving and publishing

    private func saveAll(_ all: [MeetingSegment]) {
        save { [store, id = meeting.id] in try await store.replaceSegments(all, for: id) }
    }

    /// Writes only the fields the session owns, onto the meeting as it is on disk now (a rename survives; so
    /// does a speaker the user renamed, since the session only adds people the file does not have yet).
    private func saveMeeting() {
        let (muted, paused, duration, state, speakers) =
            (meeting.mutedRanges, meeting.pausedRanges, meeting.duration, meeting.state, meeting.speakers)
        save { [store, id = meeting.id] in
            try await store.update(id: id) { m in
                m.mutedRanges = muted
                m.pausedRanges = paused
                m.duration = duration
                m.state = state
                for (person, info) in speakers where m.speakers[person] == nil { m.speakers[person] = info }
            }
        }
    }

    private func save(_ work: @escaping @Sendable () async throws -> Void) {
        guard !discarded else { return }
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
        guard !discarded else { return }
        snapshotSink.yield(
            MeetingSnapshot(
                meeting: meeting, segments: MeetingStore.ordered(segments), volatile: volatile,
                mutedStreams: Set(mutedSince.keys), engineErrors: engineErrors, audioError: audioError,
                saveError: saveError, isPaused: pausedSince != nil, diarizerError: diarizerError))
    }
}
