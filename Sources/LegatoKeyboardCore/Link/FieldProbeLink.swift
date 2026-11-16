#if DEBUG || LEGATO_INTERNAL
import Foundation

/// Explicit development-only raw proxy exploration. No interpretation of cursor units or field text.
/// `delete`, `insert` and `burst` write, and only into a synthetic field: one that was empty at `begin` or whose
/// window then held `FieldProbeRequest.marker`.
public struct FieldProbeRequest: Codable, Sendable, Equatable {
    public enum Action: String, Codable, Sendable { case begin, read, move, pause, status, end, delete, insert, burst }
    public static let marker = "PROBE:"
    public var id: String
    public var sessionID: String
    public var action: Action
    public var delta: Int
    public var milliseconds: Int
    /// `delete` and `burst`: back-to-back `deleteBackward` calls.
    public var count: Int?
    /// `insert` and `burst`: one `insertText` call.
    public var text: String?
    /// `burst`: the move back after the edit (the return to the user's caret).
    public var back: Int?
    public var at: Date
    public init(id: String, sessionID: String, action: Action, delta: Int = 0, milliseconds: Int = 0,
                count: Int? = nil, text: String? = nil, back: Int? = nil, at: Date = Date()) {
        self.id = id; self.sessionID = sessionID; self.action = action
        self.delta = delta; self.milliseconds = milliseconds; self.count = count; self.text = text; self.back = back; self.at = at
    }
    public var writes: Bool { action == .delete || action == .insert || action == .burst }
}

public struct FieldProbeObservation: Codable, Sendable, Equatable {
    /// What produced the sample: `sent` (right after the calls), `text` / `selection` (a host callback),
    /// `window` (the proxy changed with no callback), `settled` (end of the settle time); nil for plain reads.
    public var event: String?
    public var elapsedMs: Double
    public var uptimeMs: Double
    public var before: String
    public var after: String
    public var selected: String?
    public var hasText: Bool
    public var fieldID: String?
    public var secure: Bool
    public var nativeTextChangeCount: Int?
    public var nativeSelectionChangeCount: Int?
    public init(elapsedMs: Double, uptimeMs: Double, before: String, after: String, selected: String?, hasText: Bool, fieldID: String?, secure: Bool, nativeTextChangeCount: Int? = nil, nativeSelectionChangeCount: Int? = nil, event: String? = nil) {
        self.event = event; self.elapsedMs = elapsedMs; self.uptimeMs = uptimeMs; self.before = before; self.after = after
        self.selected = selected; self.hasText = hasText; self.fieldID = fieldID; self.secure = secure
        self.nativeTextChangeCount = nativeTextChangeCount; self.nativeSelectionChangeCount = nativeSelectionChangeCount
    }
}

public struct FieldProbeReply: Codable, Sendable, Equatable {
    public var id: String
    public var probeSessionID: String
    public var action: FieldProbeRequest.Action
    public var active: Bool
    public var ownsLease: Bool
    public var fieldID: String?
    public var requestedDelta: Int?
    public var ok: Bool
    public var error: String?
    public var observations: [FieldProbeObservation]
    public init(request: FieldProbeRequest, active: Bool, ownsLease: Bool, fieldID: String?, error: String? = nil, observations: [FieldProbeObservation] = []) {
        id = request.id; probeSessionID = request.sessionID; action = request.action
        self.active = active; self.ownsLease = ownsLease; self.fieldID = fieldID
        requestedDelta = request.action == .move || request.action == .burst ? request.delta : nil
        ok = error == nil; self.error = error; self.observations = observations
    }
}

public struct FieldProbeLink: Sendable {
    public static var note: String { "\(RuntimeIdentity.current.notificationNamespace).link.field-probe" }
    private static let requestKey = "link.debug.field-probe.request"
    private static let replyKey = "link.debug.field-probe.reply"
    public let store: LinkStore
    public init(store: LinkStore) { self.store = store }
    public func request(_ request: FieldProbeRequest) { store.write(request, forKey: Self.requestKey) }
    public func takeRequest() -> FieldProbeRequest? {
        let value = store.read(FieldProbeRequest.self, forKey: Self.requestKey)
        if value != nil { store.remove(forKey: Self.requestKey) }
        return value
    }
    public func cancelRequest(id: String) {
        if store.read(FieldProbeRequest.self, forKey: Self.requestKey)?.id == id { store.remove(forKey: Self.requestKey) }
    }
    public func reply(_ reply: FieldProbeReply) { store.write(reply, forKey: Self.replyKey) }
    public func takeReply(id: String) -> FieldProbeReply? {
        guard let reply = store.read(FieldProbeReply.self, forKey: Self.replyKey), reply.id == id else { return nil }
        store.remove(forKey: Self.replyKey)
        return reply
    }
}
#endif
