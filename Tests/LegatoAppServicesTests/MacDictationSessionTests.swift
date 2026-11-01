import Foundation
import Synchronization
import Testing
import LegatoAgent
import LegatoCore
import LegatoSoniox
@testable import LegatoAppServices

final class Cleaner: SentenceCleaning {
    let inputs = Mutex<[SentenceCleanupInput]>([])
    let slow: Set<String>
    init(slow: Set<String> = []) { self.slow = slow }
    func clean(_ input: SentenceCleanupInput) async throws -> ValidatedSentence {
        inputs.withLock { $0.append(input) }
        if slow.contains(input.text) { try await Task.sleep(for: .seconds(10)) }
        return .init(sentenceID: input.sentenceID, sequence: input.sequence, text: input.text.prefix(1).uppercased() + input.text.dropFirst() + ".")
    }
}

/// A microphone that hands out one stream per `start`.
actor MacMic: AudioSource {
    var starts = 0, stops = 0
    private var continuation: AsyncStream<AudioChunk>.Continuation?
    func start(format: AudioFormatSpec) async throws -> AsyncStream<AudioChunk> {
        starts += 1
        let pair = AsyncStream<AudioChunk>.makeStream(); continuation = pair.continuation
        return pair.stream
    }
    func route() async throws -> AsyncStream<AudioChunk> { try await start(format: .init(sampleRate: 16000, channelCount: 1)) }
    func emit() { continuation?.yield(AudioChunk(samples: Array(repeating: 0.1, count: 320), format: .init(sampleRate: 16000, channelCount: 1))) }
    func detach() async { continuation?.finish() }
    func stop() async { stops += 1; continuation?.finish(); continuation = nil }
}

@MainActor final class Typed {
    var lines: [String] = []
    func record(_ text: String) async { lines.append(text) }
}

@MainActor private func until(_ condition: @MainActor () async -> Bool) async throws {
    for _ in 0..<1000 { if await condition() { return }; try await Task.sleep(for: .milliseconds(2)) }
    Issue.record("Timed out waiting for condition")
    throw CancellationError()
}

@MainActor @Suite(.timeLimit(.minutes(1))) struct MacDictationSessionTests {
    let mic = MacMic()
    let sockets = SocketBox()
    let typed = Typed()

    private func make(key: String = "test", cleaner: Cleaner = Cleaner(), timeout: Duration = .milliseconds(2500),
                      context: @escaping @MainActor () -> String = { "" }) -> MacDictationSession {
        let pipeline = DictationPipeline(cleaner: cleaner, timeout: timeout)
        pipeline.contextBefore = context
        let sockets = self.sockets
        let session = MacDictationSession(pipeline: pipeline, microphone: mic, vocabularyURL: URL(fileURLWithPath: "/nonexistent/vocabulary.json"),
                                          sonioxKey: { key }, claudeKey: { true }, makeSocket: { sockets.make() }, warmConnection: {})
        let typed = self.typed
        session.deliver = { await typed.record($0) }
        return session
    }

    @Test func idleHoldsAnUnbilledConnectionAndTheStartRequestGoesOutOnTheHotkey() async throws {
        let session = make()
        session.ensureWarm()
        try await until { await sockets.last?.held == true }
        #expect(await sockets.last?.configured == false, "Held, not billed")
        #expect(await mic.starts == 0, "No microphone while idle")
        #expect(await session.start())
        #expect(session.phase == .listening)
        #expect(await sockets.at(0)?.configured == true, "The held stream takes the start request")
        try await until { sockets.count == 2 } // the next connection is held right away
        await session.cancel()
    }

    @Test func spokenLinesAreCleanedAndDeliveredInOrderThenStopFinalizes() async throws {
        let session = make()
        session.ensureWarm()
        try await until { await sockets.last?.held == true }
        let socket = try #require(sockets.last)
        #expect(await session.start())
        await mic.emit()
        try await until { await socket.audioFrames > 0 }
        await socket.feed(#"{"tokens":[{"text":"hallo","is_final":false}]}"#)
        try await until { session.tail == "hallo" }
        await socket.feed(#"{"tokens":[{"text":"hallo","is_final":true},{"text":" welt","is_final":true},{"text":"<end>","is_final":true}]}"#)
        await socket.feed(#"{"tokens":[{"text":"zweite","is_final":true},{"text":" zeile","is_final":true},{"text":"<end>","is_final":true}]}"#)
        try await until { typed.lines.count == 2 }
        #expect(typed.lines == ["Hallo welt.", "Zweite zeile."])
        let stopping = Task { await session.stop() }
        try await until { await socket.sent.contains(.text(#"{"type":"finalize"}"#)) }
        #expect(await mic.stops == 1)
        await socket.feed(#"{"tokens":[{"text":"<fin>","is_final":true}]}"#)
        await socket.feed(#"{"finished":true}"#)
        await stopping.value
        #expect(session.phase == .idle)
    }

    @Test func aSlowCleanupInsertsTheRawLineInOrder() async throws {
        let session = make(cleaner: Cleaner(slow: ["uh erste"]), timeout: .milliseconds(40))
        try await session.debugLine("uh erste")
        try await session.debugLine("zweite")
        try await until { typed.lines.count == 2 }
        #expect(typed.lines == ["uh erste", "Zweite."], "Timeout: the raw line, still before the later one")
        #expect(session.pipeline.fallbacks == ["timeout"])
        await session.debugStop()
        #expect(session.phase == .idle)
    }

    @Test func cleanupContextIsPreviousLinesPlusTheFieldAndResetsPerSession() async throws {
        let cleaner = Cleaner()
        var field = "Hi Anna,"
        let session = make(cleaner: cleaner, context: { field })
        try await session.debugLine("eins")
        try await until { typed.lines.count == 1 }
        try await session.debugLine("zwei")
        try await until { typed.lines.count == 2 }
        let second = cleaner.inputs.withLock { $0 }.first { $0.text == "zwei" }
        #expect(second?.dictation?.previousLines == ["Eins."] && second?.dictation?.textBeforeCursor == "Hi Anna,")
        await session.debugStop()

        field = ""
        try await session.debugLine("drei")
        try await until { typed.lines.count == 3 }
        let third = cleaner.inputs.withLock { $0 }.first { $0.text == "drei" }
        #expect(third?.dictation?.previousLines == [] && third?.dictation?.textBeforeCursor == "", "A new session starts without context")
        await session.debugStop()
    }

    @Test func aSessionNeverReachesTheComposer() async throws {
        let composer = ComposerSession(microphone: mic, activateAudioSession: {})
        let session = make()
        session.ensureWarm()
        try await until { await sockets.last?.held == true }
        #expect(await session.start())
        await mic.emit()
        await sockets.at(0)?.feed(#"{"tokens":[{"text":"nur","is_final":true},{"text":" diktat","is_final":true},{"text":"<end>","is_final":true}]}"#)
        try await until { typed.lines.count == 1 }
        #expect(composer.snapshot.lines.isEmpty && composer.tail.isEmpty && composer.status == "idle", "Separate route and Room")
        #expect(!composer.isListening)
        await session.cancel()
    }

    @Test func aMissingSonioxKeyStaysIdleAndSaysWhy() async throws {
        let session = make(key: "")
        let before = session.noticeID
        #expect(await session.start() == false)
        #expect(session.phase == .idle && session.notice?.contains("Soniox key") == true && session.noticeID == before + 1)
        #expect(await mic.starts == 0 && sockets.count == 0)
    }

    @Test func cancelDropsHalfSpokenWordsAndWarmsAgain() async throws {
        let session = make()
        session.ensureWarm()
        try await until { await sockets.last?.held == true }
        let active = try #require(sockets.last)
        #expect(await session.start())
        await mic.emit()
        await active.feed(#"{"tokens":[{"text":"halb","is_final":true},{"text":" gesp","is_final":false}]}"#)
        try await until { !session.tail.isEmpty }
        await session.cancel()
        #expect(session.phase == .idle && typed.lines.isEmpty)
        let finalized = await active.sent.contains(.text(#"{"type":"finalize"}"#))
        #expect(await active.closed && !finalized)
        try await until { await sockets.last?.held == true && sockets.last !== active }
    }
}
