import Foundation
import Observation
import os
import LegatoAudio
import LegatoClaude
import LegatoCore
import LegatoSoniox

/// The Mac dictation hotkey's session: it types straight into the focused field, and it never shares speech with
/// the composer (own microphone source, own Room and Soniox connection through `DictationEngine`).
///
/// Idle, the app holds the engine's Soniox connection (authenticated, upgraded, no start request, so unbilled)
/// and a credential-free connection to the Messages API, so the hotkey only has to open the microphone and
/// send the start request. A session runs hotkey press → hotkey press (or release, push-to-talk):
/// `start` resets the cleanup context (previous lines, text before the cursor), opens the microphone and the take;
/// finalized lines go through `DictationPipeline` (cleanup-only Haiku, ordered, raw on failure or after 2.5 s)
/// and are handed to `deliver` strictly in speaking order. `stop` finalizes and returns once the last line
/// was delivered.
@MainActor @Observable public final class MacDictationSession {
    public enum Phase: String, Sendable, Equatable { case idle, starting, listening, finishing }
    public private(set) var phase = Phase.idle
    /// The last thing that kept dictation from starting or working; `noticeID` changes with every new one.
    public private(set) var notice: String?
    public private(set) var noticeID = 0
    /// The live line (Soniox partials not yet final).
    public var tail: String { engine.tail }
    public var voiceIsolationStatus: String? { phase == .listening ? engine.voiceIsolationStatus : nil }
    public var isActive: Bool { phase != .idle }
    @ObservationIgnored public let pipeline: DictationPipeline
    @ObservationIgnored let engine: DictationEngine
    @ObservationIgnored private let mic: any AudioSource
    @ObservationIgnored private let sonioxKey: @MainActor () -> String
    @ObservationIgnored private let claudeKey: @MainActor () -> Bool
    @ObservationIgnored private let warmConnection: @Sendable () async -> Void
    @ObservationIgnored private let settleTimeout: Duration
    @ObservationIgnored private var audioTask: Task<Void, Never>?
    @ObservationIgnored private var stopTask: Task<Void, Never>?
    @ObservationIgnored private var pendingStop = false
    @ObservationIgnored private var debugSession = false
    @ObservationIgnored private var lastWarm: Date?
    @ObservationIgnored private var draining = false
    @ObservationIgnored private var delivered = -1
    @ObservationIgnored private var held = false
    /// A failed take's partial text sits in the field until Retry / Insert as-is retracts it.
    @ObservationIgnored private var stalled: (session: String, sequence: Int)?
    /// Where finished lines go (the focused field); called one line at a time, in speaking order.
    @ObservationIgnored public var deliver: @MainActor (String) async -> Void = { _ in }
    /// Types one take that is still being cleaned (whole-take modes): `poll` returns its state as it grows; returns
    /// true when the take was left open because its cleanup failed (nothing more will come until the user chooses).
    @ObservationIgnored public var deliverStream: (@MainActor (_ poll: @MainActor () -> DictationStreamState?) async -> Bool)?
    /// Takes the stalled take's partial text back out of the field (Retry / Insert as-is).
    @ObservationIgnored public var retractStream: (@MainActor () async -> Void)?
    /// A new session begins (capture the target field).
    @ObservationIgnored public var onBegin: @MainActor () -> Void = {}
    /// The session's last line was delivered (settle anything held back).
    @ObservationIgnored public var onEnd: @MainActor () async -> Void = {}
    private static let log = Logger(subsystem: "de.gruenwald.legato", category: "mac-dictation")
    private static let warmInterval: TimeInterval = 240

    public init(pipeline: DictationPipeline, microphone: any AudioSource, vocabularyURL: URL,
                sonioxKey: @escaping @MainActor () -> String = { (try? KeychainKeyStore(service: "de.gruenwald.legato.soniox").apiKey()) ?? "" },
                claudeKey: @escaping @MainActor () -> Bool = { ((try? KeychainKeyStore().apiKey()) ?? nil)?.isEmpty == false },
                makeSocket: @escaping @Sendable () -> any SonioxSocket = { URLSessionSonioxSocket() },
                warmConnection: @escaping @Sendable () async -> Void = { await KeyboardSession.warmClaudeConnection() },
                settleTimeout: Duration = .seconds(4)) {
        self.pipeline = pipeline; mic = microphone; self.sonioxKey = sonioxKey; self.claudeKey = claudeKey
        self.warmConnection = warmConnection; self.settleTimeout = settleTimeout
        engine = DictationEngine(sink: pipeline, sonioxKey: sonioxKey, makeSocket: makeSocket, vocabularyURL: vocabularyURL)
        pipeline.onChange = { [weak self] in self?.drain() }
    }

    /// Holds the Soniox connection and the Claude connection while the app runs and keys exist. Cheap to call
    /// often: an open route only re-warms a missing connection, and the Claude HEAD is throttled.
    public func ensureWarm() {
        guard !sonioxKey().isEmpty else { return }
        guard phase == .idle || phase == .listening || engine.isOpen else { return }
        engine.open()
        if lastWarm.map({ Date().timeIntervalSince($0) >= Self.warmInterval }) ?? true {
            lastWarm = Date()
            let warm = warmConnection
            Task.detached { await warm() }
        }
    }
    public var isWarm: Bool { engine.isLive }

    // MARK: Session

    /// Starts dictating. False (with a `notice`) when it cannot.
    @discardableResult public func start() async -> Bool {
        guard !VoiceEnrollmentController.shared.isBusy else { post("Finish or cancel voice profile setup first."); return false }
        await stopTask?.value
        guard !VoiceEnrollmentController.shared.isBusy else { post("Finish or cancel voice profile setup first."); return false }
        guard phase == .idle else { return phase == .listening }
        phase = .starting; pendingStop = false
        guard !sonioxKey().isEmpty else {
            phase = .idle
            post("Add your Soniox key in Legato Settings to dictate.")
            return false
        }
        await beginContext()
        let audio: AsyncStream<AudioChunk>
        do { audio = try await mic.start(format: .init(sampleRate: 16000, channelCount: 1)) }
        catch {
            phase = .idle
            post("Can't use the microphone. Allow Legato in System Settings, Privacy & Security, Microphone.")
            Self.log.error("mac.dictation.mic.failed \(String(describing: error), privacy: .public)")
            return false
        }
        await engine.activate()
        guard engine.hasActiveTake else {
            await mic.stop()
            phase = .idle
            engine.open()
            post("Can't reach Soniox. Check your connection and key, then try again.")
            return false
        }
        phase = .listening
        if !claudeKey() { post("No Claude key: lines are typed as heard. Add it in Legato Settings.") }
        let engine = self.engine
        audioTask = Task {
            var converter = PCM16Converter()
            for await chunk in audio {
                guard !Task.isCancelled, let pcm = try? converter.convert(chunk) else { continue }
                await engine.send(pcm)
            }
        }
        Task { await pipeline.warm() }
        if pendingStop { pendingStop = false; await stop() }
        return true
    }

    /// Finalizes what was heard, delivers the remaining lines, then idles. A stop during `start` waits for it.
    public func stop() async {
        if phase == .starting { pendingStop = true; return }
        guard phase == .listening else { return }
        if let stopTask { await stopTask.value; return }
        phase = .finishing
        updateAutoSend()
        let task = Task { await self.finishSession() }
        stopTask = task
        await task.value
    }
    private func finishSession() async {
        if debugSession {
            debugSession = false
        } else {
            await mic.stop()
            await audioTask?.value; audioTask = nil
            await engine.finalizeTake()
            await engine.waitForFinish(timeout: .seconds(3))
        }
        _ = await pipeline.settle(timeout: settleTimeout)
        // The whole take (on stop, or what the pause timer has not sent yet) is cleaned and written once, here.
        // The cleanup bounds itself (a timeout per attempt, one retry); a failure leaves the raw text held for the user.
        await pipeline.finishTake()
        await drainNow()
        await onEnd()
        phase = .idle
        stopTask = nil
        updateAutoSend()
    }

    /// The hotkey is held (push-to-talk): release is the send, so the pause timer stays quiet. Taps and the
    /// debug bridge are not held.
    public func setHeld(_ held: Bool) { self.held = held; updateAutoSend() }
    /// No automatic send while the key is held or while stopping (stop sends the take itself).
    private func updateAutoSend() { pipeline.setAutoSendSuppressed(held || phase == .finishing) }

    /// A chord after the hotkey started the run: drop the take and the half-spoken words. Lines already typed stay.
    public func cancel() async {
        await stopTask?.value
        guard phase != .idle else { return }
        pendingStop = false
        debugSession = false
        await mic.stop()
        audioTask?.cancel(); audioTask = nil
        await engine.abandonTake()
        await pipeline.reset()
        delivered = -1; stalled = nil
        phase = .idle
        ensureWarm()
    }

    /// Start of a session: the previous session's lines are written first, then the cleanup context starts empty.
    private func beginContext() async {
        _ = await pipeline.settle(timeout: settleTimeout)
        await drainNow()
        await pipeline.reset(keepFailedTake: true)
        delivered = -1; stalled = nil
        engine.resetSequence()
        engine.open()
        onBegin()
    }

    func post(_ text: String) {
        notice = text; noticeID += 1
        Self.log.info("mac.dictation.notice")
    }
    /// A notice from the delivery side (clipboard fallback, no field).
    public func report(_ text: String) { post(text) }

    // MARK: Delivery

    /// The outbox is written to the field in order; each acknowledged line leaves it.
    private func drain() {
        guard !draining else { return }
        Task { await drainNow() }
    }
    private func drainNow() async {
        while draining { try? await Task.sleep(for: .milliseconds(5)) }
        draining = true; defer { draining = false }
        await settleStalled()
        while let next = pipeline.outbox.first(where: { $0.sequence > delivered }) {
            let session = pipeline.sessionID
            delivered = next.sequence
            if next.isTake, let deliverStream {
                // A take streams: the writer follows its growing delivery until it is final (or stalls).
                let sequence = next.sequence, pipeline = self.pipeline
                let stalledHere = await deliverStream {
                    guard pipeline.sessionID == session, let entry = pipeline.outbox.first(where: { $0.sequence == sequence }) else { return nil }
                    return .init(text: entry.text, isFinal: entry.final, stalled: entry.failed && !entry.final && !entry.retracted,
                                 retracted: entry.retracted)
                }
                if stalledHere { stalled = (session, sequence); continue }
            } else {
                await deliver(next.text)
            }
            pipeline.acknowledge(sessionID: session, upTo: next.sequence)
        }
    }

    /// A failed take left its partial text open: once the user retracted it (Retry / Insert as-is) it is erased and
    /// the delivery acknowledged; a delivery that ended otherwise (discarded, reset) is just acknowledged.
    private func settleStalled() async {
        guard let held = stalled else { return }
        guard held.session == pipeline.sessionID,
              let entry = pipeline.outbox.first(where: { $0.sequence == held.sequence }) else { stalled = nil; return }
        guard entry.retracted || entry.final else { return }
        stalled = nil
        if entry.retracted { await retractStream?() }
        pipeline.acknowledge(sessionID: held.session, upTo: held.sequence)
    }

    // MARK: Debug

    #if DEBUG || LEGATO_INTERNAL
    /// Debug bridge: a finalized line enters the route where a Soniox segment does (cleanup, field writing run for
    /// real). Without a running session this begins a microphone-free one, so acceptance needs no keys or speech.
    public func debugLine(_ text: String) async throws {
        try await beginDebugIfIdle()
        guard await engine.debugLine(text) else { throw DebugError.empty }
    }
    public func debugTail(_ text: String) async throws {
        try await beginDebugIfIdle()
        engine.debugTail(text)
    }
    public func debugStop() async {
        guard debugSession else { return }
        engine.debugTail("")
        await stop()
    }
    private func beginDebugIfIdle() async throws {
        guard phase == .idle else { return }
        await stopTask?.value
        phase = .starting
        await beginContext()
        debugSession = true
        phase = .listening
    }
    public enum DebugError: Error, CustomStringConvertible, Sendable {
        case empty
        public var description: String { "Empty dictation text." }
    }
    public var debugState: [String: Any] {
        ["phase": phase.rawValue, "tail": tail, "notice": notice ?? "", "noticeID": noticeID, "warm": engine.isLive,
         "pending": pipeline.pending, "outbox": pipeline.outbox.count, "fallbacks": pipeline.fallbacks, "debugSession": debugSession,
         "delivered": delivered, "sessionID": pipeline.sessionID]
            .merging(pipeline.takeState) { $1 }
    }
    #endif
}
