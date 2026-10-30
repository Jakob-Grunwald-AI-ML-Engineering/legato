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
        switch frame { case .text(let text): try await task.send(.string(text)); case .binary(let data): try await task.send(.data(data)) }
    }
    public func receive() async throws -> SonioxFrame {
        guard let task else { throw SonioxError.notConnected }
        switch try await task.receive() {
        case .string(let text): return .text(text)
        case .data(let data): return .binary(data)
        @unknown default: throw SonioxError.invalidResponse
        }
    }
    public func close() async {
        task?.cancel(with: .normalClosure, reason: nil); task = nil
        session?.invalidateAndCancel(); session = nil
    }
}

public enum SonioxError: Error, Sendable, Equatable, LocalizedError {
    case missingKey, notConnected, invalidResponse, network, timeout, cancelled, provider(Int)
    public var errorDescription: String? {
        switch self {
        case .missingKey: "Add a Soniox API key in Settings."
        case .notConnected: "Soniox is not connected."
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
    public init(room: Room, config: SonioxConfig = SonioxConfig(), socket: any SonioxSocket = URLSessionSonioxSocket(),
                keepaliveInterval: Duration = .seconds(10), finishTimeout: Duration = .seconds(20)) {
        self.room = room; self.config = config; self.socket = socket
        self.keepaliveInterval = keepaliveInterval; self.finishTimeout = finishTimeout
    }
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
        } catch { await fail(.network); throw SonioxError.network }
    }
    public func sendAudio(_ pcm16: Data) async throws {
        guard state == .streaming else { throw failure ?? .notConnected }
        guard !pcm16.isEmpty else { return }
        do { try await socket.send(.binary(pcm16)); lastSend = .now }
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
            try await socket.send(.text("{\"type\":\"finalize\"}")); lastSend = .now
        } catch { await fail(.network); throw SonioxError.network }
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
    private var thresholds: JSONValue { .object(["gapSeconds": .number(segmenter.gap), "maxWords": .number(Double(segmenter.maxWords)), "maxSeconds": .number(segmenter.maxDuration)]) }
    private func keepalive() async {
        guard state == .streaming || state == .finalizing || state == .ending else { return }
        guard lastSend.duration(to: .now) >= keepaliveInterval else { return }
        do { try await socket.send(.text("{\"type\":\"keepalive\"}")); lastSend = .now }
        catch { await fail(.network) }
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
                let data: Data
                switch frame { case .text(let text): data = Data(text.utf8); case .binary(let bytes): data = bytes }
                let response: Response
                do { response = try JSONDecoder().decode(Response.self, from: data) }
                catch { await fail(.invalidResponse); return }
                if let code = response.error_code { await fail(.provider(code)); return }
                let tokens = response.tokens ?? []
                try await publish(segmenter.ingest(tokens, finished: response.finished == true))
                if state == .finalizing && tokens.contains(where: { $0.text == "<fin>" && $0.isFinal }) {
                    state = .ending
                    // Empty binary is merely an audio chunk. Soniox requires an empty TEXT frame.
                    try await socket.send(.text("")); lastSend = .now
                }
                if response.finished == true {
                    state = .finished; heartbeat?.cancel(); timeoutTask?.cancel()
                    try await room.finishTranscription()
                    _ = try await room.publish(channel: .session, participant: .transcriber, payload: .object(["event": .string("asr.finished")]))
                    completion?.resume(); completion = nil
                    await socket.close(); return
                }
            }
        } catch { if state != .finished && state != .failed { await fail(.network) } }
    }
    private func publish(_ output: SegmenterOutput) async throws {
        for segment in output.segments {
            let metadata: JSONValue = .object(["timings": try .encoding(segment.words.map { ["t0": $0.t0, "t1": $0.t1] }), "reason": .string(segment.reason), "thresholds": thresholds])
            _ = try await room.publish(channel: .asrSegment, participant: .segmenter,
                payload: .object(["words": try .encoding(segment.words.map(\.word)), "metadata": metadata]))
        }
        _ = try await room.publish(channel: .asrTail, participant: .transcriber, payload: .object(["text": .string(output.tail)]))
    }
    private func fail(_ error: SonioxError) async {
        guard state != .finished && state != .failed else { return }
        state = .failed; failure = error; receiver?.cancel(); heartbeat?.cancel(); timeoutTask?.cancel()
        _ = try? await room.publish(channel: .session, participant: .transcriber,
            payload: .object(["event": .string("asr.error"), "message": .string(error.localizedDescription)]))
        completion?.resume(throwing: error); completion = nil
        await socket.close()
    }
}
