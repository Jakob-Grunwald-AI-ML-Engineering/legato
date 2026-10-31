import Foundation
import LegatoComposerDoc

public enum RoomError: Error, Equatable {
    case documentChannelRequiresCapability, sessionEnded, invalidSegment, invalidLifecycleTransition
}

/// One composition, optionally spanning multiple microphone activations. All envelope assignment and document mutations run on this actor.
public actor Room {
    private var sequence: Int64 = 0
    private var subscribers: [UUID: (Set<Channel>, AsyncStream<Envelope>.Continuation)] = [:]
    private var document = ComposerDocument()
    private var lifecycle = SessionLifecycle()
    private var transcriberDraining = false
    private var pendingSegments: Set<String> = []
    private let clock: @Sendable () -> Double
    private let log: SessionLog?
    private let segmentRouting: SegmentRouting
    private let resumable: Bool
    public private(set) var loggingError: String?
    public var state: SessionState { lifecycle.state }
    public var documentSnapshot: DocumentSnapshot { document.snapshot }
    public init(log: SessionLog? = nil, segmentRouting: SegmentRouting = .automatic, resumable: Bool = false,
                clock: @escaping @Sendable () -> Double = { ProcessInfo.processInfo.systemUptime }) {
        self.log = log; self.segmentRouting = segmentRouting; self.resumable = resumable; self.clock = clock
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
        guard !channel.isDocument else { throw RoomError.documentChannelRequiresCapability }
        try requireActive()
        // In intercepted sessions only the binder publishes the general partial transcript.
        if channel == .asrTail, participant != .hintBinder, case .intercepted = segmentRouting {
            return emit(channel: .asrRawTail, participant: participant, payload: payload,
                        tOrigin: tOrigin, baseRev: baseRev, causedBy: causedBy)
        }
        if channel == .asrSegment {
            guard let encodedWords = payload["words"], let words = try? encodedWords.decode([Word].self), !words.isEmpty else {
                throw RoomError.invalidSegment
            }
            let envelope = emit(channel: channel, participant: participant, payload: payload,
                                tOrigin: tOrigin, baseRev: baseRev, causedBy: causedBy)
            if segmentRouting == .automatic { _ = try appendSegment(words: words, causedBy: envelope.id) }
            else { pendingSegments.insert(envelope.id) }
            return envelope
        }
        return emit(channel: channel, participant: participant, payload: payload,
                    tOrigin: tOrigin, baseRev: baseRev, causedBy: causedBy)
    }

    /// Operational acknowledgement only: successful Clear/Insert may already have ended
    /// subscriptions. Retain their terminal result in the owning session log without
    /// reopening the Room or granting a document mutation capability.
    public func recordHostAction(stage: String, actionID: String, instructionID: String, action: String,
                                 sessionToken: String, succeeded: Bool? = nil, message: String? = nil) {
        guard ["queued", "result"].contains(stage), ["clear_composer", "insert_draft"].contains(action) else { return }
        var fields: [String: JSONValue] = ["event": .string("host.action." + stage),
            "actionID": .string(actionID), "instructionID": .string(instructionID),
            "action": .string(action), "sessionToken": .string(sessionToken)]
        if let succeeded { fields["succeeded"] = .bool(succeeded) }
        if let message { fields["message"] = .string(message) }
        _ = emit(channel: .agentStatus, participant: .ui, payload: .object(fields))
    }

    /// Payload: {"words":[Word]}. Extra segment timing/threshold fields may be sent via publish.
    @discardableResult public func publishSegment(words: [Word], tOrigin: Double? = nil, causedBy: String? = nil) throws -> Envelope {
        try publish(channel: .asrSegment, participant: .segmenter,
                    payload: .object(["words": try .encoding(words)]), tOrigin: tOrigin, causedBy: causedBy)
    }

    @discardableResult public func appendSegment(words: [Word], causedBy: String? = nil, resolve: Bool = true) throws -> Transaction {
        try requireActive()
        guard !words.isEmpty else { throw RoomError.invalidSegment }
        let transaction = try document.appendSegment(words: words)
        publishTransaction(transaction, causedBy: causedBy)
        if resolve, let causedBy { resolveSegment(causedBy) }
        return transaction
    }

    /// A routed hint consumes an ASR segment without appending it to the document.
    public func resolveSegment(_ envelopeID: String) {
        guard pendingSegments.remove(envelopeID) != nil else { return }
        advanceToFinalPass()
    }

    @discardableResult public func applyDocument(_ ops: [DocOp], origin: TransactionOrigin,
        versions: [String: Int], groupID: String? = nil, causedBy: String? = nil) throws -> Transaction {
        try requireActive()
        let transaction = try document.apply(ops, origin: origin, versions: versions, groupID: groupID)
        publishTransaction(transaction, causedBy: causedBy)
        return transaction
    }

    @discardableResult public func undoDocument(transactionID: String, causedBy: String? = nil) throws -> Transaction {
        try requireActive()
        let transaction = try document.undo(transactionID: transactionID)
        publishTransaction(transaction, causedBy: causedBy)
        return transaction
    }

    private func publishTransaction(_ transaction: Transaction, causedBy: String?) {
        guard let publication = document.publication(for: transaction) else { return }
        _ = try? publishDocument(publication, causedBy: causedBy)
        _ = try? publishDocument(document.snapshotPublication, causedBy: causedBy)
    }

    /// A publication can only be minted by ComposerDocument; arbitrary doc payloads are rejected.
    @discardableResult public func publishDocument(_ publication: DocumentPublication, causedBy: String? = nil) throws -> Envelope {
        try requireActive()
        switch publication.event {
        case .ops(let transaction):
            return emit(channel: .docOps, participant: .document, payload: try .encoding(transaction),
                        baseRev: transaction.revision, causedBy: causedBy)
        case .snapshot(let snapshot):
            return emit(channel: .docSnapshot, participant: .document, payload: try .encoding(snapshot),
                        baseRev: snapshot.revision, causedBy: causedBy)
        }
    }

    public func setAgentBusy(_ participant: Participant, busy: Bool) {
        guard participant == .liveAgent || participant == .restructureAgent, state != .done else { return }
        lifecycle.setBusy(participant, busy: busy)
        _ = emit(channel: .agentStatus, participant: participant, payload: .object(["busy": .bool(busy)]))
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
        if resumable {
            lifecycle.pause()
            sessionEvent("paused")
            do { try log?.finish(document.snapshot.text) } catch { loggingError = String(describing: error) }
        } else { finish(reason: "complete") }
    }

    /// Resume the same composition after its final pass, retaining all subscribers and history.
    public func resume() throws {
        try requireActive()
        guard resumable, state == .paused else { throw RoomError.invalidLifecycleTransition }
        lifecycle.resume()
        sessionEvent("mic.on")
    }

    /// Returns the current text immediately; cancellation is an event, never an awaited agent task.
    public func insert() throws -> DocumentSnapshot {
        let snapshot = document.snapshot
        if state != .done { finish(reason: "insert") }
        return snapshot
    }
    public func cancel() throws { if state != .done { finish(reason: "cancel") } }

    private func finish(reason: String) {
        lifecycle.finish()
        sessionEvent("cancel.work", fields: ["reason": .string(reason)])
        sessionEvent("done", fields: ["reason": .string(reason)])
        do { try log?.finish(document.snapshot.text) } catch { loggingError = String(describing: error) }
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
        tOrigin: Double? = nil, baseRev: Int? = nil, causedBy: String? = nil) -> Envelope {
        sequence += 1
        let now = clock()
        let envelope = Envelope(seq: sequence, id: UUID().uuidString, channel: channel,
                                participant: participant, tMono: now, tOrigin: tOrigin ?? now,
                                baseRev: baseRev, causedBy: causedBy, payload: payload)
        do { try log?.append(envelope) } catch { loggingError = String(describing: error) }
        for (channels, continuation) in subscribers.values where channels.contains(channel) { continuation.yield(envelope) }
        return envelope
    }
}
