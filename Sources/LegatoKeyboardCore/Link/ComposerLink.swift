import Foundation
import LegatoComposerDoc

public struct ComposerPublication: Codable, Equatable, Sendable {
    public var snapshot: DocumentSnapshot
    public var hunks: [AnimationHunk]
    public var requiresSnapshot: Bool
    public var sessionID: String?
    public var tail = ""
    /// Advances only after validated dictation is appended, never on an agent rewrite.
    public var dictationRevision: Int?
    public var mode = "message"
    public var status = "idle"
    public var error: String?
    public var pendingLineIDs: Set<String> = []
    public var busy = false
    /// nil decodes legacy publications written before voice mute was available.
    public var correctionDraft: String?
    public var correctionSubmitting: Bool?
    public var correctionCountdownStart: Double?
    public var correctionCountdownDeadline: Double?
    public var muted: Bool?
    public var inputMode: String?
    public var instructionDraft: String?
    public var instructionStatus: String?
    /// The last keyboard insertion consumed by the host (including a stale-session rejection).
    public var insertedIntentID: String?
    public init(snapshot: DocumentSnapshot = .init(revision: 0, lines: []), hunks: [AnimationHunk] = [], requiresSnapshot: Bool = false) {
        self.snapshot = snapshot; self.hunks = hunks; self.requiresSnapshot = requiresSnapshot
    }
}

/// Every value contains the current snapshot and all animation hunks since the acknowledged revision.
/// The snapshot makes missed notifications and bounded history recovery deterministic.
public struct ComposerLinkHistory: Sendable {
    private var current = DocumentSnapshot(revision: 0, lines: [])
    private var revisions: [(Int, [AnimationHunk])] = []
    public init() {}
    public mutating func record(_ snapshot: DocumentSnapshot, hunks: [AnimationHunk]) {
        current = snapshot; revisions.append((snapshot.revision, hunks))
        if revisions.count > 100 { revisions.removeFirst(revisions.count - 100) }
    }
    public func publication(acknowledged: Int) -> ComposerPublication {
        let oldest = revisions.first?.0 ?? current.revision + 1
        let gap = acknowledged < oldest - 1 || acknowledged > current.revision
        return .init(snapshot: current, hunks: gap ? [] : revisions.filter { $0.0 > acknowledged }.flatMap { $0.1 }, requiresSnapshot: gap)
    }
}

public struct ComposerIntent: Codable, Equatable, Sendable {
    public var id: String
    public var action: String
    public var lineID: String?
    public var wordID: String?
    public var text: String?
    public var endLineID: String?
    public var endWordID: String?
    public var sessionID: String?
    public var timestamp: Double
    public init(action: String, lineID: String? = nil, wordID: String? = nil, endLineID: String? = nil, endWordID: String? = nil, text: String? = nil, sessionID: String? = nil) {
        id = UUID().uuidString; self.action = action; self.lineID = lineID; self.wordID = wordID; self.text = text
        self.endLineID = endLineID; self.endWordID = endWordID
        self.sessionID = sessionID
        timestamp = ProcessInfo.processInfo.systemUptime
    }


}

public struct ComposerLink: Sendable {
    public let store: LinkStore
    public init(store: LinkStore) { self.store = store }
    public func publish(_ value: ComposerPublication) { store.write(value, forKey: LinkChannel.Key.composer) }
    public func read() -> ComposerPublication? { store.read(ComposerPublication.self, forKey: LinkChannel.Key.composer) }
    public func acknowledge(_ revision: Int) { store.write(revision, forKey: LinkChannel.Key.composerAck) }
    public var acknowledged: Int { store.read(Int.self, forKey: LinkChannel.Key.composerAck) ?? 0 }
    public func send(_ intent: ComposerIntent) { store.write(intent, forKey: LinkChannel.Key.composerIntentPrefix + intent.id) }
    public func drainIntents() -> [ComposerIntent] {
        store.keys(withPrefix: LinkChannel.Key.composerIntentPrefix).compactMap { key in
            defer { store.remove(forKey: key) }
            return store.read(ComposerIntent.self, forKey: key)
        }.sorted { $0.timestamp < $1.timestamp }
    }
}
