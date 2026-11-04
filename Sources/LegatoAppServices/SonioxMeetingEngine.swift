import Foundation
import LegatoAudio
import LegatoComposerDoc
import LegatoCore
import LegatoRoom
import LegatoSoniox

/// The live engine of a meeting: the mix of every source goes to Soniox on ONE diarized stream, and what comes
/// back is `TranscriptEvent`s for `MeetingSession`.
///
/// - **Speakers.** Every final segment carries Soniox's speaker label ("1", "2", …). The session turns labels into people.
/// - **Reconnect.** A stream that drops is replaced in the background (backoff). The audio meanwhile is held, newest
///   `backlog` seconds, and sent on the new stream, so a short outage costs nothing. What Soniox never heard is
///   reported as a gap (`TranscriptEvent.isGap`) that the transcript shows; the recording itself never stops. A new
///   stream numbers its speakers afresh, so its labels get a prefix (`1.2`): the same voice may appear as a second
///   person that the user can merge by renaming.
/// - **Rollover.** Soniox ends a stream at 300 minutes. At `rolloverAfter` the next stream connects while the old
///   one still listens, takes over, and the old one finishes its words.
/// - **Fatal.** A missing or rejected key and exhausted credits end the stream with that error (the session shows it
///   and keeps recording); every other failure is retried.
/// - **Log.** Each meeting logs its Room (`room.jsonl`) like a session, without the tail.
///
/// The type is named so it does not clash with the `DictationEngine` class of this module; it implements the
/// `LegatoCore` protocol of that name. It serves one meeting: `transcribe` is called once.
public final class SonioxMeetingEngine: LegatoCore.DictationEngine, Sendable {
    public struct Timing: Sendable {
        /// Audio seconds on one stream before the next one takes over (Soniox's cap is 300 minutes).
        public var rolloverAfter: TimeInterval = 285 * 60
        /// Audio held while there is no stream, seconds.
        public var backlog: TimeInterval = 10
        /// Waits between attempts to connect; the last one repeats.
        public var retryDelays: [Duration] = [.milliseconds(500), .seconds(1), .seconds(2), .seconds(4), .seconds(8), .seconds(15)]
        /// Speech Soniox had heard but not yet finalized when a stream dropped, seconds: the gap starts that far back.
        public var inFlight: TimeInterval = 2
        /// Shorter stretches are not reported as gaps.
        public var minimumGap: TimeInterval = 1
        public init() {}
    }

    public let id = "soniox-stt-rt-v6"
    private let apiKey: @Sendable () -> String
    private let config: SonioxConfig
    private let log: SessionLog?
    private let makeSocket: @Sendable () -> any SonioxSocket
    private let timing: Timing

    /// - Parameters:
    ///   - apiKey: read when a stream connects, so a key saved meanwhile is used.
    ///   - config: use `diarization: true`.
    ///   - log: the meeting's session log; nil logs nothing.
    public init(
        apiKey: @escaping @Sendable () -> String, config: SonioxConfig, log: SessionLog? = nil,
        makeSocket: @escaping @Sendable () -> any SonioxSocket = { URLSessionSonioxSocket() }, timing: Timing = Timing()
    ) {
        self.apiKey = apiKey; self.config = config; self.log = log; self.makeSocket = makeSocket; self.timing = timing
    }

    public func installAssets(locale: Locale?) -> AsyncStream<Double> { AsyncStream { $0.finish() } }

    /// Soniox needs no model; the key must exist, so a meeting without one fails before it records.
    /// The languages are the config's hints (German and English), whatever `locale` says.
    public func prepare(locale: Locale?) async throws -> AudioFormatSpec {
        guard !apiKey().trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw SonioxError.missingKey }
        return AudioFormatSpec(sampleRate: 16_000, channelCount: 1)
    }

    public func transcribe(_ input: AsyncStream<AudioChunk>) -> AsyncThrowingStream<TranscriptEvent, Error> {
        let (stream, continuation) = AsyncThrowingStream<TranscriptEvent, Error>.makeStream()
        let runner = MeetingStreamRunner(
            apiKey: apiKey, config: config, room: Room(log: log, segmentRouting: .intercepted, logsTail: false),
            makeSocket: makeSocket, timing: timing, output: continuation)
        let task = Task { await runner.run(input) }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    /// Everything is finalized when the input ends, so there is nothing to flush here.
    public func finish() async throws {}
}

/// The state of one meeting's connections. An actor: audio arrives from one task, connects and drops from others.
private actor MeetingStreamRunner {
    private struct Live {
        let id: Int
        let client: SonioxClient
        /// Audio seconds of the first sample sent on this stream.
        let since: TimeInterval
    }

    private let apiKey: @Sendable () -> String
    private let config: SonioxConfig
    private let room: Room
    private let makeSocket: @Sendable () -> any SonioxSocket
    private let timing: SonioxMeetingEngine.Timing
    private let output: AsyncThrowingStream<TranscriptEvent, Error>.Continuation

    private var converter = PCM16Converter()
    /// Audio seconds received so far: the clock of every time in the transcript.
    private var fed: TimeInterval = 0
    private var live: Live?
    private var generation = 0
    private var connecting: Task<Void, Never>?
    private var retiring: [Task<Void, Never>] = []
    /// While a stream is being adopted or the backlog is sent, new audio queues behind it to keep its order.
    private var adopting = false
    private var flushing = false
    private var backlog: [(pcm: Data, start: TimeInterval, seconds: TimeInterval)] = []
    private var backlogSeconds: TimeInterval = 0
    /// Where Soniox lost audio: from when it was last heard, until the audio resumes.
    private var gapFrom: TimeInterval?
    private var lastHeard: TimeInterval = 0
    private var failures = 0
    private var closed = false
    private var fatal: SonioxError?

    init(
        apiKey: @escaping @Sendable () -> String, config: SonioxConfig, room: Room,
        makeSocket: @escaping @Sendable () -> any SonioxSocket, timing: SonioxMeetingEngine.Timing,
        output: AsyncThrowingStream<TranscriptEvent, Error>.Continuation
    ) {
        self.apiKey = apiKey; self.config = config; self.room = room
        self.makeSocket = makeSocket; self.timing = timing; self.output = output
    }

    func run(_ input: AsyncStream<AudioChunk>) async {
        let events = await room.subscribe(participant: .ui, channels: [.asrSegment, .asrRawTail], buffering: .unbounded)
        let reader = Task { [room, output] in
            for await envelope in events {
                if envelope.channel == .asrSegment { await room.resolveSegment(envelope.id) }
                guard let event = Self.event(from: envelope) else { continue }
                heard(event)
                output.yield(event)
            }
        }
        startConnecting()
        for await chunk in input {
            guard let pcm = try? converter.convert(chunk) else { continue }
            let seconds = Double(chunk.samples.count) / (chunk.format.sampleRate * Double(max(1, chunk.format.channelCount)))
            await send(pcm, seconds: seconds)
        }
        await end()
        try? await room.cancel()
        await reader.value
        output.finish()
    }

    // MARK: Audio

    private func send(_ pcm: Data, seconds: TimeInterval) async {
        let start = fed
        fed += seconds
        guard fatal == nil else { return }
        if let current = live, !adopting, !flushing {
            if fed - current.since >= timing.rolloverAfter { startConnecting() }
            do { return try await current.client.sendAudio(pcm) } catch { await lost(current.id) }
        }
        enqueue(pcm, start: start, seconds: seconds)
        if live == nil { startConnecting() }
    }

    /// Holds audio for the next stream: the newest `backlog` seconds; what falls out is lost to the transcript.
    private func enqueue(_ pcm: Data, start: TimeInterval, seconds: TimeInterval) {
        backlog.append((pcm, start, seconds))
        backlogSeconds += seconds
        guard !adopting else { return }
        while backlogSeconds > timing.backlog, backlog.count > 1 {
            let lost = backlog.removeFirst()
            backlogSeconds -= lost.seconds
            gapFrom = min(gapFrom ?? lost.start, lost.start)
        }
    }

    // MARK: Connections

    private func startConnecting() {
        guard connecting == nil, !closed, fatal == nil else { return }
        generation += 1
        let id = generation
        connecting = Task { [weak self] in await self?.connect(id) }
    }

    /// Opens a stream, trying again with backoff until one starts, the key is refused or the meeting ends.
    private func connect(_ id: Int) async {
        // A stream that connects and drops again at once must not become a hot loop.
        var attempt = max(0, failures - 1)
        var wait = failures > 0
        while !Task.isCancelled, !closed {
            if wait { try? await Task.sleep(for: delay(attempt)) }
            wait = true
            let client = makeClient(id)
            do {
                try await client.open(apiKey: apiKey())
                try await client.begin()
                return await adopt(client, id: id)
            } catch {
                await client.close()
                let failure = error as? SonioxError ?? .network
                if Self.isFatal(failure) { return fail(failure) }
                attempt += 1
            }
        }
    }

    private func delay(_ attempt: Int) -> Duration {
        timing.retryDelays[min(attempt, max(0, timing.retryDelays.count - 1))]
    }

    private func makeClient(_ id: Int) -> SonioxClient {
        // The first stream's labels stay as Soniox gives them; later streams number their speakers afresh.
        SonioxClient(
            room: room, config: config, socket: makeSocket(), audioOrigin: 0, quietFailure: .always,
            speakerPrefix: id == 1 ? "" : "\(id).", onDrop: { [weak self] in await self?.clientDropped(id) })
    }

    /// The new stream starts at the oldest audio still held (or the next audio, when nothing is): its times are
    /// measured from there. Audio that arrives meanwhile waits behind the backlog.
    private func adopt(_ client: SonioxClient, id: Int) async {
        connecting = nil
        guard !closed else { return await client.close() }
        adopting = true
        let since = backlog.first?.start ?? fed
        await client.setAudioOrigin(since)
        guard !closed else {
            adopting = false
            return await client.close()
        }
        let previous = live
        live = Live(id: id, client: client, since: since)
        adopting = false
        if let previous { retire(previous.client) }
        // The stream may have failed while it was being adopted: nobody was told, as it was not live yet.
        if await client.lastFailure != nil {
            await clientDropped(id)
            return
        }
        if let from = gapFrom {
            gapFrom = nil
            if since - from >= timing.minimumGap { output.yield(TranscriptEvent(stream: .mixed, text: "", isFinal: true, range: from..<since, isGap: true)) }
        }
        await flush(id: id)
    }

    private func flush(id: Int) async {
        flushing = true
        while let held = backlog.first, let current = live, current.id == id {
            backlog.removeFirst()
            backlogSeconds -= held.seconds
            do { try await current.client.sendAudio(held.pcm) } catch {
                backlog.insert(held, at: 0)
                backlogSeconds += held.seconds
                await lost(id)
                break
            }
        }
        flushing = false
        if live == nil { startConnecting() }
    }

    private func clientDropped(_ id: Int) async {
        guard live?.id == id else { return }
        await lost(id)
        startConnecting()
    }

    /// The live stream `id` failed: a refused key ends the session's transcription, anything else is retried.
    private func lost(_ id: Int) async {
        guard let current = live, current.id == id else { return }
        if let failure = await current.client.lastFailure, Self.isFatal(failure) { return fail(failure) }
        dropped(id)
    }

    private func dropped(_ id: Int) {
        guard let current = live, current.id == id else { return }
        live = nil
        failures += 1
        // Speech Soniox had heard but not finalized is lost with the stream.
        gapFrom = gapFrom ?? max(current.since, lastHeard, fed - timing.inFlight)
        Task { await current.client.close() }
    }

    /// A stream whose time is over finishes its words, off the audio path.
    private func retire(_ client: SonioxClient) {
        retiring.append(Task {
            try? await client.finish(micOff: false)
            await client.close()
        })
    }

    private func fail(_ error: SonioxError) {
        guard fatal == nil else { return }
        fatal = error
        output.finish(throwing: error)
        connecting = nil
        let current = live
        live = nil
        backlog = []; backlogSeconds = 0
        Task { await current?.client.close() }
    }

    /// The input ended: say what was missed, let the last stream finish its words and end the session.
    private func end() async {
        closed = true
        connecting?.cancel()
        let pending = connecting
        connecting = nil
        await pending?.value
        if live == nil, fatal == nil, let from = gapFrom ?? backlog.first?.start, fed - from >= timing.minimumGap {
            output.yield(TranscriptEvent(stream: .mixed, text: "", isFinal: true, range: from..<fed, isGap: true))
        }
        if let current = live {
            // Soniox recommends a little silence before the finalize, so the last word is not cut.
            try? await current.client.sendAudio(Data(count: 6_400))
            try? await current.client.finish(micOff: false)
            await current.client.close()
            live = nil
        }
        for task in retiring { await task.value }
    }

    private func heard(_ event: TranscriptEvent) {
        failures = 0
        if event.isFinal, let end = event.range?.upperBound { lastHeard = max(lastHeard, end) }
    }

    private static func isFatal(_ error: SonioxError) -> Bool {
        [.missingKey, .provider(401), .provider(402)].contains(error)
    }

    /// A segment or tail as the session wants it. Times are meeting times: the stream's audio origin is the audio
    /// second of its first sample, so an envelope's `tOrigin` already is one.
    private static func event(from envelope: Envelope) -> TranscriptEvent? {
        switch envelope.channel {
        case .asrRawTail:
            let text = (try? envelope.payload["text"]?.decode(String.self)) ?? ""
            return TranscriptEvent(stream: .mixed, text: text, isFinal: false)
        case .asrSegment:
            guard let words = try? envelope.payload["words"]?.decode([Word].self), !words.isEmpty else { return nil }
            let metadata = envelope.payload["metadata"]
            var range: Range<TimeInterval>?
            if let t0 = try? metadata?["t0"]?.decode(Double.self), let t1 = try? metadata?["t1"]?.decode(Double.self) {
                let start = envelope.tOrigin
                range = start..<max(start, start - t0 + t1)
            }
            let speaker = try? metadata?["speaker"]?.decode(String.self)
            return TranscriptEvent(stream: .mixed, text: words.map(\.text).joined(separator: " "), isFinal: true, range: range, speaker: speaker)
        default:
            return nil
        }
    }
}
