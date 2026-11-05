import Foundation
import Synchronization
import Testing
import LegatoCore
import LegatoRoom
import LegatoSoniox
@testable import LegatoAppServices

/// Holds a socket's connect until the test opens it, so a test decides when a stream may come up instead of
/// racing a retry delay.
final class PullCount: Sendable { let value = Mutex(0) }

final class ConnectGate: Sendable {
    private let signal = AsyncStream<Void>.makeStream()
    func open() { signal.continuation.finish() }
    func wait() async { for await _ in signal.stream {} }
}

/// A Soniox socket the test drives: it answers a finalize with `<fin>` and the end-of-stream with `finished`.
actor MeetingSocket: SonioxSocket {
    private(set) var sent: [SonioxFrame] = []
    private(set) var closed = false
    private var inbox: [Result<SonioxFrame, any Error>] = []
    private var waiter: CheckedContinuation<SonioxFrame, any Error>?
    private let refuseConnect: Bool
    private let gate: ConnectGate?

    init(refuseConnect: Bool = false, gate: ConnectGate? = nil) { (self.refuseConnect, self.gate) = (refuseConnect, gate) }

    var audio: [Data] { sent.compactMap { if case .binary(let data) = $0 { data } else { nil } } }
    var configuration: String? {
        sent.compactMap { if case .text(let text) = $0, text.contains("stt-rt") { text } else { nil } }.first
    }
    var finalizes: Int { sent.filter { $0 == .text(#"{"type":"finalize"}"#) }.count }

    func connect(request: URLRequest) async throws {
        await gate?.wait()
        if refuseConnect { throw SonioxError.network }
    }
    func send(_ frame: SonioxFrame) async throws {
        guard !closed else { throw SonioxError.network }
        sent.append(frame)
        if frame == .text(#"{"type":"finalize"}"#) { feed(#"{"tokens":[{"text":"<fin>","is_final":true}]}"#) }
        if frame == .text("") { feed(#"{"finished":true}"#) }
    }
    func receive() async throws -> SonioxFrame {
        if !inbox.isEmpty { return try inbox.removeFirst().get() }
        if closed { throw SonioxError.network }
        return try await withCheckedThrowingContinuation { waiter = $0 }
    }
    func close() async {
        closed = true
        waiter?.resume(throwing: SonioxError.cancelled)
        waiter = nil
    }
    func feed(_ text: String) { deliver(.success(.text(text))) }
    /// The provider's side hangs up (or answers with an error): the next receive throws `error`.
    func fail(_ error: SonioxError = .network) { deliver(.failure(error)) }

    private func deliver(_ result: Result<SonioxFrame, any Error>) {
        if let waiter { self.waiter = nil; waiter.resume(with: result) } else { inbox.append(result) }
    }
}

final class MeetingSockets: Sendable {
    private let all = Mutex<[MeetingSocket]>([])
    private let refusals: Mutex<Int>
    private let gate: ConnectGate?
    init(refusingFirst: Int = 0, gate: ConnectGate? = nil) {
        refusals = Mutex(refusingFirst)
        self.gate = gate
    }
    func make() -> MeetingSocket {
        let refuse = refusals.withLock { count -> Bool in
            defer { count = max(0, count - 1) }
            return count > 0
        }
        let socket = MeetingSocket(refuseConnect: refuse, gate: gate)
        all.withLock { $0.append(socket) }
        return socket
    }
    var count: Int { all.withLock { $0.count } }
    func at(_ index: Int) -> MeetingSocket? { all.withLock { $0.indices.contains(index) ? $0[index] : nil } }
}

/// One engine on scripted sockets, with the audio fed by hand and every event collected.
final class MeetingEngineRig: Sendable {
    static let format = AudioFormatSpec(sampleRate: 16_000, channelCount: 1)
    let sockets: MeetingSockets
    let engine: SonioxMeetingEngine
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("legato-engine-\(UUID().uuidString)")
    let log: SessionLog
    private let input = AsyncStream<AudioChunk>.makeStream()
    private let events = Mutex<[TranscriptEvent]>([])
    private let outcome = Mutex<(any Error)?>(nil)
    private let ended = Mutex(false)
    private let pullCount = PullCount()
    var pulls: Int { pullCount.value.withLock { $0 } }

    init(key: String = "sk-test", refusingFirst: Int = 0, gate: ConnectGate? = nil, timing: SonioxMeetingEngine.Timing = .tests) throws {
        let sockets = MeetingSockets(refusingFirst: refusingFirst, gate: gate)
        self.sockets = sockets
        log = try SessionLog(rootDirectory: root, sessionID: "log", secrets: [key])
        engine = SonioxMeetingEngine(
            apiKey: { key }, config: SonioxConfig(mode: "Meeting", diarization: true), log: log,
            makeSocket: { sockets.make() }, timing: timing)
    }

    private func counted(_ source: AsyncStream<AudioChunk>) -> AsyncStream<AudioChunk> {
        nonisolated(unsafe) var chunks = source.makeAsyncIterator()  // only the engine's one reader pulls
        return AsyncStream(unfolding: { [pullCount] in
            pullCount.value.withLock { $0 += 1 }
            return await chunks.next()
        })
    }

    /// - Parameter countingPulls: ``pulls`` counts how often the engine asked for the next chunk; with `n` chunks
    ///   fed, `n + 1` pulls mean it has handled all of them and waits for more.
    func start(countingPulls: Bool = false) {
        let stream = engine.transcribe(countingPulls ? counted(input.stream) : input.stream)
        Task {
            do { for try await event in stream { events.withLock { $0.append(event) } } } catch { outcome.withLock { $0 = error } }
            ended.withLock { $0 = true }
        }
    }

    /// `seconds` of audio, in 100 ms chunks.
    func hear(_ seconds: Double, level: Float = 0.5) {
        for _ in 0..<Int((seconds * 10).rounded()) {
            input.continuation.yield(AudioChunk(samples: Array(repeating: level, count: 1_600), format: Self.format))
        }
    }
    func endInput() { input.continuation.finish() }

    var received: [TranscriptEvent] { events.withLock { $0 } }
    var finals: [TranscriptEvent] { received.filter { $0.isFinal && !$0.isGap } }
    var gaps: [TranscriptEvent] { received.filter(\.isGap) }
    var failure: (any Error)? { outcome.withLock { $0 } }
    var isEnded: Bool { ended.withLock { $0 } }
    func cleanup() { try? FileManager.default.removeItem(at: root) }
}

extension SonioxMeetingEngine.Timing {
    static var tests: Self {
        var timing = Self()
        timing.retryDelays = [.milliseconds(5)]
        timing.backlog = 5
        return timing
    }
}

private func tokens(_ words: [(String, Int, Int, String?)]) -> String {
    let list = words.map { text, start, end, speaker in
        #"{"text":"\#(text)","is_final":true,"start_ms":\#(start),"end_ms":\#(end)"# + (speaker.map { #","speaker":"\#($0)""# } ?? "") + "}"
    }
    return #"{"tokens":["# + list.joined(separator: ",") + "]}"
}

@Suite(.timeLimit(.minutes(1))) struct SonioxMeetingEngineTests {
    @Test func aMeetingWithoutAKeyFailsBeforeItRecords() async throws {
        let engine = SonioxMeetingEngine(apiKey: { "  " }, config: SonioxConfig(diarization: true))
        await #expect(throws: SonioxError.missingKey) { try await engine.prepare(locale: nil) }
        let ready = SonioxMeetingEngine(apiKey: { "sk" }, config: SonioxConfig(diarization: true))
        #expect(try await ready.prepare(locale: Locale(identifier: "de-DE")) == MeetingEngineRig.format)
    }

    @Test func oneDiarizedStreamCarriesTheMixAndSpeakersComeBack() async throws {
        let rig = try MeetingEngineRig()
        defer { rig.cleanup() }
        rig.start()
        rig.hear(1)
        await eventually("the stream starts") { await rig.sockets.at(0)?.configuration != nil }
        let socket = try #require(rig.sockets.at(0))
        let configuration = try #require(await socket.configuration)
        #expect(configuration.contains(#""enable_speaker_diarization":true"#))

        await socket.feed(tokens([("Hello", 200, 500, "1"), (" there.", 500, 900, "1")]))
        await socket.feed(tokens([(" Hi", 1_000, 1_200, "2"), (" you.", 1_200, 1_500, "2")]))
        await eventually("two segments") { rig.finals.count == 2 }
        let first = rig.finals[0], second = rig.finals[1]
        #expect(first.text == "Hello there." && first.speaker == "1")
        #expect(second.text == "Hi you." && second.speaker == "2")
        #expect(first.range == 0.2..<0.9 && second.range == 1.0..<1.5, "times are meeting times")
        #expect(first.stream == .mixed)
        await eventually("the audio reaches Soniox") { await socket.audio.reduce(0) { $0 + $1.count } >= 32_000 }

        rig.endInput()
        await eventually("the session ends") { rig.isEnded }
        #expect(rig.failure == nil)
        #expect(await socket.finalizes == 1)
    }

    @Test func theTailIsPassedOnButNotLogged() async throws {
        let rig = try MeetingEngineRig()
        defer { rig.cleanup() }
        rig.start()
        rig.hear(0.5)
        await eventually("the stream starts") { await rig.sockets.at(0)?.configuration != nil }
        let socket = try #require(rig.sockets.at(0))
        await socket.feed(#"{"tokens":[{"text":" speculative","is_final":false}]}"#)
        await socket.feed(tokens([("Done.", 300, 600, "1")]))
        await eventually("tail and segment") { rig.received.contains { !$0.isFinal && $0.text.trimmingCharacters(in: .whitespaces) == "speculative" } && rig.finals.count == 1 }
        rig.endInput()
        await eventually("the session ends") { rig.isEnded }
        let logged = try String(contentsOf: rig.log.roomURL, encoding: .utf8)
        #expect(logged.contains("asr.segment") && logged.contains("asr.started"))
        #expect(!logged.contains("speculative") && !logged.contains("asr.raw-tail") && !logged.contains("asr.tail"))
        #expect(!logged.contains("sk-test"))
    }

    @Test func aDroppedStreamReconnectsAndTheHeldAudioFollows() async throws {
        let rig = try MeetingEngineRig()
        defer { rig.cleanup() }
        rig.start()
        rig.hear(1)
        await eventually("the first stream") { await rig.sockets.at(0)?.configuration != nil }
        // Soniox finalizes only what it has heard.
        await eventually("the audio is sent") { await rig.sockets.at(0)?.audio.reduce(0) { $0 + $1.count } ?? 0 >= 32_000 }
        await rig.sockets.at(0)?.feed(tokens([("Before.", 100, 800, "1")]))
        await eventually("its segment") { rig.finals.count == 1 }

        await rig.sockets.at(0)?.fail()
        await eventually("a second stream") { await rig.sockets.at(1)?.configuration != nil }
        rig.hear(0.5)  // heard right after: waits for, or follows, the new stream
        let second = try #require(rig.sockets.at(1))
        await eventually("the audio follows") { await second.audio.reduce(0) { $0 + $1.count } >= 16_000 }

        // The second stream numbers its speakers afresh; its prefix keeps them apart from the first stream's.
        await second.feed(tokens([("After.", 300, 900, "1")]))
        await eventually("its segment") { rig.finals.count == 2 }
        #expect(rig.finals[0].speaker == "1")
        #expect(rig.finals[1].speaker == "2.1")
        let resumed = try #require(rig.finals[1].range)
        // The stream starts where the last final word ended (0.8 s); its word is 0.3 s into it.
        #expect(abs(resumed.lowerBound - 1.1) < 0.1 + 1e-6, "stream times are meeting times: \(resumed)")
        rig.endInput()
        await eventually("the session ends") { rig.isEnded }
        #expect(rig.failure == nil)
    }

    @Test func wordsNotFinalWhenAStreamDropsAreHeardAgainOnTheNextOne() async throws {
        let rig = try MeetingEngineRig()
        defer { rig.cleanup() }
        rig.start()
        rig.hear(3)
        await eventually("the first stream") { await rig.sockets.at(0)?.configuration != nil }
        let first = try #require(rig.sockets.at(0))
        await eventually("the audio is sent") { await first.audio.reduce(0) { $0 + $1.count } >= 96_000 }

        await first.fail()
        await eventually("a second stream") { await rig.sockets.at(1)?.configuration != nil }
        let second = try #require(rig.sockets.at(1))
        await eventually("all of it is sent again") { await second.audio.reduce(0) { $0 + $1.count } >= 96_000 }
        await second.feed(tokens([("Kept.", 500, 900, "1")]))
        await eventually("its segment") { rig.finals.count == 1 }
        let kept = try #require(rig.finals[0].range)
        #expect(abs(kept.lowerBound - 0.5) < 1e-6, "the replay keeps meeting times: \(kept)")
        rig.endInput()
        await eventually("the session ends") { rig.isEnded }
        #expect(rig.gaps.isEmpty)
    }

    @Test func audioTheBacklogCannotHoldIsReportedAsAGap() async throws {
        // No stream comes up while three seconds of audio are heard: the one second held cannot keep the start.
        var timing = SonioxMeetingEngine.Timing.tests
        timing.backlog = 1
        let gate = ConnectGate()
        let rig = try MeetingEngineRig(gate: gate, timing: timing)
        defer { rig.cleanup() }
        rig.start(countingPulls: true)
        rig.hear(3)
        await eventually("all the audio is handled") { rig.pulls == 31 }
        gate.open()
        await eventually("a stream connects") { await rig.sockets.at(0)?.configuration != nil }
        await eventually("the gap is reported") { rig.gaps.count == 1 }
        let gap = try #require(rig.gaps.first?.range)
        #expect(gap.lowerBound == 0 && gap.upperBound >= 1.5, "the start of the meeting was never transcribed: \(gap)")
        #expect(rig.gaps[0].text.isEmpty && rig.gaps[0].isFinal)
        let held = try #require(rig.sockets.at(0))
        await eventually("the newest audio is sent") { await held.audio.reduce(0) { $0 + $1.count } >= 32_000 }
        rig.endInput()
        await eventually("the session ends") { rig.isEnded }
    }

    @Test func aStreamThatIsDownAtTheEndLeavesAGapToTheEnd() async throws {
        let rig = try MeetingEngineRig(refusingFirst: 1_000)
        defer { rig.cleanup() }
        rig.start()
        rig.hear(3)
        try await Task.sleep(for: .milliseconds(50))
        rig.endInput()
        await eventually("the session ends") { rig.isEnded }
        let gap = try #require(rig.gaps.first?.range)
        #expect(gap.lowerBound == 0 && abs(gap.upperBound - 3) < 1e-6)
        #expect(rig.failure == nil)
    }

    @Test func aLongMeetingRollsOverToANewStreamWithoutAGap() async throws {
        var timing = SonioxMeetingEngine.Timing.tests
        timing.rolloverAfter = 2
        let rig = try MeetingEngineRig(timing: timing)
        defer { rig.cleanup() }
        rig.start()
        rig.hear(1)
        await eventually("the first stream") { await rig.sockets.at(0)?.configuration != nil }
        // Audio keeps coming, as in a meeting: the rollover is decided as it is sent.
        await eventually("the next stream connects") {
            rig.hear(0.1)
            return await rig.sockets.at(1)?.configuration != nil
        }
        let first = try #require(rig.sockets.at(0)), second = try #require(rig.sockets.at(1))
        await eventually("the old stream finishes its words") { await first.finalizes == 1 }
        rig.hear(0.5)
        await eventually("the new stream gets the audio") { await second.audio.reduce(0) { $0 + $1.count } > 0 }
        rig.endInput()
        await eventually("the session ends") { rig.isEnded }
        #expect(rig.gaps.isEmpty)
        #expect(await second.finalizes == 1)
    }

    @Test func aRefusedKeyEndsTheStreamWithThatError() async throws {
        let rig = try MeetingEngineRig()
        defer { rig.cleanup() }
        rig.start()
        rig.hear(0.5)
        await eventually("the stream starts") { await rig.sockets.at(0)?.configuration != nil }
        await rig.sockets.at(0)?.fail(.provider(401))
        await eventually("the engine reports it") { (rig.failure as? SonioxError) == .provider(401) }
        rig.hear(0.5)  // the session keeps recording and keeps feeding; nothing is sent on, nothing crashes
        try await Task.sleep(for: .milliseconds(30))
        #expect(rig.sockets.count == 1, "a refused key is not retried")
        rig.endInput()
    }
}
