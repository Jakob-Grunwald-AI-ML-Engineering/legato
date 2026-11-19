import Foundation
import Synchronization
import Testing
import LegatoAgent
import LegatoCore
import LegatoKeyboardCore
import LegatoSoniox
@testable import LegatoAppServices

@Test func gateOpensDictationAndAbandonsWhenKeyboardCloses() {
    var gate = AudioGate()
    #expect(gate.tap() == .open(.dictation))
    #expect(gate.tap() == .finalize(.dictation))
    #expect(gate.tap() == .open(.dictation))
    #expect(gate.abandon() == .abandon(.dictation))
    #expect(gate.route == .idle)
    #expect(gate.abandon() == nil)
}

@Test func probeMeasuresTapToFirstTailOncePerTap() {
    var probe = TapLatencyProbe()
    probe.tapped(route: .dictation, at: 10, warm: true, idleS: 120)
    #expect(probe.tail("early", route: .dictation, at: 10.01) == nil, "A tail before the gate opened is not this take's")
    probe.gateOpened(at: 10.04)
    probe.audioRouted(at: 10.05)
    #expect(probe.tail("  ", route: .dictation, at: 10.1) == nil)
    #expect(probe.tail("hi", route: .idle, at: 10.1) == nil)
    let result = probe.tail("hallo", route: .dictation, at: 10.25)
    #expect(result == .init(route: .dictation, warm: true, idleS: 120, tapToGateMs: 40, tapToAudioMs: 50, tapToTailMs: 250))
    #expect(probe.tail("hallo welt", route: .dictation, at: 10.3) == nil)
}

@MainActor @Suite(.timeLimit(.minutes(1))) struct KeyboardSessionDictationTests {
    let mic = GateMicrophone()
    let sockets = SocketBox()
    let sink = RecordingSink()

    private func openOnTyping() async throws -> (MicrophoneHost, KeyboardSession) {
        let composer = MicrophoneHost(microphone: mic, activateAudioSession: {})
        await composer.arm()
        let sockets = self.sockets
        let keyboard = KeyboardSession(microphone: composer, sink: sink, sonioxKey: { "test" },
                                       makeSocket: { sockets.make() }, warmConnection: {})
        keyboard.update(visible: true, surface: .dictation)
        await keyboard.settle()
        try await until { await sockets.last?.held == true }
        // The keepalive goes out while connecting; the route is warm once the held connection fills its slot.
        try await until { keyboard.diagnostics["dictationStreamLive"] as? Bool == true }
        return (composer, keyboard)
    }

    @Test func meetingSuspensionRejectsAllMicrophoneAdmission() async throws {
        let composer = MicrophoneHost(microphone: mic, activateAudioSession: {})
        await composer.arm()
        let sockets = self.sockets
        let keyboard = KeyboardSession(microphone: composer, sink: sink, sonioxKey: { "test" },
            makeSocket: { sockets.make() }, warmConnection: {})
        keyboard.update(visible: true, surface: .dictation)
        await keyboard.settle()
        await keyboard.suspendForMeeting()
        let starts = await mic.starts
        let routes = await mic.routes
        keyboard.update(visible: true, surface: .dictation)
        await keyboard.settle()
        #expect(!(await keyboard.openGate()))
        await composer.arm()
        let afterStarts = await mic.starts
        let afterRoutes = await mic.routes
        #expect(afterStarts == starts && afterRoutes == routes)
        #expect(!composer.isArmed && !composer.holdsWarmInput && !keyboard.isOpen)
        keyboard.finishMeeting()
        #expect(!composer.isArmed, "Finishing a meeting never implicitly rearms the mic")
    }

    @Test func meetingReservationWinsAgainstAnArmingPermissionAwait() async throws {
        let permission = ConnectGate()
        var entered = false
        let composer = MicrophoneHost(microphone: mic, activateAudioSession: { entered = true; await permission.wait() })
        let arming = Task { await composer.arm() }
        try await until { entered }
        await composer.suspendMicrophoneForMeeting()
        permission.open()
        await arming.value
        #expect(!composer.isArmed)
        #expect(await mic.starts == 0, "Permission returning cannot start a mic after a meeting reserved it")
    }

    @Test func debugDictationLineEntersTheSinkOnTheTypingSurface() async throws {
        let (_, keyboard) = try await openOnTyping()
        try await keyboard.debugDictationLine("Hallo Welt")
        #expect(sink.lines.map(\.text) == ["Hallo Welt"])
        try keyboard.debugDictationTail("und dann")
        #expect(keyboard.dictationTail == "und dann")
        keyboard.update(visible: false, surface: .dictation); await keyboard.settle()
        await #expect(throws: KeyboardSession.DebugDictationError.self) { try await keyboard.debugDictationLine("x") }
    }

    /// The bridge's lines stand in for real takes: the first line after a stop begins a take, as the mic key would.
    @Test func theDebugBridgeBeginsATakeAfterEveryStopLikeTheMicKey() async throws {
        let (_, keyboard) = try await openOnTyping()
        try await keyboard.debugDictationLine("one")
        try keyboard.debugDictationTail("tw")
        try await keyboard.debugDictationLine("two")
        #expect(sink.begins == 1)
        try keyboard.debugDictationStop()
        try await until { sink.finishes == 1 }
        try keyboard.debugDictationTail("thr")
        try await keyboard.debugDictationLine("three")
        #expect(sink.begins == 2)
        #expect(await keyboard.openGate())
        #expect(sink.begins == 3, "The mic key begins a take")
    }

    /// Device run 4: a replay began while a bridge line's take was still open (no `dictation-debug-stop`). Its speech
    /// waited behind that take's run until its own stop, which ended the line's run instead. A take the mic key or a
    /// replay begins ends the bridge's open take first, as its stop would.
    @Test func aTakeBeganWhileABridgeLinesTakeIsOpenEndsThatTakeFirst() async throws {
        let (_, keyboard) = try await openOnTyping()
        try await keyboard.debugDictationLine("and the ink cartridges")
        #expect(sink.begins == 1 && sink.finishes == 0)
        #expect(await keyboard.openGate())
        #expect(sink.begins == 2)
        try await until { sink.finishes == 1 }
    }

    /// A stop never cancels the end of the take before it (still waiting for its last words): every take is ended.
    @Test func aStopNeverCancelsTheEndOfTheTakeBeforeIt() async throws {
        let (_, keyboard) = try await openOnTyping()
        let first = try #require(sockets.last)
        #expect(await keyboard.openGate())
        await mic.emit()
        await keyboard.closeGate()
        try await until { await first.sent.contains(.text(#"{"type":"finalize"}"#)) }
        // The first take still waits for its last words when the second take starts and stops.
        try await until { sockets.count == 2 }
        try await until { await sockets.last?.held == true }
        let second = try #require(sockets.last)
        #expect(await keyboard.openGate())
        await mic.emit()
        await keyboard.closeGate()
        try await until { await second.sent.contains(.text(#"{"type":"finalize"}"#)) }
        for socket in [first, second] {
            await socket.feed(#"{"tokens":[{"text":"<fin>","is_final":true}]}"#)
            await socket.feed(#"{"finished":true}"#)
        }
        try await until { sink.finishes == 2 }
        #expect(sink.begins == 2)
    }

    /// Manual send (#313): the mic key's Stop is a pause for the sink, and only the keyboard going away ends the take.
    @Test func stopPausesTheTakeAndOnlyHidingTheKeyboardEndsIt() async throws {
        sink.keepsPausedTake = true
        let (_, keyboard) = try await openOnTyping()
        let socket = try #require(sockets.last)
        #expect(await keyboard.openGate())
        await mic.emit()
        await keyboard.closeGate()
        try await until { await socket.sent.contains(.text(#"{"type":"finalize"}"#)) }
        await socket.feed(#"{"tokens":[{"text":"<fin>","is_final":true}]}"#)
        await socket.feed(#"{"finished":true}"#)
        try await until { sink.pauses == 1 }
        #expect(sink.finishes == 0, "A paused take stays open")
        keyboard.update(visible: false, surface: .dictation)
        await keyboard.settle()
        try await until { sink.finishes == 1 }
    }

    @Test func aTapWithoutSonioxKeyStaysClosedAndSaysWhy() async throws {
        let composer = MicrophoneHost(microphone: mic, activateAudioSession: {})
        await composer.arm()
        let sockets = self.sockets
        let keyboard = KeyboardSession(microphone: composer, sink: sink, sonioxKey: { "" },
                                       makeSocket: { sockets.make() }, warmConnection: {})
        keyboard.update(visible: true, surface: .dictation)
        await keyboard.settle()
        let before = keyboard.dictationNoticeID
        _ = await keyboard.openGate(tapAt: Date())
        #expect(keyboard.route == .idle && composer.route == .idle, "No stream: the gate must not claim to listen")
        #expect(keyboard.dictationNotice?.contains("Soniox key") == true)
        #expect(keyboard.dictationNoticeID == before + 1)
    }

    @Test func appearancePrewarmsAndIdleAudioIsDiscarded() async throws {
        let (composer, keyboard) = try await openOnTyping()
        try await until { sink.warms == 1 } // the cleanup connection and prompt cache are warmed on the dictation surface
        #expect(keyboard.isOpen && composer.holdsWarmInput && composer.route == .idle)
        #expect(await mic.routes == 1, "The held input routes the leased microphone; it never starts one")
        await mic.emit()
        try await Task.sleep(for: .milliseconds(20))
        #expect(await sockets.last?.audioFrames == 0, "The idle gate discards audio; the stream only sees keepalives")
        #expect(await sockets.last?.configured == false, "Idle keyboards hold the connection without a billed stream")
        #expect(sockets.count == 1)
    }

    @Test func dictationLinesReachTheSinkNeverTheComposer() async throws {
        let (composer, keyboard) = try await openOnTyping()
        let socket = try #require(sockets.last)
        #expect(await keyboard.openGate(tapAt: Date()))
        #expect(composer.route == .dictation)
        #expect(await socket.configured, "The start request goes out on tap")
        await mic.emit()
        try await until { await socket.audioFrames > 0 }
        #expect(await socket.configuredBeforeAudio)
        await socket.feed(#"{"tokens":[{"text":"Hallo","is_final":false}]}"#)
        try await until { keyboard.dictationTail == "Hallo" }
        #expect(keyboard.probes.count == 1 && keyboard.probes.first?.route == .dictation && keyboard.probes.first?.warm == true)
        await socket.feed(#"{"tokens":[{"text":"Hallo","is_final":true},{"text":" Welt.","is_final":true}]}"#)
        try await until { sink.lines.count == 1 }
        #expect(sink.lines.first?.text == "Hallo Welt.")
        await keyboard.closeGate()
        #expect(composer.route == .idle)
        try await until { await socket.sent.contains(.text(#"{"type":"finalize"}"#)) }
        await socket.feed(#"{"tokens":[{"text":"<fin>","is_final":true}]}"#)
        try await until { await socket.sent.contains(.text("")) }
        await socket.feed(#"{"finished":true}"#)
        try await until { await socket.closed }
        #expect(sockets.count == 2, "A held, unbilled connection waits for the next tap")
        try await until { await sockets.last?.held == true }
        #expect(await sockets.last?.configured == false)
        #expect(composer.holdsWarmInput, "The microphone keeps running between taps")
    }

    /// Contract change (issue #312, undelivered speech stays recoverable): hiding mid-take used to drop the half-spoken
    /// words; it now finalizes them like Stop, then closes the route and resets the session.
    @Test func disappearingFinalizesHalfSpokenWordsLikeStopThenResetsTheSession() async throws {
        let (composer, keyboard) = try await openOnTyping()
        let socket = try #require(sockets.last)
        #expect(await keyboard.openGate())
        await mic.emit()
        await socket.feed(#"{"tokens":[{"text":"Halb","is_final":true},{"text":" gesp","is_final":false}]}"#)
        try await until { !keyboard.dictationTail.isEmpty }
        keyboard.update(visible: false, surface: .dictation)
        try await until { await socket.sent.contains(.text(#"{"type":"finalize"}"#)) }
        await socket.feed(#"{"tokens":[{"text":" gesp","is_final":true},{"text":"rochen","is_final":true},{"text":"<fin>","is_final":true}]}"#)
        try await until { await socket.sent.contains(.text("")) }
        await socket.feed(#"{"finished":true}"#)
        await keyboard.settle()
        #expect(!keyboard.isOpen && composer.route == .idle && !composer.holdsWarmInput)
        #expect(sink.lines.map(\.text).joined().contains("gesp"), "The half-spoken words are finalized and delivered")
        try await until { sink.finishes == 1 }
        #expect(sink.resets == 1)
        #expect(await socket.closed)
    }

    @Test func disappearingMidTakeStillEndsTheTakeSoItsFinalWordsAreRecorded() async throws {
        let (_, keyboard) = try await openOnTyping()
        let socket = try #require(sockets.last)
        #expect(await keyboard.openGate())
        await mic.emit()
        await socket.feed(#"{"tokens":[{"text":"Erster Satz.","is_final":true},{"text":" gesp","is_final":false}]}"#)
        try await until { !sink.lines.isEmpty }
        #expect(sink.finishes == 0)
        keyboard.update(visible: false, surface: .dictation)
        await keyboard.settle()
        try await until { sink.finishes == 1 }
        #expect(sink.lines.map(\.text) == ["Erster Satz."], "Only the half-spoken words are dropped")
    }

    @Test func closingAndReopeningKeyboardReusesTheHeldMicrophone() async throws {
        let (composer, keyboard) = try await openOnTyping()
        keyboard.update(visible: false, surface: .dictation)
        await keyboard.settle()
        #expect(composer.isArmed)
        keyboard.update(visible: true, surface: .dictation)
        await keyboard.settle()
        #expect(composer.holdsWarmInput)
        // Tapped while the reopened keyboard's connection is still being held: the take waits for it.
        #expect(await keyboard.openGate())
        #expect(keyboard.dictationNotice == nil)
        let socket = try #require(sockets.at(1))
        #expect(await socket.configured, "The take starts on the reopened keyboard's held connection")
        await mic.emit()
        try await until { await socket.audioFrames > 0 }
        keyboard.update(visible: false, surface: .dictation); await keyboard.settle()
        await composer.releaseMicrophone()
    }

    @Test func speechDuringTakeConnectionIsBufferedButIdleSpeechIsDiscarded() async throws {
        let (composer, keyboard) = try await openOnTyping()
        let socket = try #require(sockets.last)
        let idleChunks = composer.consumedWarmInputChunks
        await mic.emit(sample: 0.9)
        try await until { composer.consumedWarmInputChunks > idleChunks }
        await socket.holdConfiguration()
        let opening = Task { await keyboard.openGate() }
        try await until { await socket.configurationBlocked }
        await mic.emit(sample: 0.25)
        // Wait until the consumer has accepted the post-tap chunk, independent of the held network send.
        try await until { composer.bufferedTakeFrames == 320 }
        await socket.releaseConfiguration()
        #expect(await opening.value)
        await mic.emit(sample: 0.5)
        try await until { await socket.audioFrames == 2 }
        let audio = await socket.sent.compactMap { frame -> Data? in if case .binary(let data) = frame { return data }; return nil }
        #expect(audio.count == 2)
        #expect(audio[0] != audio[1], "The opening chunk precedes the later speech")
        keyboard.update(visible: false, surface: .dictation); await keyboard.settle()
        await composer.releaseMicrophone()
    }

    @Test func idleDropReconnectsSilently() async throws {
        let (composer, keyboard) = try await openOnTyping()
        await sockets.last?.drop()
        try await until { sockets.count == 2 }
        try await until { await sockets.last?.held == true }
        #expect(composer.error == nil && keyboard.isOpen)
        #expect(await keyboard.openGate())
        await mic.emit()
        let active = try #require(sockets.at(1))
        try await until { await active.audioFrames > 0 }
    }
}

@MainActor private func until(_ condition: @MainActor () async -> Bool) async throws {
    // Bounded by real time (10 s), not iterations: on loaded CI runners each sleep can take far longer than asked.
    let deadline = ContinuousClock.now + .seconds(10)
    while ContinuousClock.now < deadline { if await condition() { return }; try await Task.sleep(for: .milliseconds(2)) }
    Issue.record("Timed out waiting for condition")
    throw CancellationError()
}

@MainActor final class RecordingSink: DictationRouteSink {
    var lines: [DictationRouteLine] = []
    var resets = 0
    func receive(_ line: DictationRouteLine) async { lines.append(line) }
    var warms = 0
    var begins = 0
    var finishes = 0
    var pauses = 0
    /// The sink keeps a paused take open (the iPhone's manual send): Stop does not end it.
    var keepsPausedTake = false
    func reset() async { resets += 1 }
    func warm() async { warms += 1 }
    func beginTake() { begins += 1 }
    func finishTake() async { finishes += 1 }
    func pauseTake() async { pauses += 1; if !keepsPausedTake { await finishTake() } }
}

actor GateMicrophone: AudioSource {
    var stops = 0
    var routes = 0
    var starts = 0
    private var continuation: AsyncStream<AudioChunk>.Continuation?
    func start(format: AudioFormatSpec) async throws -> AsyncStream<AudioChunk> { starts += 1; return AsyncStream { $0.finish() } }
    func route() async throws -> AsyncStream<AudioChunk> {
        routes += 1; continuation?.finish()
        let pair = AsyncStream<AudioChunk>.makeStream(); continuation = pair.continuation
        return pair.stream
    }
    func emit(sample: Float = 0.1) { continuation?.yield(AudioChunk(samples: Array(repeating: sample, count: 320), format: .init(sampleRate: 16000, channelCount: 1))) }
    func detach() async { continuation?.finish(); continuation = nil }
    func stop() async { stops += 1; continuation?.finish(); continuation = nil }
}

final class SocketBox: Sendable {
    private let sockets = Mutex<[TestSocket]>([])
    func make() -> TestSocket { let socket = TestSocket(); sockets.withLock { $0.append(socket) }; return socket }
    var last: TestSocket? { sockets.withLock { $0.last } }
    var count: Int { sockets.withLock { $0.count } }
    func at(_ index: Int) -> TestSocket? { sockets.withLock { $0.indices.contains(index) ? $0[index] : nil } }
}

actor TestSocket: SonioxSocket {
    var sent: [SonioxFrame] = []
    var closed = false
    private var dropped = false
    private var inbox: [SonioxFrame] = []
    private var waiter: CheckedContinuation<SonioxFrame, any Error>?
    var configured: Bool { sent.contains(where: Self.isConfig) }
    var held: Bool { sent.contains(.text(#"{"type":"keepalive"}"#)) }
    var configuredBeforeAudio: Bool {
        guard let config = sent.firstIndex(where: Self.isConfig) else { return false }
        return !sent[..<config].contains { if case .binary = $0 { true } else { false } }
    }
    private static func isConfig(_ frame: SonioxFrame) -> Bool { if case .text(let text) = frame { text.contains("stt-rt") } else { false } }
    var audioFrames: Int { sent.filter { if case .binary = $0 { true } else { false } }.count }
    func connect(request: URLRequest) async throws {}
    private var holdConfig = false
    private var configWaiter: CheckedContinuation<Void, Never>?
    var configurationBlocked = false
    func holdConfiguration() { holdConfig = true }
    func releaseConfiguration() { holdConfig = false; configWaiter?.resume(); configWaiter = nil }
    func send(_ frame: SonioxFrame) async throws {
        guard !closed else { throw SonioxError.network }
        if holdConfig && Self.isConfig(frame) {
            configurationBlocked = true
            await withCheckedContinuation { configWaiter = $0 }
        }
        guard !closed else { throw SonioxError.network }
        sent.append(frame)
    }
    func receive() async throws -> SonioxFrame {
        if !inbox.isEmpty { return inbox.removeFirst() }
        if dropped || closed { throw SonioxError.network }
        return try await withCheckedThrowingContinuation { waiter = $0 }
    }
    func close() async { closed = true; waiter?.resume(throwing: SonioxError.cancelled); waiter = nil }
    func feed(_ text: String) {
        if let waiter { self.waiter = nil; waiter.resume(returning: .text(text)) } else { inbox.append(.text(text)) }
    }
    func drop() { dropped = true; waiter?.resume(throwing: SonioxError.network); waiter = nil }
}

private final class LogBox: Sendable {
    private let events = Mutex<[String]>([])
    func add(_ event: String) { events.withLock { $0.append(event) } }
    func has(_ event: String) -> Bool { events.withLock { $0.contains(event) } }
}

private actor CloseHistory: HistoryStore {
    private var entries: [DictationEntry] = []
    func append(_ entry: DictationEntry) { entries.append(entry) }
    func upsert(_ entry: DictationEntry) { entries.removeAll { $0.id == entry.id }; entries.append(entry) }
    func recent(limit: Int) -> [DictationEntry] { Array(entries.suffix(limit)) }
    func delete(id: UUID) { entries.removeAll { $0.id == id } }
}

/// Uppercases the first letter; the first request can be held until the test opens the gate.
private final class HeldCleaner: SentenceCleaning {
    let gate: ConnectGate?
    private let first = Mutex(true)
    init(holdFirst: ConnectGate? = nil) { gate = holdFirst }
    func clean(_ input: SentenceCleanupInput) async throws -> ValidatedSentence {
        if first.withLock({ let was = $0; $0 = false; return was }) { await gate?.wait() }
        let text = input.dictation?.instructions == "uppercase" ? input.text.uppercased() :
            input.text.prefix(1).uppercased() + input.text.dropFirst()
        return .init(sentenceID: input.sentenceID, sequence: input.sequence, text: text)
    }
}

/// Hiding the keyboard with a take open ends it like Stop: the open unit is cleaned and the take goes to History cleaned.
@MainActor @Suite(.timeLimit(.minutes(1))) struct KeyboardHideFinishesTakeTests {
    let mic = GateMicrophone()
    let sockets = SocketBox()
    fileprivate let history = CloseHistory()
    fileprivate let logged = LogBox()

    private func session(_ cleaner: any SentenceCleaning, manual: Bool) async throws -> (DictationPipeline, KeyboardSession) {
        let pipeline = DictationPipeline(history: history, cleaner: cleaner, sendMode: { .live }, supportsLive: true,
                                         liveSend: { manual ? .manual : .sentence }, liveTimeout: .seconds(30),
                                         groupsLiveHistory: true, stagedLive: true)
        let logged = self.logged
        pipeline.diagnostics = { event, _ in logged.add(event) }
        let composer = MicrophoneHost(microphone: mic, activateAudioSession: {})
        await composer.arm()
        let sockets = self.sockets
        let keyboard = KeyboardSession(microphone: composer, sink: pipeline, sonioxKey: { "test" },
                                       makeSocket: { sockets.make() }, warmConnection: {})
        keyboard.update(visible: true, surface: .dictation)
        await keyboard.settle()
        try await until { keyboard.diagnostics["dictationStreamLive"] as? Bool == true }
        return (pipeline, keyboard)
    }

    private func cleanedHistory(_ expected: String) async throws {
        try await until {
            await self.history.recent(limit: 10).contains { $0.text == expected }
        }
    }

    @Test func previewPressOpensOnlyInstructionAudioAndRestoresThePausedDraft() async throws {
        let (pipeline, keyboard) = try await session(HeldCleaner(), manual: true)
        let draftStream = try #require(sockets.last)
        #expect(await keyboard.openGate())
        await draftStream.feed(#"{"tokens":[{"text":"meet at the ferry","is_final":true},{"text":"<end>","is_final":true}]}"#)
        try await until { pipeline.liveRun?.snapshot.text == "meet at the ferry" }
        let runID = try #require(pipeline.liveRun?.runID)
        await keyboard.closeGate()
        await draftStream.feed(#"{"tokens":[{"text":"<fin>","is_final":true}]}"#)
        await draftStream.feed(#"{"finished":true}"#)
        try await until { pipeline.isPaused && sockets.count >= 2 }

        let hold = KeyboardRequest.PreviewHold(id: "preview-press", runID: runID)
        keyboard.handlePreviewHold(.init(id: hold.id, command: .beginPreviewHold, at: Date(), previewHold: hold))
        try await until { keyboard.previewInstructionReadyID == hold.id }
        #expect(keyboard.route == .dictation && pipeline.isPaused)
        let instructionStream = try #require(sockets.at(1))
        await mic.emit()
        try await until { await instructionStream.audioFrames == 1 }
        keyboard.handlePreviewHold(.init(id: "release", command: .releasePreviewHold, at: Date(), previewHold: hold))
        await keyboard.settle()
        #expect(keyboard.route == .idle && keyboard.previewInstructionReadyID == nil)

        await instructionStream.feed(#"{"tokens":[{"text":"uppercase","is_final":true},{"text":"<fin>","is_final":true}]}"#)
        await instructionStream.feed(#"{"finished":true}"#)
        try await until { pipeline.liveRun?.snapshot.segments.first?.ready == true }
        #expect(pipeline.isPaused && pipeline.liveRun?.runID == runID)
        #expect(pipeline.liveRun?.snapshot.text == "MEET AT THE FERRY")
        #expect(pipeline.liveRun?.wholeRaw.text == "meet at the ferry")

        #expect(await keyboard.openGate())
        let resumedStream = try #require(sockets.at(2))
        await resumedStream.feed(#"{"tokens":[{"text":"bring a spare key","is_final":true},{"text":"<end>","is_final":true}]}"#)
        try await until { pipeline.liveRun?.snapshot.text == "MEET AT THE FERRY bring a spare key" }
        #expect(pipeline.liveRun?.runID == runID && !pipeline.isPaused)
    }

    @Test(arguments: [true, false]) func hidingMidTakeCleansTheOpenUnitIntoHistory(manual: Bool) async throws {
        let (_, keyboard) = try await session(HeldCleaner(), manual: manual)
        try await keyboard.debugDictationLine("we should ship it on friday")
        keyboard.update(visible: false, surface: .dictation); await keyboard.settle()
        try await cleanedHistory("We should ship it on friday")
        try await until { self.logged.has("live2.run.end") }
        #expect(!logged.has("live2.run.drop"))
    }

    @Test(arguments: [true, false]) func hidingAPausedOrListeningTakeCleansItToo(manual: Bool) async throws {
        let (pipeline, keyboard) = try await session(HeldCleaner(), manual: manual)
        try await keyboard.debugDictationLine("bring the laptop")
        try keyboard.debugDictationStop()
        await pipeline.pauseTake()
        keyboard.update(visible: false, surface: .dictation); await keyboard.settle()
        try await cleanedHistory("Bring the laptop")
        try await until { self.logged.has("live2.run.end") }
    }

    @Test(arguments: [true, false]) func reopeningAtOnceKeepsTheNewTakeApartAndTheOldOneLandsInHistory(manual: Bool) async throws {
        let held = ConnectGate()
        let (pipeline, keyboard) = try await session(HeldCleaner(holdFirst: held), manual: manual)
        try await keyboard.debugDictationLine("the old take")
        keyboard.update(visible: false, surface: .dictation); await keyboard.settle()
        // The old take's cleanup is still running while the keyboard comes back.
        keyboard.update(visible: true, surface: .dictation); await keyboard.settle()
        #expect(keyboard.isOpen)
        try await keyboard.debugDictationLine("the new take and more")
        held.open()
        try await cleanedHistory("The old take")
        keyboard.update(visible: false, surface: .dictation); await keyboard.settle()
        try await cleanedHistory("The new take and more")
        let texts = await history.recent(limit: 10).map(\.text)
        #expect(texts.contains("The old take"))
    }
}
