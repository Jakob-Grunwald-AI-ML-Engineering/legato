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

/// One entry of the change feed: what the field did, in landing order. Positions are UTF-16 offsets into the
/// window as it stood right before the event.
public enum FeedEvent: Sendable, Hashable, Codable {
    /// Recognized text streamed in (Mac only; on iOS the app owns ASR text).
    case asrDelta(String)
    /// A confirmed write; `steps` in application order, as in ``FieldWrite``.
    case applied(UUID, origin: EditOrigin, steps: [EditStep], version: FieldVersion)
    /// A change the queue did not write.
    case foreign(EditStep, byUser: Bool, version: FieldVersion)
    case conflict(UUID, Conflict)
    /// An edit was overtaken by the same owner's newer edit `by` (a landed overlap or a coalesced tick); its
    /// source re-plans from the feed.
    case superseded(UUID, by: UUID)
    /// A pending edit was cancelled before it was written (``FieldEditQueue/withdraw(_:)``); it never lands.
    case withdrawn(UUID)
    /// The caret-relative window's edges moved (iOS: the proxy's context is length-limited) without the text
    /// changing: the window now reads `window`, and a still-visible old offset `p` is now `p + shift`.
    case rebased(window: String, shift: Int, version: FieldVersion)
    case reset(ResetReason, window: String, version: FieldVersion)

    /// The field version this event leaves, when it changes it.
    public var version: FieldVersion? {
        switch self {
        case .applied(_, _, _, let version), .foreign(_, _, let version), .rebased(_, _, let version),
            .reset(_, _, let version):
            version
        case .asrDelta, .conflict, .superseded, .withdrawn: nil
        }
    }
}

public struct FeedEntry: Sendable, Hashable, Codable {
    public var seq: Int
    public var event: FeedEvent
}

/// The feed entries after a sequence number, and the field version they leave (the `base` for new edits, sent
/// with `session` as ``EditTransaction/session``).
///
/// A `resync` batch carries no entries: the reader was older than the kept feed (or had nothing), so it drops
/// its copy of the field and starts over from `window` at `version`. Conflicts and supersedes it missed are lost;
/// it re-plans from the window.
public struct FeedBatch: Sendable, Hashable, Codable {
    public var entries: [FeedEntry]
    public var version: FieldVersion
    /// The queue instance the versions belong to.
    public var session: UUID
    public var resync: Bool
    /// The confirmed window at `version`; set on a resync.
    public var window: String?
    /// The feed's newest sequence number when the batch was cut.
    var through: Int

    public init(
        entries: [FeedEntry], version: FieldVersion, session: UUID = UUID(), resync: Bool = false,
        window: String? = nil, through: Int? = nil
    ) {
        self.entries = entries
        self.version = version
        self.session = session
        self.resync = resync
        self.window = window
        self.through = through ?? entries.last?.seq ?? 0
    }

    /// The last sequence number the batch covers; pass it to the next ``FeedLog/since(_:)``.
    public var lastSeq: Int? { entries.last?.seq ?? through }
}

/// The seq-numbered change feed (from 1, no gaps). It folds its events into the confirmed window, so a reader
/// that joins late or falls behind a ``trim(through:)`` rebuilds from a `resync` batch.
public struct FeedLog: Sendable, Hashable {
    /// The kept entries, oldest first.
    public private(set) var entries: [FeedEntry] = []
    /// The field version after the newest event that moved it.
    public private(set) var version: FieldVersion
    /// The confirmed window at `version`.
    public private(set) var window: String
    public let session: UUID
    /// The newest sequence number ever appended (0 before the first).
    public private(set) var lastSeq = 0
    /// The sequence number of the oldest kept entry (`lastSeq + 1` while none is kept).
    public private(set) var firstSeq = 1

    public init(version: FieldVersion, window: String = "", session: UUID = UUID()) {
        self.version = version
        self.window = window
        self.session = session
    }

    mutating func append(_ event: FeedEvent) {
        lastSeq += 1
        if entries.isEmpty { firstSeq = lastSeq }
        entries.append(FeedEntry(seq: lastSeq, event: event))
        if let version = event.version { self.version = version }
        switch event {
        case .applied(_, _, let steps, _): for step in steps { fold(step) }
        case .foreign(let step, _, _): fold(step)
        case .rebased(let window, _, _), .reset(_, let window, _): self.window = window
        case .asrDelta, .conflict, .superseded, .withdrawn: break
        }
    }

    private mutating func fold(_ step: EditStep) {
        guard window.units(in: step.span) != nil else { return }
        window = window.replacing(step.span, with: step.text)
    }

    /// Drops every entry up to and including `seq`; readers older than that get a `resync` batch.
    public mutating func trim(through seq: Int) {
        entries.removeAll { $0.seq <= seq }
        firstSeq = max(firstSeq, min(seq + 1, lastSeq + 1))
    }

    /// Every entry after `seq`, oldest first. A reader with nothing (`nil`), one older than the kept entries or
    /// one ahead of this feed (another instance) gets a `resync` batch with the current window instead.
    public func since(_ seq: Int?) -> FeedBatch {
        guard let seq, seq >= firstSeq - 1, seq <= lastSeq else {
            return FeedBatch(entries: [], version: version, session: session, resync: true, window: window, through: lastSeq)
        }
        return FeedBatch(entries: entries.filter { $0.seq > seq }, version: version, session: session, through: lastSeq)
    }
}
