import Foundation
import Synchronization
import Testing
import LegatoAgent
import LegatoCore
import LegatoSoniox
@testable import LegatoAppServices

final class Cleaner: SentenceCleaning {
    let inputs = Mutex<[SentenceCleanupInput]>([])
    let takes = Mutex<[DictationTakeInput]>([])
    let slow: Set<String>
    let takeDelay: Duration
    init(slow: Set<String> = [], takeDelay: Duration = .zero) { self.slow = slow; self.takeDelay = takeDelay }
    func cleanTake(_ input: DictationTakeInput) async throws -> String {
        takes.withLock { $0.append(input) }
        try await Task.sleep(for: takeDelay)
        return input.text.prefix(1).uppercased() + input.text.dropFirst() + "."
    }
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

/// Streams "Hello" and fails on the first take; later takes stream whole.
final class FailingStreamCleaner: SentenceCleaning {
    let calls = Mutex(0)
    func clean(_ input: SentenceCleanupInput) async throws -> ValidatedSentence { throw SentenceCleanupError.invalidInput }
    func cleanTake(_ input: DictationTakeInput) async throws -> String { "" }
    func cleanTakeStream(_ input: DictationTakeInput) -> AsyncThrowingStream<String, any Error> {
        let call = calls.withLock { $0 += 1; return $0 }
        return AsyncThrowingStream { continuation in
            if call == 1 { continuation.yield("Hello "); continuation.finish(throwing: SentenceCleanupError.providerError) }
            else { continuation.yield("Hello world."); continuation.finish() }
        }
    }
}

@MainActor final class Typed {
    var lines: [String] = []
    func record(_ text: String) async { lines.append(text) }
}

@MainActor private func until(_ condition: @MainActor () async -> Bool) async throws {
    // A wall-clock deadline, not an iteration count: under the full parallel suite each sleep runs long.
    let deadline = ContinuousClock.now + .seconds(20)
    while ContinuousClock.now < deadline { if await condition() { return }; try await Task.sleep(for: .milliseconds(2)) }
    Issue.record("Timed out waiting for condition")
    throw CancellationError()
}

@MainActor @Suite(.timeLimit(.minutes(1))) struct MacDictationSessionTests {
    let mic = MacMic()
    let sockets = SocketBox()
    let typed = Typed()

    private func make(key: String = "test", cleaner: any SentenceCleaning = Cleaner(), timeout: Duration = .milliseconds(2500),
                      context: @escaping @MainActor () -> String = { "" },
                      mode: DictationSendSetting.Mode = .lineByLine, clock: any Clock<Duration> = ContinuousClock(),
                      takeTimeout: (@Sendable (Int) -> Duration)? = nil) -> MacDictationSession {
        let pipeline = DictationPipeline(cleaner: cleaner, timeout: timeout, sendMode: { mode }, pauseSeconds: { 5 }, clock: clock,
                                         takeTimeout: takeTimeout)
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

    @Test func theStartRequestCarriesTheTakesRecordedAfterTheConnectionWasWarmed() async throws {
        let session = make()
        session.ensureWarm()
        try await until { await sockets.last?.held == true }
        let socket = try #require(sockets.at(0))
        session.pipeline.recentTakes.record(raw: "lego", cleaned: "Legato läuft.", wasCleaned: true)
        #expect(await session.start())
        let sent = await socket.sent
        let config = try #require(sent.compactMap { message -> String? in
            if case .text(let text) = message, text.contains("stt-rt") { return text } else { return nil }
        }.first)
        #expect(config.contains("Legato läuft."), "Context is read when the take starts, not when the connection was warmed")
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

    @Test func inTakeModeNothingIsTypedUntilStopThenTheWholeTakeIsWrittenOnce() async throws {
        let cleaner = Cleaner(takeDelay: .milliseconds(80))
        let session = make(cleaner: cleaner, mode: .onStop)
        try await session.debugLine("hallo welt")
        try await session.debugLine("zweite zeile")
        try await session.debugTail("dritte")
        #expect(typed.lines.isEmpty && session.pipeline.takeLines.count == 2)
        #expect(session.debugState["takeLength"] as? Int == "hallo welt zweite zeile".count)
        await session.debugStop()
        #expect(session.phase == .idle)
        #expect(typed.lines == ["Hallo welt zweite zeile."], "Stop waited for the take's cleanup and wrote it once")
        #expect(cleaner.takes.withLock { $0 }.count == 1)
    }

    @Test func aFailedTakeLeavesTheSessionIdleWithNothingTypedUntilTheUserChooses() async throws {
        let session = make(mode: .onStop)
        session.pipeline.debugFailTakes = 1
        try await session.debugLine("keep me")
        await session.debugStop()
        #expect(session.phase == .idle && typed.lines.isEmpty && session.pipeline.takePhase == .failed)
        await session.pipeline.insertRaw()
        try await until { typed.lines.count == 1 }
        #expect(typed.lines == ["keep me"])
        await session.pipeline.insertRaw()
        #expect(typed.lines.count == 1)
    }

    @Test func aCancelDiscardsTheBufferedTakeAndTypesNothing() async throws {
        let cleaner = Cleaner()
        let session = make(cleaner: cleaner, mode: .onStop)
        try await session.debugLine("never typed")
        await session.cancel()
        #expect(session.phase == .idle && session.pipeline.takeLines.isEmpty && typed.lines.isEmpty)
        #expect(cleaner.takes.withLock { $0 }.isEmpty)
    }

    @Test func aHeldHotkeyNeverStartsThePauseCountdownAndReleasingDoes() async throws {
        let session = make(mode: .afterPause, clock: VirtualClock())
        session.setHeld(true)
        try await session.debugLine("push to talk")
        #expect(session.pipeline.countdownDeadline == nil)
        session.setHeld(false)
        #expect(session.pipeline.countdownDeadline != nil)
        await session.debugStop()
        #expect(typed.lines == ["Push to talk."], "Stop sends the take and the countdown is gone")
        #expect(session.pipeline.countdownDeadline == nil)
    }

    @Test func lineByLineStillTypesEachLineAsItIsCleaned() async throws {
        let session = make(mode: .lineByLine)
        try await session.debugLine("erste")
        try await session.debugLine("zweite")
        try await until { typed.lines.count == 2 }
        #expect(typed.lines == ["Erste.", "Zweite."] && session.pipeline.takeLines.isEmpty)
        await session.debugStop()
    }

    @Test func aWholeTakeStreamsAndAFailedOneStaysOpenUntilRetryRetractsIt() async throws {
        let cleaner = FailingStreamCleaner()
        // The take cleanup's own 4 s timeout is wall-clock: on a starved runner it fired before the first stream
        // answered, the cleaner moved on to the second (whole) stream, and the take never failed. Only the stream fails here.
        let session = make(cleaner: cleaner, mode: .onStop, takeTimeout: { _ in .seconds(3600) })
        var seen: [DictationStreamState] = [], retracted = 0
        session.deliverStream = { poll in
            // Follows the take like the field writer: until it is final, retracted or stalled.
            while let state = poll() {
                seen.append(state)
                if state.isFinal || state.retracted { return false }
                if state.stalled { return true }
                try? await Task.sleep(for: .milliseconds(2))
            }
            return false
        }
        session.retractStream = { retracted += 1 }
        try await session.debugLine("hello world")
        await session.debugStop()
        try await until { session.pipeline.takePhase == .failed && seen.contains { $0.stalled } }
        #expect(typed.lines.isEmpty, "A take is streamed, not delivered whole")
        #expect(seen.first?.text == "Hello " && seen.allSatisfy { !$0.isFinal })
        #expect(session.pipeline.outbox.count == 1, "The stalled take is not acknowledged; its partial text is in the field")

        await session.pipeline.retry()
        // The writer follows the retry to its end and acknowledges it, so the finished delivery is only in the outbox
        // for an instant: wait for what the writer saw and for the acknowledgement, not for that window.
        try await until { retracted == 1 && seen.last?.isFinal == true && session.pipeline.outbox.isEmpty }
        #expect(seen.last?.text == "Hello world." && seen.last?.retracted == false, "The retry streamed on to the whole text")
        #expect(retracted == 1 && session.pipeline.nextOutboxSequenceForTesting == 2, "The partial (sequence 0) was retracted and acknowledged; the retry is sequence 1")
    }
}
