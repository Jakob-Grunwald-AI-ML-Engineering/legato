import Foundation

/// Shared ordered field-operation barrier used by both platforms.
public struct FieldEditCoordinator: Sendable {}

public extension FieldEditCoordinator {
    /// Explicit product responsiveness target for typing, cursor movement and resumed speech.
    /// This is a requirement, not a measured host latency or a cleanup completion deadline.
    static let inputResponseTargetMs = 500.0

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
