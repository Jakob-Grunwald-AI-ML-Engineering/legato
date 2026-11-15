import Foundation
import LegatoComposerDoc

public enum RoomError: Error, Equatable {
    case retiredDocumentChannel, sessionEnded, invalidSegment, invalidLifecycleTransition
}

/// Ordered ASR events and transcription draining shared by dictation and meetings.
public actor Room {
    private var sequence: Int64 = 0
    private var subscribers: [UUID: (Set<Channel>, AsyncStream<Envelope>.Continuation)] = [:]
    private var lifecycle = SessionLifecycle()
    private var transcriberDraining = false
    private var pendingSegments: Set<String> = []
    private let clock: @Sendable () -> Double
    private let log: SessionLog?
    private let segmentRouting: SegmentRouting
    private let logsTail: Bool
    public private(set) var loggingError: String?
    public var state: SessionState { lifecycle.state }
    public init(log: SessionLog? = nil, segmentRouting: SegmentRouting = .automatic, logsTail: Bool = true,
                clock: @escaping @Sendable () -> Double = { ProcessInfo.processInfo.systemUptime }) {
        self.log = log; self.segmentRouting = segmentRouting; self.logsTail = logsTail; self.clock = clock
    }

    public func subscribe(participant: Participant, channels: Set<Channel>, buffering: SubscriptionBuffer? = nil) -> AsyncStream<Envelope> {
        let policy: AsyncStream<Envelope>.Continuation.BufferingPolicy
        switch buffering ?? (participant == .ui ? .newest(1) : .unbounded) {
        case .unbounded: policy = .unbounded
        case .newest(let count): policy = .bufferingNewest(max(1, count))
        }
        let id = UUID()
        let pair = AsyncStream<Envelope>.makeStream(bufferingPolicy: policy)
        if state == .done { pair.continuation.finish(); return pair.stream }
        subscribers[id] = (channels, pair.continuation)
        pair.continuation.onTermination = { [weak self] _ in
            Task { await self?.removeSubscription(id) }
        }
        return pair.stream
    }

    private func removeSubscription(_ id: UUID) { subscribers.removeValue(forKey: id) }

    @discardableResult public func publish(channel: Channel, participant: Participant, payload: JSONValue,
        tOrigin: Double? = nil, baseRev: Int? = nil, causedBy: String? = nil) throws -> Envelope {
        guard !channel.isDocument else { throw RoomError.retiredDocumentChannel }
        try requireActive()
        // Intercepted ASR consumers receive the provider tail directly.
        if channel == .asrTail, case .intercepted = segmentRouting {
            return emit(channel: .asrRawTail, participant: participant, payload: payload,
                        tOrigin: tOrigin, baseRev: baseRev, causedBy: causedBy)
        }
        if channel == .asrSegment {
            guard let encodedWords = payload["words"], let words = try? encodedWords.decode([Word].self), !words.isEmpty else {
                throw RoomError.invalidSegment
            }
            let envelope = emit(channel: channel, participant: participant, payload: payload,
                                tOrigin: tOrigin, baseRev: baseRev, causedBy: causedBy)
            if segmentRouting == .intercepted { pendingSegments.insert(envelope.id) }
            return envelope
        }
        return emit(channel: channel, participant: participant, payload: payload,
                    tOrigin: tOrigin, baseRev: baseRev, causedBy: causedBy)
    }

    /// Payload: {"words":[Word]}. Extra segment timing/threshold fields may be sent via publish.
    @discardableResult public func publishSegment(words: [Word], tOrigin: Double? = nil, causedBy: String? = nil) throws -> Envelope {
        try publish(channel: .asrSegment, participant: .segmenter,
                    payload: .object(["words": try .encoding(words)]), tOrigin: tOrigin, causedBy: causedBy)
    }

    /// A consumer acknowledges a segment after processing it so transcription can drain.
    public func resolveSegment(_ envelopeID: String) {
        guard pendingSegments.remove(envelopeID) != nil else { return }
        advanceToFinalPass()
    }

    /// Call after issuing provider finalize. Segment/status events may still arrive while trailing.
    public func micOff(transcriberDraining: Bool = false) throws {
        try requireActive()
        guard state == .listening else { return }
        self.transcriberDraining = transcriberDraining
        lifecycle.micOff()
        sessionEvent("mic.off")
        advanceToFinalPass()
    }

    public func finishTranscription() {
        transcriberDraining = false
        advanceToFinalPass()
    }

    private func advanceToFinalPass() {
        guard !transcriberDraining, pendingSegments.isEmpty, lifecycle.beginFinalPassIfReady() else { return }
        sessionEvent("final.pass")
    }

    public func finishFinalPass() throws {
        try requireActive()
        guard state == .finalPass else { throw RoomError.invalidLifecycleTransition }
        finish(reason: "complete")
    }

    public func cancel() throws { if state != .done { finish(reason: "cancel") } }

    private func finish(reason: String) {
        lifecycle.finish()
        sessionEvent("cancel.work", fields: ["reason": .string(reason)])
        sessionEvent("done", fields: ["reason": .string(reason)])
        for (_, continuation) in subscribers.values { continuation.finish() }
        subscribers.removeAll()
    }

    private func sessionEvent(_ event: String, fields: [String: JSONValue] = [:]) {
        var payload = fields
        payload["event"] = .string(event)
        payload["state"] = .string(state.rawValue)
        _ = emit(channel: .session, participant: .document, payload: .object(payload))
    }

    private func requireActive() throws { if state == .done { throw RoomError.sessionEnded } }

    @discardableResult private func emit(channel: Channel, participant: Participant, payload: JSONValue,
        tOrigin: Double? = nil, baseRev: Int? = nil, causedBy: String? = nil, logged: Bool = true) -> Envelope {
        sequence += 1
        let now = clock()
        let envelope = Envelope(seq: sequence, id: UUID().uuidString, channel: channel,
                                participant: participant, tMono: now, tOrigin: tOrigin ?? now,
                                baseRev: baseRev, causedBy: causedBy, payload: payload)
        // A long session (a meeting) leaves the tail out of the log: it changes with every provider frame.
        let isTail = channel == .asrTail || channel == .asrRawTail
        if logged, logsTail || !isTail { do { try log?.append(envelope) } catch { loggingError = String(describing: error) } }
        for (channels, continuation) in subscribers.values where channels.contains(channel) { continuation.yield(envelope) }
        return envelope
    }
}
