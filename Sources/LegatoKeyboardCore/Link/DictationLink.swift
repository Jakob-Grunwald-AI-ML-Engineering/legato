import Foundation

public enum DictationLineStatus: String, Codable, Sendable, Equatable {
    /// `text` is the model's cleanup of `raw`.
    case cleaned
    /// Cleanup failed, timed out or was rejected: `text` is the raw line.
    case raw
}

/// One dictated line for the keyboard to type, in speaking order (`seq` counts from 0 within a session).
public struct DictationLine: Codable, Equatable, Sendable {
    public var lineID: String
    public var seq: Int
    public var raw: String
    /// What to type: the cleaned line, or the raw line when `status` is `raw`.
    public var text: String
    public var status: DictationLineStatus
    public init(lineID: String, seq: Int, raw: String, text: String, status: DictationLineStatus) {
        self.lineID = lineID; self.seq = seq; self.raw = raw; self.text = text; self.status = status
    }
}

/// app -> keyboard (`link.dictation`): the lines not yet acknowledged, oldest first, for one keyboard session.
/// A new `sessionID` starts counting from 0 again.
public struct DictationPublication: Codable, Equatable, Sendable {
    public var sessionID: String
    public var lines: [DictationLine]
    public init(sessionID: String, lines: [DictationLine] = []) { self.sessionID = sessionID; self.lines = lines }
}

/// keyboard -> app (`link.dictation.ack`): every line up to and including `upTo` is typed or dropped (a user edit
/// stopped it), so the app stops sending it and the keyboard never types it twice.
public struct DictationAck: Codable, Equatable, Sendable {
    public var sessionID: String
    public var upTo: Int
    public init(sessionID: String, upTo: Int) { self.sessionID = sessionID; self.upTo = upTo }
}

public struct DictationLink: Sendable {
    public let store: LinkStore
    public init(store: LinkStore) { self.store = store }
    public func publish(_ value: DictationPublication) {
        store.write(value, forKey: LinkChannel.Key.dictation)
    }
    public func read() -> DictationPublication? { store.read(DictationPublication.self, forKey: LinkChannel.Key.dictation) }
    public func acknowledge(_ ack: DictationAck) { store.write(ack, forKey: LinkChannel.Key.dictationAck) }
    public func acknowledged() -> DictationAck? { store.read(DictationAck.self, forKey: LinkChannel.Key.dictationAck) }
}
