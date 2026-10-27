import Foundation
import LegatoCore
import Synchronization

/// Converts a source's audio to the recording format (16 kHz mono). Injected so this module stays free of AVFoundation.
public typealias MeetingAudioConverter = @Sendable (AudioChunk) -> AudioChunk

/// One captured source of a meeting: where its audio comes from. The sources are summed by a
/// ``MeetingMixer`` into the one signal a single engine transcribes.
public struct MeetingSource: Sendable {
    public var stream: TranscriptEvent.Stream
    public var source: any AudioSource

    public init(stream: TranscriptEvent.Stream, source: any AudioSource) {
        self.stream = stream
        self.source = source
    }
}

/// Everything a live meeting view shows, republished on change (at most four times a second).
public struct MeetingSnapshot: Sendable, Equatable {
    public var meeting: Meeting
    /// Finished segments, ordered by start.
    public var segments: [MeetingSegment]
    /// The tentative text of the segment in progress, under `.mixed`.
    public var volatile: [TranscriptEvent.Stream: String]
    public var mutedStreams: Set<TranscriptEvent.Stream>
    /// The engine failed (under `.mixed`); the audio is still recorded.
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

/// Maps the diarizer's own clock (seconds of audio it was fed) onto the meeting's. Its feed keeps only the
/// newest frames when it lags, so after a drop its clock runs behind the meeting's by what it never heard.
struct DiarizerTimeline: Sendable {
    /// Seconds of audio the diarizer was given.
    private(set) var fed: TimeInterval = 0
    /// From diarizer time `from` on, meeting time is diarizer time plus `by`.
    private var shifts: [(from: TimeInterval, by: TimeInterval)] = []

    /// The diarizer is given `duration` seconds that begin at `meetingTime`.
    mutating func feeding(_ duration: TimeInterval, at meetingTime: TimeInterval) {
        let by = meetingTime - fed
        if by > (shifts.last?.by ?? 0) + 1e-6 { shifts.append((fed, by)) }
        fed += duration
    }

    /// `turn` (diarizer time) in meeting time; its end belongs with what came before it.
    func meetingTime(of turn: SpeakerTurn) -> SpeakerTurn {
        let start = turn.start + (shifts.last { $0.from <= turn.start }?.by ?? 0)
        let end = turn.end + (shifts.last { $0.from < turn.end }?.by ?? 0)
        return SpeakerTurn(speaker: turn.speaker, start: start, end: max(start, end))
    }
}

/// A running meeting: several ``MeetingSource``s summed by a ``MeetingMixer``, and ONE engine that transcribes
/// the mix, so the transcript is one continuous stream of `.mixed` segments.
///
/// - **One timeline.** The meeting begins when the first source has started (`t0`); each source is routed from
///   the moment it starts. A source that starts later has its lead (`offset`) written to its own track as
///   silence, and a source that restarts (it reports ``ResumableAudioSource/resumptions``) has the missing time
///   filled with silence, so every recording and every segment time is seconds since `t0`. In the mix each
///   source is placed by counting its own samples from its start (see ``MeetingMixer``): a backlog that arrives
///   at once keeps its place, so no source runs ahead of the others or falls silent.
/// - **The mix.** It is cut every 100 ms, a little behind the clock so late chunks still make it; at the stop
///   it is cut to the stop time, partial last frame included: the mix is exactly as long as the meeting, however
///   long stopping the sources takes. The engine hears it in its own format; the sink records each source
///   (through `convert`) and, with several sources, the mix on `.mixed`. With one source its track is the mix.
/// - **Speakers.** An optional ``SpeakerDiarizer`` is fed the same mix from its own task; its turns become
///   people (``Meeting/speakers``) and give the segments their speakers. Turns and segments of the last
///   ``SpeakerAssigner/recentWindow`` seconds are revised as the diarizer catches up (it lags); older ones are
///   settled and never looked at again, so a long meeting costs no more per frame than a short one. Settled
///   turns are appended to the turns file; the rest are written at the stop. Frames dropped from a lagging
///   diarizer's feed do not shift its turns: they are placed on the meeting's timeline.
/// - **Pause** silences every source (and the mix) and records one ``PausedRange``; **mute** silences one
///   stream and records a ``MutedRange``; the two are independent, and the sink records silence for both.
///   **Discard** stops everything and removes the meeting's folder.
/// - Events are tagged `.mixed` and timed from the event's range, else from `clock`.
/// - An engine that fails or lags never holds the recording back: its feed keeps only the newest ~30 s and is
///   ended when the engine fails, while the sink keeps writing.
/// - Finished segments are saved to the ``MeetingStore`` as they arrive; a revised speaker rewrites the file at
///   most once a second. Snapshots go out at most four times a second, the newest state always last.
public actor MeetingSession {
    /// Latest state; only the newest unread snapshot is kept.
    public nonisolated let snapshots: AsyncStream<MeetingSnapshot>
    private let snapshotSink: AsyncStream<MeetingSnapshot>.Continuation

    /// How far behind the clock the mix runs, so a chunk that arrives a little late still makes its frame.
    private static let mixLatency: TimeInterval = 0.2
    private static let mixTick: Duration = .milliseconds(50)
    /// The least time between two snapshots.
    private static let snapshotInterval: Duration = .milliseconds(250)
    /// The least time between two rewrites of the segments for revised speakers.
    private static let relabelSaveInterval: Duration = .seconds(1)

    private var meeting: Meeting
    private let sources: [MeetingSource]
    private let engine: any DictationEngine
    private let locale: Locale?
    private let diarizer: (any SpeakerDiarizer)?
    private let store: MeetingStore
    private let sink: any MeetingAudioSink
    private let convert: MeetingAudioConverter
    private let clock: @Sendable () -> TimeInterval
    private let feedCapacity: Int
    /// The clock value at the meeting's beginning; nil until the first source has started.
    private nonisolated let origin = Mutex<TimeInterval?>(nil)

    private var mixer = MeetingMixer()
    private var mixFormat: AudioFormatSpec?
    /// Where the mix ends: the stop time, once the meeting stops.
    private var mixEnd: TimeInterval?
    private var tickerTask: Task<Void, Never>?
    private var engineFeed: AsyncStream<AudioChunk>.Continuation?
    private var engineTask: Task<Void, Never>?

    // Speakers
    private struct DiarizerFrame: Sendable {
        var chunk: AudioChunk
        /// Where the frame begins on the meeting's timeline.
        var at: TimeInterval
    }
    private var diarizerTask: Task<Void, Never>?
    private var diarizerFeed: AsyncStream<DiarizerFrame>.Continuation?
    private var directory: SpeakerDirectory
    /// Diarizer cluster id → person id, for the live turns.
    private var clusterPerson: [String: PersonID] = [:]
    /// Turns that will not change any more (written to the turns file), and the ones that still may.
    private var settledTurns: [SpeakerTurn] = []
    private var recentTurns: [SpeakerTurn] = []
    /// How many of the diarizer's turns (it always answers with all of them) are settled.
    private var settledClusterCount = 0
    private var diarizerError: String?

    // Segments
    private var segments: [MeetingSegment] = []
    /// How many leading segments ended before the relabel window: they are never revised again.
    private var settledSegments = 0
    private var segmentsDirty = false
    private var lastSegmentsRewrite: ContinuousClock.Instant?
    private var segmentsRewriteTask: Task<Void, Never>?
    private var volatile: String?
    /// When the segment in progress was first heard.
    private var firstHeard: TimeInterval?
    private var engineError: String?

    // Mute and pause
    /// When each currently muted stream was muted.
    private var mutedSince: [TranscriptEvent.Stream: TimeInterval] = [:]
    /// When the meeting was paused, while it is.
    private var pausedSince: TimeInterval?

    private var audioError: String?
    private var saveError: String?
    /// Seconds of the meeting timeline each stream's recording covers (offset, audio and silence).
    private var covered: [TranscriptEvent.Stream: TimeInterval] = [:]
    private var sourceTasks: [Task<Void, Never>] = []
    private var resumeTasks: [Task<Void, Never>] = []
    /// Saves run one after another, in the order they were queued.
    private var saveTail: Task<Void, Never>?
    private var lastPublish: ContinuousClock.Instant?
    private var publishTask: Task<Void, Never>?
    private var started = false
    private var stopped = false
    private var tearingDown = false
    private var discarded = false

    /// - Parameters:
    ///   - locale: the language `engine` prepares for; nil lets it choose.
    ///   - diarizer: tells speakers apart in the mix while the meeting runs; nil leaves segments without speakers.
    ///   - clock: an increasing clock in seconds, on any origin. The meeting begins when the first source has
    ///     started; times are measured from there.
    ///   - feedCapacity: how many source-sized chunks (~20 ms) the engine's and the diarizer's feeds hold before
    ///     the oldest are dropped (~30 s); they hold a fifth as many 100 ms frames of the mix.
    public init(
        meeting: Meeting, sources: [MeetingSource], engine: any DictationEngine, locale: Locale? = nil,
        diarizer: (any SpeakerDiarizer)? = nil, store: MeetingStore,
        sink: any MeetingAudioSink, convert: @escaping MeetingAudioConverter,
        clock: @escaping @Sendable () -> TimeInterval, feedCapacity: Int = 1_500
    ) {
        self.meeting = meeting
        meetingID = meeting.id
        self.sources = sources
        self.engine = engine
        self.locale = locale
        self.diarizer = diarizer
        self.directory = SpeakerDirectory(meeting: meeting)
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

    /// Prepares the engine, starts every source (each is routed as soon as it has started), and saves the
    /// meeting as `recording`. If anything fails, or the calling task is cancelled (checked after the engine
    /// and after each source, since a model load cannot be interrupted), the sources already running are
    /// stopped and the error is rethrown.
    public func start() async throws {
        guard !started else { return }
        started = true
        do {
            let format = try await engine.prepare(locale: locale)
            // A model load cannot be interrupted; once it returns, a cancelled start stops here.
            try Task.checkCancellation()
            mixFormat = format
            mixer = MeetingMixer(sampleRate: format.sampleRate)
            for entry in sources {
                try Task.checkCancellation()
                let chunks = try await entry.source.start(format: format)
                let startedAt = clock()
                let t0 = origin.withLock { o -> TimeInterval in
                    if o == nil { o = startedAt }
                    return o!
                }
                await beginSource(entry, chunks: chunks, offset: max(0, startedAt - t0))
            }
            try Task.checkCancellation()
            origin.withLock { if $0 == nil { $0 = clock() } }
            meeting.state = .recording
            try await store.create(meeting)
            beginEngine(format)
            startTicker()
            startDiarizer()
        } catch {
            await teardown(flushMix: false)
            throw error
        }
        publishNow()
    }

    /// Fills what a stream's recording is missing, up to now, with silence (its own track and its place in the
    /// mix). A source that restarts calls this through ``ResumableAudioSource/resumptions``; shortfalls under
    /// ``MeetingSilence/tolerance`` are jitter and ignored. Chunks delivered right after the restart may land
    /// just ahead of the silence, which shifts them by no more than their own length.
    public func fillGap(stream: TranscriptEvent.Stream) async {
        guard started, !stopped, !tearingDown, let have = covered[stream] else { return }
        let missing = MeetingSilence.deficit(elapsed: elapsed, delivered: have)
        guard missing > 0 else { return }
        covered[stream] = have + missing
        mixer.skip(stream, seconds: missing)
        await writeSilence(missing, stream: stream)
    }

    /// Mutes or unmutes one stream. Manual and automatic mute both come through here. Nothing changes once the
    /// meeting has stopped.
    public func setMuted(_ muted: Bool, stream: TranscriptEvent.Stream) {
        guard started, !stopped else { return }
        if muted {
            guard mutedSince[stream] == nil else { return }
            mutedSince[stream] = elapsed
            mixer.mute(stream, at: elapsed)
        } else if let since = mutedSince.removeValue(forKey: stream) {
            mixer.unmute(stream, at: elapsed)
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
        mixer.pause(at: elapsed)
        publish()
    }

    public func resume() {
        guard !stopped, let since = pausedSince else { return }
        pausedSince = nil
        mixer.resume(at: elapsed)
        meeting.pausedRanges.append(PausedRange(start: since, end: elapsed))
        saveMeeting()
        publish()
    }

    /// Ends capture, drains the engine, closes any open mute or pause and finishes the recording. The meeting
    /// is saved as `processing`, ready for the after-stop chain.
    @discardableResult
    public func stop() async -> Meeting {
        guard !stopped else { return meeting }
        stopped = true
        let now = elapsed
        mixEnd = now
        await teardown(flushMix: true)

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
        // The turns still open to revision are final now; so are the speakers of the last segments.
        let rest = recentTurns
        settledTurns += rest
        recentTurns = []
        save { [store, id = meeting.id] in try await store.appendLiveTurns(rest, for: id) }
        segmentsRewriteTask?.cancel()
        if segmentsDirty { rewriteSegments() }
        await saveTail?.value
        do {
            let (muted, paused, duration, state, speakers) =
                (meeting.mutedRanges, meeting.pausedRanges, meeting.duration, meeting.state, meeting.speakers)
            if let merged = try await store.update(id: meeting.id, { m in
                m.mutedRanges = muted
                m.pausedRanges = paused
                m.duration = duration
                m.state = state
                for (id, info) in speakers where m.speakers[id] == nil && m.mergedSpeakers[id] == nil { m.speakers[id] = info }
            }) {
                meeting = merged
                directory = SpeakerDirectory(meeting: merged)
            }
        } catch { saveError = "\(error)" }
        do { try await sink.finish() } catch { audioError = "\(error)" }
        publishNow()
        snapshotSink.finish()
        return meeting
    }

    /// Gives a person a name while the meeting runs. Another person with that name merges with this one. The
    /// session owns the people while it records, so the rename goes through it: it shows in the next snapshot, is
    /// saved, and the diarizer's later turn updates keep it (they only add people for clusters never seen).
    public func renameSpeaker(_ person: PersonID, to name: String) {
        guard !stopped, !discarded, directory.speakers[person] != nil else { return }
        let merge = directory.rename(person, to: name)
        directory.save(into: &meeting)
        if let merge {
            // The diarizer's cluster for the merged person is the other person's from now on.
            for (cluster, owner) in clusterPerson where owner == merge.from { clusterPerson[cluster] = merge.into }
            segments = merge.apply(to: segments)
            settledTurns = merge.apply(to: settledTurns)
            recentTurns = merge.apply(to: recentTurns)
            markSegmentsDirty()
            let turns = settledTurns
            save { [store, id = meeting.id] in try await store.saveLiveTurns(turns, for: id) }
        }
        let (people, merged) = (directory.speakers, directory.merged)
        save { [store, id = meeting.id] in
            try await store.update(id: id) { m in
                m.speakers = people
                m.mergedSpeakers = merged
            }
        }
        publish()
    }

    /// Stops the capture and removes the meeting: its folder and everything recorded or saved in it. Nothing
    /// of the meeting is kept, and a later ``stop()`` does nothing.
    public func discard() async {
        guard !discarded else { return }
        discarded = true
        publishTask?.cancel()
        segmentsRewriteTask?.cancel()
        if !stopped {
            stopped = true
            if started { await teardown(flushMix: false) }
        }
        await saveTail?.value
        try? await sink.finish()  // close the files before their folder goes
        try? await store.deleteMeeting(id: meeting.id)
        snapshotSink.finish()
    }

    // MARK: Sources

    private func beginSource(_ input: MeetingSource, chunks: AsyncStream<AudioChunk>, offset: TimeInterval) async {
        let stream = input.stream
        covered[stream] = offset
        mixer.begin(stream, at: offset)
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

    /// Stops the ticker and the sources, cuts the rest of the mix (to ``mixEnd``) when `flushMix`, lets the
    /// engine and the diarizer deliver what is left, then ends them.
    private func teardown(flushMix: Bool) async {
        tearingDown = true
        tickerTask?.cancel()
        await tickerTask?.value
        tickerTask = nil
        for entry in sources { await entry.source.stop() }
        for task in sourceTasks { await task.value }
        for task in resumeTasks { task.cancel() }
        if flushMix, let mixEnd { await emitMix(flushingTo: mixEnd) }
        engineFeed?.finish()
        engineFeed = nil
        diarizerFeed?.finish()
        diarizerFeed = nil
        try? await engine.finish()
        await engineTask?.value
        await diarizerTask?.value
        sourceTasks = []
        resumeTasks = []
        engineTask = nil
        diarizerTask = nil
    }

    private func route(_ chunk: AudioChunk, stream: TranscriptEvent.Stream) async {
        let silenced = mutedSince[stream] != nil || pausedSince != nil
        let perSecond = chunk.format.sampleRate * Double(max(1, chunk.format.channelCount))
        let seconds = Double(chunk.samples.count) / perSecond
        covered[stream, default: 0] += seconds
        // The mixer silences what was muted or paused when the audio was heard, by its timestamp.
        mixer.append(chunk.samples, from: stream, at: elapsed)
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

    // MARK: Engine

    private func beginEngine(_ format: AudioFormatSpec) {
        // Newest audio wins: an engine that lags drops the oldest rather than growing without bound.
        let (audio, feed) = AsyncStream<AudioChunk>.makeStream(bufferingPolicy: .bufferingNewest(max(1, feedCapacity / 5)))
        engineFeed = feed
        let results = engine.transcribe(audio)
        engineTask = Task { [self] in
            do {
                for try await event in results { handle(event) }
            } catch {
                engineFailed(error)
            }
        }
    }

    private func engineFailed(_ error: any Error) {
        engineError = "\(error)"
        volatile = nil
        // No one reads this feed any more; the sink keeps recording the audio.
        engineFeed?.finish()
        engineFeed = nil
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
    /// little behind now (never past the stop), and sends it to the engine, the diarizer and the sink.
    private func emitMix(flushingTo end: TimeInterval?) async {
        guard let format = mixFormat else { return }
        let first = mixer.emittedSamples
        let frames: [[Float]]
        if let end {
            frames = mixer.flush(to: end)
        } else {
            frames = mixer.advance(to: min(mixEnd ?? .infinity, max(0, elapsed - Self.mixLatency)))
        }
        var position = first
        for samples in frames {
            let chunk = AudioChunk(samples: samples, format: format)
            engineFeed?.yield(chunk)
            diarizerFeed?.yield(DiarizerFrame(chunk: chunk, at: Double(position) / format.sampleRate))
            position += samples.count
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
        let (audio, feed) = AsyncStream<DiarizerFrame>.makeStream(bufferingPolicy: .bufferingNewest(max(1, feedCapacity / 5)))
        diarizerFeed = feed
        diarizerTask = Task { [self] in
            var timeline = DiarizerTimeline()
            do {
                for await frame in audio {
                    let format = frame.chunk.format
                    timeline.feeding(Double(frame.chunk.samples.count) / format.sampleRate, at: frame.at)
                    try await diarizer.feed(frame.chunk)
                    let answer = await diarizer.turns()
                    diarizerTurns(answer.map(timeline.meetingTime(of:)), final: false)
                }
                let answer = try await diarizer.finish()
                diarizerTurns(answer.map(timeline.meetingTime(of:)), final: true)
            } catch {
                diarizerFailed(error)
            }
        }
    }

    private func diarizerFailed(_ error: any Error) {
        diarizerError = "\(error)"
        publish()
    }

    /// New turns from the diarizer (every turn so far, on the meeting's timeline): map its clusters to people,
    /// settle the turns that ended before the relabel window (they are appended to the turns file), and
    /// re-assign the segments that ended within it (a diarizer lags, so it revises its newest turns). With
    /// `final`, the diarizer is done: nothing is settled here, ``stop()`` writes the rest.
    private func diarizerTurns(_ clusters: [SpeakerTurn], final: Bool) {
        let before = directory
        let cutoff = elapsed - SpeakerAssigner.recentWindow
        var newlySettled: [SpeakerTurn] = []
        var recent: [SpeakerTurn] = []
        for turn in clusters.dropFirst(settledClusterCount) {
            let mapped = SpeakerTurn(speaker: person(for: turn.speaker), start: turn.start, end: turn.end)
            if !final, recent.isEmpty, mapped.end < cutoff {
                newlySettled.append(mapped)
            } else {
                recent.append(mapped)
            }
        }
        settledClusterCount += newlySettled.count
        // People first, then the turns and segments that name them: a reader that sees an id can look it up.
        if directory != before {
            meeting.speakers = directory.speakers
            saveMeeting()
        }
        if !newlySettled.isEmpty {
            settledTurns += newlySettled
            save { [store, id = meeting.id, newlySettled] in try await store.appendLiveTurns(newlySettled, for: id) }
        }
        let changed = !newlySettled.isEmpty || recent != recentTurns
        recentTurns = recent
        guard changed else { return }
        relabelRecentSegments()
        publish()
    }

    /// Re-assigns the segments that ended within the relabel window; those before it are settled for good.
    private func relabelRecentSegments() {
        let cutoff = elapsed - SpeakerAssigner.recentWindow
        while settledSegments < segments.count, segments[settledSegments].end < cutoff { settledSegments += 1 }
        guard settledSegments < segments.count else { return }
        let open = segments[settledSegments...]
        let earliest = open.map(\.start).min() ?? cutoff
        let relabelled = SpeakerAssigner.relabelRecent(Array(open), turns: turns(endingAfter: earliest), now: elapsed)
        guard !relabelled.elementsEqual(open) else { return }
        segments.replaceSubrange(settledSegments..., with: relabelled)
        markSegmentsDirty()
    }

    /// The live turns that end after `time`: the recent ones and the settled ones reaching into it.
    private func turns(endingAfter time: TimeInterval) -> [SpeakerTurn] {
        var first = settledTurns.count
        while first > 0, settledTurns[first - 1].end > time { first -= 1 }
        return Array(settledTurns[first...]) + recentTurns
    }

    private func person(for cluster: String) -> PersonID {
        if let known = clusterPerson[cluster] { return known }
        let id = directory.add()
        clusterPerson[cluster] = id
        return id
    }

    // MARK: Events

    private func handle(_ event: TranscriptEvent) {
        let text = event.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard event.isFinal else {
            volatile = text.isEmpty ? nil : text
            if !text.isEmpty, firstHeard == nil { firstHeard = elapsed }
            publish()
            return
        }
        volatile = nil
        let heardAt = firstHeard
        firstHeard = nil
        guard !text.isEmpty else { return publish() }

        let start: TimeInterval, end: TimeInterval
        if let range = event.range {
            // The engine hears the mix from the meeting's first moment: its times are meeting times.
            (start, end) = (range.lowerBound, range.upperBound)
        } else {
            end = elapsed
            start = min(heardAt ?? end, end)
        }
        var segment = MeetingSegment(stream: .mixed, text: text, start: start, end: end)
        segment.speaker = SpeakerAssigner.speaker(start: start, end: end, turns: turns(endingAfter: start))
        segments.append(segment)
        save { [store, id = meeting.id, segment] in try await store.appendSegment(segment, to: id) }
        publish()
    }

    // MARK: Saving and publishing

    /// A saved segment's speaker changed: the segments file is rewritten, at most once a second.
    private func markSegmentsDirty() {
        segmentsDirty = true
        guard segmentsRewriteTask == nil else { return }
        let wait = lastSegmentsRewrite.map { Self.relabelSaveInterval - (ContinuousClock.now - $0) } ?? .zero
        if wait <= .zero { return rewriteSegments() }
        segmentsRewriteTask = Task { [self] in
            try? await Task.sleep(for: wait)
            guard !Task.isCancelled else { return }
            await rewriteSegmentsLater()
        }
    }

    private func rewriteSegmentsLater() {
        segmentsRewriteTask = nil
        if segmentsDirty { rewriteSegments() }
    }

    private func rewriteSegments() {
        segmentsDirty = false
        lastSegmentsRewrite = .now
        let all = segments
        save { [store, id = meeting.id] in try await store.replaceSegments(all, for: id) }
    }

    /// Writes only the fields the session owns, onto the meeting as it is on disk now (a rename survives; so
    /// does a speaker the user renamed or merged away, since the session only adds people the file has never had).
    private func saveMeeting() {
        let (muted, paused, duration, state, speakers) =
            (meeting.mutedRanges, meeting.pausedRanges, meeting.duration, meeting.state, meeting.speakers)
        save { [store, id = meeting.id] in
            try await store.update(id: id) { m in
                m.mutedRanges = muted
                m.pausedRanges = paused
                m.duration = duration
                m.state = state
                for (person, info) in speakers where m.speakers[person] == nil && m.mergedSpeakers[person] == nil {
                    m.speakers[person] = info
                }
            }
        }
    }

    private func save(_ work: @escaping @Sendable () async throws -> Void) {
        guard !discarded else { return }
        let previous = saveTail
        saveTail = Task { [self] in
            await previous?.value
            do { try await work() } catch { await saveFailed(error) }
        }
    }

    private func saveFailed(_ error: any Error) {
        saveError = "\(error)"
        publish()
    }

    /// Publishes the state, at most every ``snapshotInterval``: a change within it goes out at its end, so the
    /// newest state always arrives.
    private func publish() {
        guard !discarded, publishTask == nil else { return }
        let wait = lastPublish.map { Self.snapshotInterval - (ContinuousClock.now - $0) } ?? .zero
        if wait <= .zero { return publishNow() }
        publishTask = Task { [self] in
            try? await Task.sleep(for: wait)
            guard !Task.isCancelled else { return }
            await publishLater()
        }
    }

    private func publishLater() {
        publishTask = nil
        publishNow()
    }

    private func publishNow() {
        guard !discarded else { return }
        publishTask?.cancel()
        publishTask = nil
        lastPublish = .now
        snapshotSink.yield(
            MeetingSnapshot(
                meeting: meeting, segments: MeetingStore.ordered(segments), volatile: volatile.map { [.mixed: $0] } ?? [:],
                mutedStreams: Set(mutedSince.keys), engineErrors: engineError.map { [.mixed: $0] } ?? [:],
                audioError: audioError, saveError: saveError, isPaused: pausedSince != nil, diarizerError: diarizerError))
    }
}
