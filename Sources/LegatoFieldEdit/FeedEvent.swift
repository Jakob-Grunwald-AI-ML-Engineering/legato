import Foundation

/// Why the queue dropped its shadow document and started over from a fresh read.
public enum ResetReason: String, Sendable, Hashable, Codable {
    /// The new read does not align with the window (the caret jumped, the window changed).
    case unaligned
    /// The field was emptied (cleared or sent).
    case cleared
    /// Another field or app took focus.
    case focusChanged
}

/// One entry of the change feed: what the field did, in landing order.
public enum FeedEvent: Sendable, Hashable, Codable {
    /// Recognized text streamed in (Mac only; on iOS the app owns ASR text).
    case asrDelta(String)
    /// A confirmed write; `steps` in application order, as in ``FieldWrite``.
    case applied(UUID, origin: EditOrigin, steps: [EditStep], version: FieldVersion)
    /// A change the queue did not write.
    case foreign(EditStep, byUser: Bool, version: FieldVersion)
    case conflict(UUID, Conflict)
    case reset(ResetReason, window: String, version: FieldVersion)

    /// The field version this event leaves, when it changes it.
    var version: FieldVersion? {
        switch self {
        case .applied(_, _, _, let version), .foreign(_, _, let version), .reset(_, _, let version): version
        case .asrDelta, .conflict: nil
        }
    }
}

public struct FeedEntry: Sendable, Hashable, Codable {
    public var seq: Int
    public var event: FeedEvent
}

/// The feed entries after a sequence number, and the field version they leave (the `base` for new edits).
public struct FeedBatch: Sendable, Hashable, Codable {
    public var entries: [FeedEntry]
    public var version: FieldVersion

    public init(entries: [FeedEntry], version: FieldVersion) {
        self.entries = entries
        self.version = version
    }

    /// The last sequence number in the batch; pass it to the next ``FeedLog/since(_:)``.
    public var lastSeq: Int? { entries.last?.seq }
}

/// The seq-numbered change feed (from 1, no gaps).
public struct FeedLog: Sendable, Hashable {
    public private(set) var entries: [FeedEntry] = []
    /// The field version after the newest event that moved it.
    public private(set) var version: FieldVersion

    public init(version: FieldVersion) { self.version = version }

    public var lastSeq: Int { entries.last?.seq ?? 0 }

    public mutating func append(_ event: FeedEvent) {
        entries.append(FeedEntry(seq: lastSeq + 1, event: event))
        if let version = event.version { self.version = version }
    }

    /// Every entry after `seq`, oldest first.
    public func since(_ seq: Int) -> FeedBatch {
        FeedBatch(entries: entries.filter { $0.seq > seq }, version: version)
    }
}
