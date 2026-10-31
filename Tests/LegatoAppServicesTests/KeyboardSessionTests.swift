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
        try await until { await sockets.last?.configured == true }
        return (composer, keyboard)
    }

    @Test func appearancePrewarmsAndIdleAudioIsDiscarded() async throws {
        let (composer, keyboard) = try await openOnTyping()
        #expect(keyboard.isOpen && composer.holdsWarmInput && composer.route == .idle)
        #expect(await mic.routes == 1, "The held input routes the leased microphone; it never starts one")
        await mic.emit()
        try await Task.sleep(for: .milliseconds(20))
        #expect(await sockets.last?.audioFrames == 0, "The idle gate discards audio; the stream only sees keepalives")
        #expect(sockets.count == 1)
    }

    @Test func dictationLinesReachTheSinkNeverTheComposer() async throws {
        let (composer, keyboard) = try await openOnTyping()
        let socket = try #require(sockets.last)
        #expect(await keyboard.openGate(tapAt: Date()))
        #expect(composer.route == .dictation)
        await mic.emit()
        try await until { await socket.audioFrames > 0 }
        await socket.feed(#"{"tokens":[{"text":"Hallo","is_final":false}]}"#)
        try await until { keyboard.dictationTail == "Hallo" }
        #expect(keyboard.probes.count == 1 && keyboard.probes.first?.route == .dictation && keyboard.probes.first?.warm == true)
        await socket.feed(#"{"tokens":[{"text":"Hallo","is_final":true},{"text":" Welt.","is_final":true}]}"#)
        try await until { sink.lines.count == 1 }
        #expect(sink.lines.first?.text == "Hallo Welt.")
        #expect(composer.snapshot.lines.isEmpty && composer.tail.isEmpty, "Dictation audio never reaches the composition")
        await keyboard.closeGate()
        #expect(composer.route == .idle)
        #expect(await socket.sent.contains(.text(#"{"type":"finalize"}"#)), "Tap again finalizes")
        #expect(await socket.closed == false, "The dictation stream stays open for the next tap")
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

    @Test func idleDropReconnectsSilently() async throws {
        let (composer, keyboard) = try await openOnTyping()
        await sockets.last?.drop()
        try await until { sockets.count == 2 }
        try await until { await sockets.last?.configured == true }
        #expect(composer.error == nil && keyboard.isOpen)
        #expect(await keyboard.openGate())
        await mic.emit()
        try await until { await sockets.last?.audioFrames ?? 0 > 0 }
    }
}

@MainActor private func until(_ condition: @MainActor () async -> Bool) async throws {
    for _ in 0..<500 { if await condition() { return }; try await Task.sleep(for: .milliseconds(2)) }
    Issue.record("Timed out waiting for condition")
    throw CancellationError()
}

@MainActor final class RecordingSink: DictationRouteSink {
    var lines: [DictationRouteLine] = []
    var resets = 0
    func receive(_ line: DictationRouteLine) async { lines.append(line) }
    func reset() async { resets += 1 }
}

actor GateMicrophone: AudioSource {
    var routes = 0
    private var continuation: AsyncStream<AudioChunk>.Continuation?
    func start(format: AudioFormatSpec) async throws -> AsyncStream<AudioChunk> { AsyncStream { $0.finish() } }
    func route() async throws -> AsyncStream<AudioChunk> {
        routes += 1; continuation?.finish()
        let pair = AsyncStream<AudioChunk>.makeStream(); continuation = pair.continuation
        return pair.stream
    }
    func emit() { continuation?.yield(AudioChunk(samples: Array(repeating: 0.1, count: 320), format: .init(sampleRate: 16000, channelCount: 1))) }
    func detach() async { continuation?.finish(); continuation = nil }
    func stop() async { continuation?.finish(); continuation = nil }
}

final class SocketBox: Sendable {
    private let sockets = Mutex<[TestSocket]>([])
    func make() -> TestSocket { let socket = TestSocket(); sockets.withLock { $0.append(socket) }; return socket }
    var last: TestSocket? { sockets.withLock { $0.last } }
    var count: Int { sockets.withLock { $0.count } }
}

actor TestSocket: SonioxSocket {
    var sent: [SonioxFrame] = []
    var closed = false
    private var dropped = false
    private var inbox: [SonioxFrame] = []
    private var waiter: CheckedContinuation<SonioxFrame, any Error>?
    var configured: Bool { sent.contains { if case .text(let text) = $0 { text.contains("stt-rt") } else { false } } }
    var audioFrames: Int { sent.filter { if case .binary = $0 { true } else { false } }.count }
    func connect(request: URLRequest) async throws {}
    func send(_ frame: SonioxFrame) async throws { guard !closed else { throw SonioxError.network }; sent.append(frame) }
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
