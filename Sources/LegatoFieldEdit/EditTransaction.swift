import Foundation

/// Who an edit comes from. User origins taint the owned text they touch and are never held back.
public enum EditOrigin: String, Sendable, Hashable, Codable, CaseIterable {
    case keystroke, asr, hold, liveCleanup, finalSwap, versions, wordRow, history, agent, tool

    /// A choice the user made: a keystroke, a word-row pick, undo/redo, a version pick.
    public var isUser: Bool {
        switch self {
        case .keystroke, .versions, .wordRow, .history: true
        case .asr, .hold, .liveCleanup, .finalSwap, .agent, .tool: false
        }
    }

    /// The lane an edit from this origin runs in unless the source names one.
    public var lane: Lane {
        if isUser { return .user }
        return self == .asr || self == .hold ? .asr : .cleanup
    }

    /// Where an insertion point of this origin goes when foreign text lands exactly there: before it, except ASR,
    /// which only appends at its run end and binds after.
    public var insertBias: Bias { self == .asr ? .after : .before }
}

/// Queue priority: the user lane preempts everything queued, then ASR, then cleanup and the agent.
public enum Lane: Int, Sendable, Hashable, Codable, Comparable {
    case cleanup, asr, user

    public static func < (a: Lane, b: Lane) -> Bool { a.rawValue < b.rawValue }
}

/// One source's edit: steps against `base`, landed together or not at all.
public struct EditTransaction: Sendable, Hashable, Identifiable, Codable {
    public var id: UUID
    public var origin: EditOrigin
    /// The run or agent the written text belongs to; nil for the user.
    public var owner: String?
    public var base: FieldVersion
    /// Non-overlapping steps, all against `base` (not against each other).
    public var steps: [EditStep]
    /// The caret after the write, in the field after these steps; nil keeps the user's caret where it was.
    public var caret: Int?
    /// Pending transactions with the same key coalesce: the newest wins (typewriter ticks per run).
    public var coalesce: String?

    public init(
        id: UUID = UUID(), origin: EditOrigin, owner: String? = nil, base: FieldVersion, steps: [EditStep],
        caret: Int? = nil, coalesce: String? = nil
    ) {
        self.id = id
        self.origin = origin
        self.owner = owner
        self.base = base
        self.steps = steps
        self.caret = caret
        self.coalesce = coalesce
    }
}

/// The one write the executor runs next: `steps` in application order (highest location first, so each span is
/// valid when it runs), then the caret to `caret`. `version` is the field version once it has landed.
public struct FieldWrite: Sendable, Hashable {
    public var id: UUID
    public var origin: EditOrigin
    public var lane: Lane
    public var steps: [EditStep]
    public var caret: Int
    public var version: FieldVersion
}
