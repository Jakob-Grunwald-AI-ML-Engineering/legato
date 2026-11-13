import Foundation

/// A revision belongs to one appearance of one field. Cursor walks owned by the coordinator do not revise its text.
public struct FieldRevision: Codable, Sendable, Equatable {
    public var generation: String
    public var revision: UInt64
    public init(generation: String, revision: UInt64) { self.generation = generation; self.revision = revision }
}

/// Serial ownership and reconciliation shared by the proxy keyboard and Accessibility editor.
/// Observations are bounded windows, never an assertion that the entire document is known.
public struct FieldEditCoordinator: Sendable {
    public struct Window: Sendable, Equatable {
        public var documentID: String?
        public var before: String
        public var after: String
        public var selection: String?
        public var startsDocument: Bool
        public var endsDocument: Bool
        public init(documentID: String?, before: String, after: String, selection: String? = nil,
                    startsDocument: Bool = false, endsDocument: Bool = false) {
            self.documentID = documentID; self.before = before; self.after = after; self.selection = selection
            self.startsDocument = startsDocument; self.endsDocument = endsDocument
        }
    }
    public enum Owner: String, Sendable { case read, instruction, dictation, typing }
    public enum Phase: String, Sendable { case prepared, issued, observed, settled, uncertain, cancelled }
    public enum Observation: String, Sendable { case unchanged, owned, staleOwnEcho, external, newField }
    public struct Lease: Sendable, Equatable {
        public let id: String
        public let revision: FieldRevision
    }
    public struct Transaction: Sendable {
        public let lease: Lease
        public let owner: Owner
        public fileprivate(set) var phase: Phase
        public fileprivate(set) var desired: Window?
        public fileprivate(set) var predicted: Window?
        public fileprivate(set) var hasIssued = false
    }
    public private(set) var revision = FieldRevision(generation: UUID().uuidString, revision: 0)
    public private(set) var observed: Window?
    public private(set) var transaction: Transaction?
    public private(set) var uncertain = false
    public private(set) var lastObservation: Observation = .unchanged
    /// Previous predictions distinguish late own echoes from a new external edit. No unobserved region is inferred.
    public private(set) var recentPredictions: [Window] = []
    private var completed: [String] = []
    public init() {}

    /// Reconcile an unsolicited host report. During a lease, intermediate/late echoes belong to its owner.
    @discardableResult public mutating func observe(_ window: Window) -> FieldRevision {
        if observed?.documentID != window.documentID {
            transaction = nil; uncertain = false; completed = []
            recentPredictions = []; lastObservation = .newField
            revision = FieldRevision(generation: UUID().uuidString, revision: 0)
        } else if observed == window {
            lastObservation = .unchanged
        } else if transaction != nil {
            // Only the active owner can interpret an intermediate report. Merely observing it never confirms it.
            lastObservation = .owned
        } else if recentPredictions.contains(window) {
            // An exact intermediate echo is causally ambiguous after settlement. Do not invent an external text
            // revision, or overwrite this report with the desired text; require reconciliation before automation.
            lastObservation = .staleOwnEcho
            uncertain = true
        } else {
            lastObservation = .external
            recentPredictions = []
            revision.revision &+= 1
        }
        observed = window
        return revision
    }
    /// Duplicate IDs and stale generations can never issue another edit. An uncertain write requires a fresh read.
    public mutating func begin(owner: Owner, id: String, expectedRevision: FieldRevision? = nil) -> Lease? {
        guard transaction == nil, !completed.contains(id), owner == .read || !uncertain,
              expectedRevision == nil || expectedRevision == revision else { return nil }
        let lease = Lease(id: id, revision: revision)
        if owner == .typing { recentPredictions = [] }
        transaction = Transaction(lease: lease, owner: owner, phase: .prepared, desired: nil, predicted: nil)
        return lease
    }
    public func owns(_ lease: Lease) -> Bool { transaction?.lease == lease }
    /// Called before the host mutation; desired and predicted text must never overwrite observed text.
    @discardableResult public mutating func issued(_ lease: Lease, desired: Window? = nil, predicted: Window? = nil) -> Bool {
        guard owns(lease) else { return false }
        transaction?.hasIssued = true
        transaction?.phase = .issued
        if let desired { transaction?.desired = desired }
        transaction?.predicted = predicted
        if let predicted {
            recentPredictions.append(predicted)
            if recentPredictions.count > 64 { recentPredictions.removeFirst() }
        }
        return true
    }
    @discardableResult public mutating func confirm(_ lease: Lease, window: Window) -> Bool {
        guard owns(lease), observed?.documentID == window.documentID else { return false }
        if let predicted = transaction?.predicted {
            guard Self.matches(predicted, window) else { observed = window; return false }
        }
        observed = window; transaction?.phase = .observed
        return true
    }
    /// Only a verified final host report settles an edit; a timeout retains uncertainty and prohibits automatic retries.
    public mutating func finish(_ lease: Lease, settled: Bool) {
        guard owns(lease), let current = transaction else { return }
        let verified = settled && (current.phase == .observed || current.phase == .prepared)
        uncertain = !verified && current.hasIssued
        if verified && current.owner == .read { uncertain = false }
        completed.append(lease.id)
        if completed.count > 128 { completed.removeFirst(completed.count - 128) }
        if current.hasIssued, current.owner != .read || !verified { revision.revision &+= 1 }
        transaction = nil
    }
    private static func matches(_ predicted: Window, _ actual: Window) -> Bool {
        guard predicted.documentID == actual.documentID, predicted.selection == actual.selection else { return false }
        // A host may expose a shorter window. Only overlap is known; an empty expected side needs an empty report.
        func side(_ expected: String, _ shown: String, end: Bool, complete: Bool) -> Bool {
            if expected.isEmpty { return !complete || shown.isEmpty }
            if shown.isEmpty { return false }
            return end ? (expected.hasSuffix(shown) || shown.hasSuffix(expected))
                       : (expected.hasPrefix(shown) || shown.hasPrefix(expected))
        }
        return side(predicted.before, actual.before, end: true, complete: predicted.startsDocument)
            && side(predicted.after, actual.after, end: false, complete: predicted.endsDocument)
    }
    /// User input cancels outstanding automation before it touches the field.
    public mutating func preempt() {
        if let current = transaction {
            completed.append(current.lease.id)
            if current.hasIssued { uncertain = true }
        }
        transaction = nil; revision.revision &+= 1
        // After an explicit user edit, equal text cannot safely be attributed to an earlier automated write.
        recentPredictions = []
    }
}


public extension FieldEditCoordinator {
    /// Shared ordered operation barrier used by both platform queues. Region placement stays in the adapter,
    /// because a proxy exposes bounded windows while Accessibility exposes absolute ranges.
    struct Operations: Sendable, Equatable {
        public enum Kind: Sendable, Equatable { case move, edit, read }
        public struct Transaction: Sendable, Equatable {
            public let sequence: UInt64
            public let kind: Kind
            public fileprivate(set) var ageMs: Double = 0
            public let settleMs: Double
            public let transitMs: Double
            public fileprivate(set) var hasIssued = false
        }
        public private(set) var current: Transaction?
        public private(set) var revision: UInt64 = 0
        private var sequence: UInt64 = 0
        private var drainMs = 0.0

        public init() {}
        public var available: Bool { current == nil && drainMs <= 0 }
        public var ageMs: Double { current?.ageMs ?? 0 }
        public var settled: Bool { current.map { $0.ageMs >= $0.settleMs } ?? false }

        public mutating func advance(_ elapsedMs: Double) {
            let elapsed = max(0, elapsedMs)
            current?.ageMs += elapsed
            drainMs = max(0, drainMs - elapsed)
        }

        /// Starts exactly one ordered transaction. A failed acquisition changes no state.
        @discardableResult public mutating func begin(_ kind: Kind, settleMs: Double = 0, transitMs: Double = 0) -> Bool {
            guard available else { return false }
            sequence &+= 1
            current = Transaction(sequence: sequence, kind: kind, settleMs: max(0, settleMs), transitMs: max(0, transitMs))
            return true
        }

        /// Called by the adapter after dispatch, so time spent planning cannot count as time in the host.
        public mutating func dispatched() { current?.ageMs = 0; current?.hasIssued = true }

        /// Independent readback is supplied by the adapter. Even a matching optimistic report waits for settlement.
        @discardableResult public mutating func confirm(matches: Bool) -> Bool {
            guard matches, settled, current?.hasIssued == true, current?.kind != .read else { return false }
            current = nil
            revision &+= 1
            return true
        }

        /// An uncertain operation is never treated as a successful write. Its remaining transit drains before another
        /// transaction (including a read's caret probe) starts. The adapter then replans against what is actually read.
        public mutating func invalidate() {
            if let current, current.hasIssued { drainMs = max(drainMs, current.transitMs - current.ageMs) }
            current = nil
        }

        public mutating func finishRead() {
            guard current?.kind == .read else { return }
            current = nil
        }

    }

    /// Exact minimal desktop plan; unchanged characters never become a cheaper block rewrite.
    static func changes(from old: [Character], to new: [Character]) -> [ShadowEditPlanner.Change] {
        ShadowEditPlanner.changes(from: old, to: new)
    }
}
