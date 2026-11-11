import Foundation
import Observation
import LegatoComposerDoc
import LegatoRoom
import LegatoSoniox
import LegatoVocabulary

/// The dictation route's Soniox side, shared by the iOS `KeyboardSession` and the Mac dictation hotkey:
/// a Room of its own (never the composition's), one held, unbilled Soniox connection (`WarmStream`), the take
/// that starts on it when the gate opens, and the ordered stream of finalized lines into a `DictationRouteSink`.
///
/// The owner decides when audio flows (`send` is only called while its gate is open) and what happens around
/// a take; the engine knows nothing of surfaces, microphones or fields.
@MainActor @Observable public final class DictationEngine {
    /// The route's uncommitted words.
    public private(set) var tail = ""
    public private(set) var voiceIsolationStatus: String?
    @ObservationIgnored private let sink: any DictationRouteSink
    @ObservationIgnored private let sonioxKey: @MainActor () -> String
    @ObservationIgnored private let makeSocket: @Sendable () -> any SonioxSocket
    @ObservationIgnored private let vocabularyURL: URL
    @ObservationIgnored private let personalPrompt: @MainActor () -> String
    @ObservationIgnored private let now: @MainActor () -> Double
    @ObservationIgnored private var room: Room?
    @ObservationIgnored private var stream: WarmStream?
    /// The started stream of the current take; nil while idle (only a held connection exists).
    @ObservationIgnored private var active: SonioxClient?
    @ObservationIgnored private var events: Task<Void, Never>?
    /// Audio sent while the stream reconnects, delivered once it is live (bounded to ~3 s).
    @ObservationIgnored private var backlog: [Data] = []
    @ObservationIgnored private var sending = false
    @ObservationIgnored private var finishing: Task<Void, Never>?
    @ObservationIgnored private var lineSequence = 0
    #if DEBUG || LEGATO_INTERNAL
    /// The scripted stream of `debugReplay` while it runs.
    @ObservationIgnored private var replaying: SonioxClient?
    #endif
    /// Every live tail (the owner's latency probe or HUD).
    @ObservationIgnored public var onTail: (@MainActor (String) -> Void)?

    public init(sink: any DictationRouteSink, sonioxKey: @escaping @MainActor () -> String,
                makeSocket: @escaping @Sendable () -> any SonioxSocket, vocabularyURL: URL,
                personalPrompt: @escaping @MainActor () -> String = { UserDefaults.standard.string(forKey: "composer.personalPrompt") ?? "" },
                now: @escaping @MainActor () -> Double = { ProcessInfo.processInfo.systemUptime }) {
        self.sink = sink; self.sonioxKey = sonioxKey; self.makeSocket = makeSocket
        self.vocabularyURL = vocabularyURL; self.personalPrompt = personalPrompt; self.now = now
    }

    public var isOpen: Bool { stream != nil }
    public var hasActiveTake: Bool { active != nil }
    /// A debug replay stands in for the microphone now.
    var isReplaying: Bool {
        #if DEBUG || LEGATO_INTERNAL
        replaying != nil
        #else
        false
        #endif
    }
    var liveSince: Double? { stream?.liveSince }
    var reconnects: Int { stream?.reconnects ?? 0 }
    var isLive: Bool { stream?.isLive ?? false }
    var hasBacklog: Bool { !backlog.isEmpty }

    /// Opens the route (Room, events, held connection); a no-op that re-warms when already open.
    public func open() {
        guard stream == nil else { stream?.warm(); return }
        let room = Room(segmentRouting: .intercepted)
        self.room = room
        events = Task { [weak self] in
            let events = await room.subscribe(participant: .ui, channels: [.asrSegment, .asrRawTail, .asrBoundary, .session], buffering: .unbounded)
            for await event in events {
                guard !Task.isCancelled, let self else { return }
                await self.receive(event, room: room)
            }
        }
        let socket = makeSocket, key = sonioxKey, vocabulary = vocabularyURL
        let prompt = personalPrompt()
        let stream = WarmStream(connect: { onDrop in
            let terms = (try? await VocabularyStore(fileURL: vocabulary).snapshot().entries.filter { !$0.blocked }.map(\.text)) ?? []
            let config = SonioxConfig(mode: "Dictation", personalPrompt: prompt, terms: terms)
            let client = SonioxClient(room: room, config: config, socket: socket(), quietFailure: .always, onDrop: onDrop)
            try await client.open(apiKey: key()); try await client.hold()
            return client
        }, now: now)
        self.stream = stream; stream.warm()
    }

    /// Starts the take on the held connection (or a fresh one) and holds the next connection right away.
    public func activate() async {
        voiceIsolationStatus = nil
        if stream == nil { open() }
        guard active == nil, let stream else { return }
        guard let held = await stream.take() else { stream.warm(); return }
        stream.warm()
        do { try await held.begin(backgroundText: sink.backgroundText); active = held } catch { await held.close() }
    }

    /// Audio goes out in order; a take whose stream dropped continues on the next held connection.
    public func send(_ pcm: Data) async {
        backlog.append(pcm)
        if backlog.count > 100 { backlog.removeFirst(backlog.count - 100) }
        await flush()
    }
    func flush() async {
        guard !sending else { return }
        sending = true
        defer { sending = false }
        while !backlog.isEmpty, stream != nil {
            if active == nil { await activate() }
            guard let take = active else { return }
            let chunk = backlog.removeFirst()
            do { try await take.sendAudio(chunk) } catch { backlog.insert(chunk, at: 0); active = nil; return }
        }
    }

    /// Stop routing and finalize (after ~200 ms of silence, as Soniox recommends). The finalized stream ends in
    /// the background once its words are final; a held, unbilled connection waits for the next take.
    public func finalizeTake() async {
        await flush()
        guard let take = active else { return }
        active = nil
        try? await take.sendAudio(Data(count: 6400))
        finishing = Task { try? await take.finish(micOff: false) }
    }

    /// Cuts the stream now (Soniox `finalize`) without ending the take: every word spoken so far becomes final, and the
    /// sink gets a `finalize` boundary once they are all through. False when no stream would answer (nothing to cut).
    public func finalizeChunk() async -> Bool {
        #if DEBUG || LEGATO_INTERNAL
        if let replaying { return (try? await replaying.finalizeChunk()) ?? false }
        #endif
        guard let take = active else { return false }
        await flush()
        return (try? await take.finalizeChunk()) ?? false
    }

    /// Waits for the last finalized take to end (its words are final), at most `timeout`.
    public func waitForFinish(timeout: Duration) async {
        guard let finishing else { return }
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await finishing.value }
            group.addTask { try? await Task.sleep(for: timeout) }
            await group.next()
            group.cancelAll()
        }
        // A later take's finish may have replaced it meanwhile: that one is still to be waited for.
        if self.finishing == finishing { self.finishing = nil }
    }

    /// Stop routing and drop the take's unfinished words (surface change, keyboard gone); delivered lines stay
    /// with the sink. The route closes too; the owner reopens it for the next take.
    public func abandonTake() async {
        backlog = []
        let take = active; active = nil
        await take?.close()
        await close()
    }

    public func close() async {
        #if DEBUG || LEGATO_INTERNAL
        await replaying?.close(); replaying = nil
        #endif
        let stream = self.stream, room = self.room, take = active
        self.stream = nil; self.room = nil; backlog = []; active = nil
        await take?.close()
        await stream?.close()
        events?.cancel(); events = nil
        try? await room?.cancel()
        if !tail.isEmpty { tail = "" }
    }

    /// A new session starts counting lines from 0.
    public func resetSequence() { lineSequence = 0 }

    private func receive(_ event: Envelope, room: Room) async {
        guard room === self.room else { return }
        switch event.channel {
        case .session:
            if event.payload["event"] == .string("asr.voiceIsolation"), case .string(let state) = event.payload["status"] {
                voiceIsolationStatus = ComposerSession.voiceIsolationMessage(state)
            }
        case .asrSegment:
            await room.resolveSegment(event.id)
            guard let words = try? event.payload["words"]?.decode([Word].self), !words.isEmpty else { return }
            let reason = (try? event.payload["metadata"]?["reason"]?.decode(String.self)) ?? ""
            await deliver(words: words, reason: reason)
        case .asrBoundary:
            if case .string(let reason) = event.payload["reason"], reason == "finalize" || reason == "finished" { sink.boundary(reason) }
        case .asrRawTail:
            let text = (try? event.payload["text"]?.decode(String.self)) ?? ""
            tail = text
            onTail?(text)
            sink.tailChanged(text)
            if !text.isEmpty { sink.speechActivity() }
        default: break
        }
    }
    private func deliver(words: [Word], reason: String) async {
        let line = DictationRouteLine(sequence: lineSequence, text: words.map(\.text).joined(separator: " "), words: words, reason: reason)
        lineSequence += 1
        await sink.receive(line)
    }

    #if DEBUG || LEGATO_INTERNAL
    /// Debug bridge: a recorded token timeline stands in for the Soniox socket. Every response goes through the
    /// provider decoder and segmenter (`SonioxClient.injectDebugFrame`), so segments, the live tail and the sink
    /// see exactly what a spoken take produces; then the take is finalized like a stop. `speed` 2 replays twice as
    /// fast. Needs the open route (the keyboard on the typing surface).
    public func debugReplay(_ timeline: DictationReplayTimeline, speed: Double = 1) async throws {
        guard let room else { throw DictationReplayTimeline.ReplayError.routeClosed }
        await replaying?.close()
        let client = SonioxClient(room: room, config: SonioxConfig(mode: "Dictation"), quietFailure: .always)
        replaying = client
        try await client.startDebug()
        var last = 0.0
        for frame in timeline.frames {
            let wait = (frame.at - last) / max(0.1, speed)
            if wait > 0.001 { try await Task.sleep(for: .seconds(wait)) }
            last = frame.at
            try await client.injectDebugFrame(frame.json)
        }
        try await client.finish(micOff: false)
        replaying = nil
    }

    /// Debug bridge: a finalized line enters exactly where a Soniox segment does (the sink).
    @discardableResult public func debugLine(_ text: String) async -> Bool {
        let words = text.split(whereSeparator: \.isWhitespace).map { Word(text: String($0), confidence: 0.95, language: "de") }
        guard !words.isEmpty else { return false }
        tail = ""
        await deliver(words: words, reason: "debug")
        return true
    }
    /// Debug bridge: sets (or with empty text clears) the live partial.
    public func debugTail(_ text: String) {
        tail = text
        onTail?(text)
        sink.tailChanged(text)
        if !text.isEmpty { sink.speechActivity() }
    }
    #endif
}
