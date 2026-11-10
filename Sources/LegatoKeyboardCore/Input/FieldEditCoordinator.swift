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
        uncertain = !verified && current.phase != .prepared
        if verified && current.owner == .read { uncertain = false }
        completed.append(lease.id)
        if completed.count > 128 { completed.removeFirst(completed.count - 128) }
        if current.phase != .prepared, current.owner != .read || !verified { revision.revision &+= 1 }
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
            if current.phase == .issued { uncertain = true }
        }
        transaction = nil; revision.revision &+= 1
        // After an explicit user edit, equal text cannot safely be attributed to an earlier automated write.
        recentPredictions = []
    }
}
