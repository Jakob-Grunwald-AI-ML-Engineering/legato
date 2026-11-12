import Foundation
import Synchronization
import Testing
import LegatoCore
import LegatoSoniox
@testable import LegatoAppServices

@Test func gateOpensOnlyTheSurfaceRouteAndSurfaceSwitchAbandons() {
    var gate = AudioGate(surface: .dictation)
    #expect(gate.tap() == .open(.dictation))
    #expect(gate.route == .dictation)
    #expect(gate.show(.agent) == .abandon(.dictation), "Leaving a surface drops its half-spoken words")
    #expect(gate.route == .idle)
    #expect(gate.tap() == .open(.agent), "Later taps follow the new surface")
    #expect(gate.tap() == .finalize(.agent))
    #expect(gate.show(.agent) == nil)
    #expect(gate.show(.dictation) == nil, "Switching while idle has nothing to abandon")
    #expect(gate.abandon() == nil)
    #expect(AudioGate(surface: .idle).surface == .agent)
}

@Test func probeMeasuresTapToFirstTailOncePerTap() {
    var probe = TapLatencyProbe()
    probe.tapped(route: .agent, at: 10, warm: true, idleS: 120)
    #expect(probe.tail("early", route: .agent, at: 10.01) == nil, "A tail before the gate opened is not this take's")
    probe.gateOpened(at: 10.04)
    probe.audioRouted(at: 10.05)
    #expect(probe.tail("  ", route: .agent, at: 10.1) == nil)
    #expect(probe.tail("hi", route: .dictation, at: 10.1) == nil)
    let result = probe.tail("hallo", route: .agent, at: 10.25)
    #expect(result == .init(route: .agent, warm: true, idleS: 120, tapToGateMs: 40, tapToAudioMs: 50, tapToTailMs: 250))
    #expect(probe.tail("hallo welt", route: .agent, at: 10.3) == nil)
}

@MainActor @Suite(.timeLimit(.minutes(1))) struct KeyboardSessionDictationTests {
    let mic = GateMicrophone()
    let sockets = SocketBox()
    let sink = RecordingSink()

    private func openOnTyping() async throws -> (ComposerSession, KeyboardSession) {
        let composer = ComposerSession(microphone: mic, activateAudioSession: {})
        await composer.arm()
        let sockets = self.sockets
        let keyboard = KeyboardSession(composer: composer, sink: sink, sonioxKey: { "test" },
                                       makeSocket: { sockets.make() }, warmConnection: {})
        keyboard.update(visible: true, surface: .dictation)
        await keyboard.settle()
        try await until { await sockets.last?.held == true }
        // The keepalive goes out while connecting; the route is warm once the held connection fills its slot.
        try await until { keyboard.diagnostics["dictationStreamLive"] as? Bool == true }
        return (composer, keyboard)
    }

    @Test func meetingSuspensionKeepsDraftAndRejectsAllMicrophoneAdmission() async throws {
        let composer = ComposerSession(microphone: mic, activateAudioSession: {})
        try await composer.seedDebugDraft("Keep this draft for after the meeting.")
        let draft = composer.snapshot
        await composer.arm()
        let sockets = self.sockets
        let keyboard = KeyboardSession(composer: composer, sink: sink, sonioxKey: { "test" },
            makeSocket: { sockets.make() }, warmConnection: {})
        keyboard.update(visible: true, surface: .dictation)
        await keyboard.settle()
        await keyboard.suspendForMeeting()
        let starts = await mic.starts
        let routes = await mic.routes
        keyboard.update(visible: true, surface: .agent)
        await keyboard.settle()
        #expect(!(await keyboard.openGate()))
        await composer.arm()
        await composer.start()
        let afterStarts = await mic.starts
        let afterRoutes = await mic.routes
        #expect(afterStarts == starts && afterRoutes == routes)
        #expect(!composer.isArmed && !composer.holdsWarmInput && !keyboard.isOpen)
        #expect(composer.snapshot == draft, "A meeting must never cancel the existing composition")
        keyboard.finishMeeting()
        #expect(!composer.isArmed, "Finishing a meeting never implicitly rearms the mic")
        #expect(composer.snapshot == draft)
    }

    @Test func meetingReservationWinsAgainstAnArmingPermissionAwait() async throws {
        let permission = ConnectGate()
        var entered = false
        let composer = ComposerSession(microphone: mic, activateAudioSession: { entered = true; await permission.wait() })
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
        keyboard.update(visible: true, surface: .agent); await keyboard.settle()
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

    @Test func aTapWithoutSonioxKeyStaysClosedAndSaysWhy() async throws {
        let composer = ComposerSession(microphone: mic, activateAudioSession: {})
        await composer.arm()
        let sockets = self.sockets
        let keyboard = KeyboardSession(composer: composer, sink: sink, sonioxKey: { "" },
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
        #expect(composer.snapshot.lines.isEmpty && composer.tail.isEmpty, "Dictation audio never reaches the composition")
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

    @Test func disappearingDropsHalfSpokenWordsAndResetsTheSession() async throws {
        let (composer, keyboard) = try await openOnTyping()
        let socket = try #require(sockets.last)
        #expect(await keyboard.openGate())
        await mic.emit()
        await socket.feed(#"{"tokens":[{"text":"Halb","is_final":true},{"text":" gesp","is_final":false}]}"#)
        try await until { !keyboard.dictationTail.isEmpty }
        keyboard.update(visible: false, surface: .dictation)
        await keyboard.settle()
        #expect(!keyboard.isOpen && composer.route == .idle && !composer.holdsWarmInput)
        #expect(sink.lines.isEmpty, "Unfinished words are dropped, not delivered")
        #expect(sink.resets == 1)
        #expect(await socket.closed)
        #expect(!(await socket.sent.contains(.text(#"{"type":"finalize"}"#))))
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
    func reset() async { resets += 1 }
    func warm() async { warms += 1 }
    func beginTake() { begins += 1 }
    func finishTake() async { finishes += 1 }
}

actor GateMicrophone: AudioSource {
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
    func stop() async { continuation?.finish(); continuation = nil }
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
