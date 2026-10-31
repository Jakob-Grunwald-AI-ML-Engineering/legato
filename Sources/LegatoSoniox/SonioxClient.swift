import Foundation
import LegatoRoom

public enum SonioxFrame: Sendable, Equatable { case text(String), binary(Data) }
public protocol SonioxSocket: Sendable {
    func connect(request: URLRequest) async throws
    func send(_ frame: SonioxFrame) async throws
    func receive() async throws -> SonioxFrame
    func close() async
}

public actor URLSessionSonioxSocket: SonioxSocket {
    private var task: URLSessionWebSocketTask?
    private var session: URLSession?
    public init() {}
    public func connect(request: URLRequest) async throws {
        let session = URLSession(configuration: .ephemeral)
        self.session = session
        let task = session.webSocketTask(with: request); self.task = task; task.resume()
    }
    public func send(_ frame: SonioxFrame) async throws {
        guard let task else { throw SonioxError.notConnected }
        do {
            switch frame { case .text(let text): try await task.send(.string(text)); case .binary(let data): try await task.send(.data(data)) }
        } catch { throw transportError(task) }
    }
    public func receive() async throws -> SonioxFrame {
        guard let task else { throw SonioxError.notConnected }
        let message: URLSessionWebSocketTask.Message
        do { message = try await task.receive() } catch { throw transportError(task) }
        switch message {
        case .string(let text): return .text(text)
        case .data(let data): return .binary(data)
        @unknown default: throw SonioxError.invalidResponse
        }
    }
    private func transportError(_ task: URLSessionWebSocketTask) -> SonioxError {
        if let response = task.response as? HTTPURLResponse, response.statusCode >= 400 { return .provider(response.statusCode) }
        return .network
    }
    public func close() async {
        task?.cancel(with: .normalClosure, reason: nil); task = nil
        session?.invalidateAndCancel(); session = nil
    }
}

public enum SonioxError: Error, Sendable, Equatable, LocalizedError {
    case missingKey, notConnected, inputMuted, invalidResponse, network, timeout, cancelled, provider(Int)
    public var errorDescription: String? {
        switch self {
        case .missingKey: "Add a Soniox API key in Settings."
        case .notConnected: "Soniox is not connected."
        case .inputMuted: "Voice input is muted."
        case .invalidResponse: "Soniox returned an invalid response."
        case .network: "Soniox connection failed. Check your internet connection."
        case .timeout: "Soniox did not finish in time. The session log has been kept."
        case .cancelled: "Transcription cancelled."
        case .provider(401): "The Soniox API key is invalid. Update it in Settings."
        case .provider(402): "Soniox credits are exhausted."
        case .provider(408): "Soniox timed out. Try again."
        case .provider(413): "The Soniox session exceeded a service limit."
        case .provider(429): "Soniox is busy or rate limited. Try again shortly."
        case .provider(let code): "Soniox could not transcribe this session (\(code))."
        }
    }
}

/// When a failure stays out of the Room's `asr.error`: a pre-warmed stream that drops before any audio
/// was sent reconnects silently instead of failing the composition.
public enum SonioxQuietFailure: Sendable { case never, untilAudio, always }

/// Host-only provider adapter. Credentials exist only in the initial URLRequest, never room envelopes.
public actor SonioxClient {
    private enum State { case idle, streaming, finalizing, ending, finished, failed }
    private var state = State.idle
    private let room: Room
    private let config: SonioxConfig
    private let socket: any SonioxSocket
    private let keepaliveInterval: Duration
    private let finishTimeout: Duration
    private var segmenter = Segmenter()
    private var receiver: Task<Void, Never>?
    private var heartbeat: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?
    private var completion: CheckedContinuation<Void, any Error>?
    private var failure: SonioxError?
    private var lastSend = ContinuousClock.now
    private var debugInput = false
    private var muted = false
    private var latestTail = ""
    private var debugPartialTokens: [SonioxToken] = []
    private var audioOrigin: Double?
    private var sentAudio = false
    private let quietFailure: SonioxQuietFailure
    private let onDrop: (@Sendable () async -> Void)?
    /// `onDrop` runs after a quiet failure (never after `cancel` or `close`); the Room then sees only `asr.dropped`.
    public init(room: Room, config: SonioxConfig = SonioxConfig(), socket: any SonioxSocket = URLSessionSonioxSocket(),
                keepaliveInterval: Duration = .seconds(10), finishTimeout: Duration = .seconds(20), audioOrigin: Double? = nil,
                quietFailure: SonioxQuietFailure = .never, onDrop: (@Sendable () async -> Void)? = nil) {
        self.room = room; self.config = config; self.socket = socket
        self.keepaliveInterval = keepaliveInterval; self.finishTimeout = finishTimeout; self.audioOrigin = audioOrigin
        self.quietFailure = quietFailure; self.onDrop = onDrop
    }
    /// Connected, configured and accepting audio or finalize.
    public var isStreaming: Bool { state == .streaming }
    public func start(apiKey: String) async throws {
        guard state == .idle else { throw SonioxError.notConnected }
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            await fail(.missingKey); throw SonioxError.missingKey
        }
        do {
            try await socket.connect(request: config.request(apiKey: apiKey))
            try await socket.send(.text(String(decoding: config.message(), as: UTF8.self)))
            state = .streaming; lastSend = .now
            _ = try await room.publish(channel: .session, participant: .transcriber,
                payload: .object(["event": .string("asr.started"), "thresholds": thresholds]))
            receiver = Task { [weak self] in await self?.receiveLoop() }
            heartbeat = Task { [weak self, keepaliveInterval] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: keepaliveInterval) } catch { return }
                    await self?.keepalive()
                }
            }
        } catch { let visible = error as? SonioxError ?? .network; await fail(visible); throw visible }
    }
    #if DEBUG || LEGATO_INTERNAL
    /// Internal ingress shares the provider decoder and segmenter, with no socket or credentials.
    public var currentDebugTail: String { latestTail }
    public func startDebug() async throws {
        guard state == .idle else { throw SonioxError.notConnected }
        debugInput = true; state = .streaming
        _ = try await room.publish(channel: .session, participant: .transcriber,
            payload: .object(["event": .string("asr.started"), "inputSource": .string("debug.transcriber"), "thresholds": thresholds]))
    }
    public func injectDebugFrame(_ json: String) async throws {
        guard debugInput, state == .streaming else { throw SonioxError.notConnected }
        guard !muted else { throw SonioxError.inputMuted }
        // Validate before logging/applying; arbitrary provider errors/finished flags are not an injection API.
        let response = try JSONDecoder().decode(Response.self, from: Data(json.utf8))
        guard response.finished != true, response.error_code == nil,
              !(response.tokens ?? []).contains(where: { $0.text == "<fin>" }) else { throw SonioxError.invalidResponse }
        _ = try await room.publish(channel: .session, participant: .transcriber,
            payload: .object(["event": .string("debug.transcriber.frame"), "inputSource": .string("debug.transcriber"), "frame": try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))]))
        try await receiveFrame(.text(json))
    }
    #endif
    /// Finalize buffered speech without ending the provider stream or the Room's listening phase.
    /// The receiver remains active so finals from audio sent before mute can still reach agents.
    public func setMuted(_ value: Bool) async throws {
        guard state == .streaming else { throw failure ?? .notConnected }
        guard muted != value else { return }
        muted = value
        guard value else { return }
        do {
            if debugInput {
                try await flushDebugHypothesis()
            } else {
                try await socket.send(.text("{\"type\":\"finalize\"}")); lastSend = .now
            }
        } catch { let visible = error as? SonioxError ?? .network; await fail(visible); throw visible }
    }
    /// Flush the current provider hypothesis without stopping microphone/session input.
    @discardableResult public func finalizeChunk() async throws -> Bool {
        if state == .finished { return false }
        if state == .finalizing || state == .ending { return true }
        guard state == .streaming else { throw failure ?? .notConnected }
        if debugInput { try await flushDebugHypothesis() }
        else { try await socket.send(.text("{\"type\":\"finalize\"}")); lastSend = .now }
        return true
    }
    private func flushDebugHypothesis() async throws {
        var final = debugPartialTokens
        for index in final.indices { final[index].isFinal = true }
        final.append(SonioxToken(text: "<fin>", isFinal: true))
        let data = try JSONEncoder().encode(JSONValue.object(["tokens": try .encoding(final)]))
        try await receiveFrame(.text(String(decoding: data, as: UTF8.self)))
    }
    public func setAudioOrigin(_ origin: Double) { audioOrigin = origin }
    public func sendAudio(_ pcm16: Data) async throws {
        guard state == .streaming else { throw failure ?? .notConnected }
        guard !muted, !pcm16.isEmpty else { return }
        if audioOrigin == nil { audioOrigin = ProcessInfo.processInfo.systemUptime }
        do { try await socket.send(.binary(pcm16)); lastSend = .now; sentAudio = true }
        catch { await fail(.network); throw SonioxError.network }
    }
    /// Stops new audio, drains all final tokens, then waits for the server's finished acknowledgement.
    public func finish() async throws {
        if state == .finished { return }
        if let failure { throw failure }
        guard state == .streaming else { throw SonioxError.notConnected }
        state = .finalizing
        do {
            try await room.micOff(transcriberDraining: true)
            if debugInput {
                try await flushDebugHypothesis()
                try await receiveFrame(.text("{\"finished\":true}"))
            } else { try await socket.send(.text("{\"type\":\"finalize\"}")); lastSend = .now }
        } catch { let visible = error as? SonioxError ?? .network; await fail(visible); throw visible }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if state == .finished { continuation.resume(); return }
                if let failure { continuation.resume(throwing: failure); return }
                completion = continuation
                timeoutTask = Task { [weak self, finishTimeout] in
                    do { try await Task.sleep(for: finishTimeout) } catch { return }
                    await self?.fail(.timeout)
                }
            }
        } onCancel: { Task { await self.cancel() } }
    }
    public func cancel() async { await fail(.cancelled) }
    /// Ends the stream without finalizing: words not yet final, or final but not yet segmented, are dropped
    /// and never published. Publishes an empty tail and `asr.closed`, never `asr.error`.
    public func close() async {
        guard state != .finished && state != .failed else { return }
        state = .finished; receiver?.cancel(); heartbeat?.cancel(); timeoutTask?.cancel()
        completion?.resume(throwing: SonioxError.cancelled); completion = nil
        segmenter = Segmenter(); debugPartialTokens = []
        if !latestTail.isEmpty {
            latestTail = ""
            _ = try? await room.publish(channel: .asrTail, participant: .transcriber,
                payload: .object(["text": .string(""), "activity": .bool(false), "parts": .array([])]))
        }
        _ = try? await room.publish(channel: .session, participant: .transcriber, payload: .object(["event": .string("asr.closed")]))
        if !debugInput { await socket.close() }
    }
    private var thresholds: JSONValue { .object(["gapSeconds": .number(segmenter.gap), "maxWords": .number(Double(segmenter.maxWords)), "maxSeconds": .number(segmenter.maxDuration)]) }
    private func keepalive() async {
        guard state == .streaming || state == .finalizing || state == .ending else { return }
        guard lastSend.duration(to: .now) >= keepaliveInterval else { return }
        do { try await socket.send(.text("{\"type\":\"keepalive\"}")); lastSend = .now }
        catch { await fail(error as? SonioxError ?? .network) }
    }
    private struct Response: Decodable {
        var tokens: [SonioxToken]?
        var finished: Bool?
        var error_code: Int?
    }
    private func receiveLoop() async {
        do {
            while !Task.isCancelled {
                let frame = try await socket.receive()
                try await receiveFrame(frame)
                if state == .finished || state == .failed { return }
            }
        } catch { if state != .finished && state != .failed { await fail(error as? SonioxError ?? .network) } }
    }
    private func receiveFrame(_ frame: SonioxFrame) async throws {
        let data: Data
        switch frame { case .text(let text): data = Data(text.utf8); case .binary(let bytes): data = bytes }
        let response: Response
        do { response = try JSONDecoder().decode(Response.self, from: data) }
        catch { await fail(.invalidResponse); throw SonioxError.invalidResponse }
        if let code = response.error_code { await fail(.provider(code)); throw SonioxError.provider(code) }
        let tokens = response.tokens ?? []
        if debugInput { debugPartialTokens = tokens.filter { !$0.isFinal && !$0.text.hasPrefix("<") } }
        try await publish(segmenter.ingest(tokens, finished: response.finished == true),
                          activity: tokens.contains { !$0.text.hasPrefix("<") && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
        if state == .finalizing && tokens.contains(where: { $0.text == "<fin>" && $0.isFinal }) {
            state = .ending
            // Empty binary is merely an audio chunk. Soniox requires an empty TEXT frame.
            if !debugInput { try await socket.send(.text("")); lastSend = .now }
        }
        if response.finished == true {
            state = .finished; heartbeat?.cancel(); timeoutTask?.cancel()
            _ = try? await room.publish(channel: .session, participant: .transcriber, payload: .object(["event": .string("asr.finished")]))
            await room.finishTranscription()
            completion?.resume(); completion = nil
            if !debugInput { await socket.close() }; return
        }
    }
    private func publish(_ output: SegmenterOutput, activity: Bool) async throws {
        latestTail = output.tail
        for event in output.events {
            switch event {
            case .boundary(let reason, let time):
                _ = try await room.publish(channel: .asrBoundary, participant: .segmenter,
                    payload: .object(["reason": .string(reason)]),
                    tOrigin: time.flatMap { end in audioOrigin.map { $0 + end } })
            case .segment(let segment):
                let t0 = segment.words.first?.t0
                let t1 = segment.words.last?.t1
                let metadata: JSONValue = .object(["t0": t0.map(JSONValue.number) ?? .null, "t1": t1.map(JSONValue.number) ?? .null, "timings": try .encoding(segment.words.map { ["t0": $0.t0, "t1": $0.t1] }), "reason": .string(segment.reason), "thresholds": thresholds])
                _ = try await room.publish(channel: .asrSegment, participant: .segmenter,
                    payload: .object(["words": try .encoding(segment.words.map(\.word)), "metadata": metadata]),
                    tOrigin: t0.flatMap { start in audioOrigin.map { $0 + start } })
            }
        }
        _ = try await room.publish(channel: .asrTail, participant: .transcriber, payload: .object(["text": .string(output.tail), "activity": .bool(activity),
                "parts": .array(output.tailParts.map { part in .object(["text": .string(part.text),
                    "timed": .bool(part.time != nil), "tOrigin": .number(part.time.flatMap { time in audioOrigin.map { $0 + time } } ?? ProcessInfo.processInfo.systemUptime)]) })]))
    }
    private func fail(_ error: SonioxError) async {
        guard state != .finished && state != .failed else { return }
        state = .failed; failure = error; receiver?.cancel(); heartbeat?.cancel(); timeoutTask?.cancel()
        let quiet = quietFailure == .always || (quietFailure == .untilAudio && !sentAudio)
        _ = try? await room.publish(channel: .session, participant: .transcriber,
            payload: .object(["event": .string(quiet ? "asr.dropped" : "asr.error"), "message": .string(error.localizedDescription)]))
        completion?.resume(throwing: error); completion = nil
        await socket.close()
        if quiet, error != .cancelled { await onDrop?() }
    }
}
