import Foundation

public enum DeleteAction: Sendable, Equatable { case character, word }

/// Key-repeat schedule for a held delete key. The caller deletes once on touch-down, then calls `tick`
/// from a timer; the clock is whatever `Date` it passes in.
public struct DeleteRepeater: Sendable {
    public static let firstRepeatMs = 500
    public static let intervalMs = 100
    public static let wordWiseMs = 1500

    private var heldSince: Date?
    private var emitted = 0

    public init() {}

    public var isActive: Bool { heldSince != nil }

    public mutating func begin(at now: Date) {
        heldSince = now
        emitted = 0
    }

    public mutating func end() {
        heldSince = nil
        emitted = 0
    }

    /// The deletes that became due since the last tick, in order.
    public mutating func tick(at now: Date) -> [DeleteAction] {
        guard let start = heldSince else { return [] }
        let elapsed = Int((now.timeIntervalSince(start) * 1000).rounded())
        var actions: [DeleteAction] = []
        while true {
            let due = Self.firstRepeatMs + emitted * Self.intervalMs
            guard due <= elapsed else { break }
            actions.append(due >= Self.wordWiseMs ? .word : .character)
            emitted += 1
        }
        return actions
    }
}
