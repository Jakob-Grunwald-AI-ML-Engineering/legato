import Foundation

/// Whether the recording island is the small pill or the full card with Stop, and when it goes back.
///
/// It starts expanded for ``startHold`` seconds when a meeting starts, expands when the user clicks the pill (and goes
/// back after ``idleHold`` seconds, or on a click outside), and expands for ``attentionHold`` seconds when something must
/// not be missed (a warning, a refused hotkey). A later expansion never shortens an earlier one. Times are seconds on any
/// monotonic clock; the owner calls ``tick(at:)`` while it is expanded.
public struct IslandExpansion: Sendable, Equatable {
    public static let startHold: TimeInterval = 3
    public static let idleHold: TimeInterval = 6
    public static let attentionHold: TimeInterval = 6

    public private(set) var isExpanded = false
    private var collapseAt: TimeInterval?

    public init() {}

    public mutating func recordingStarted(at now: TimeInterval) { expand(until: now + Self.startHold) }

    /// A click on the pill.
    public mutating func clicked(at now: TimeInterval) { expand(until: now + Self.idleHold) }

    /// Something to read: stays open at least ``attentionHold`` seconds from now.
    public mutating func attention(at now: TimeInterval) { expand(until: now + Self.attentionHold) }

    /// A click anywhere else.
    public mutating func clickedOutside() { collapse() }

    public mutating func tick(at now: TimeInterval) {
        if isExpanded, let collapseAt, now >= collapseAt { collapse() }
    }

    /// The meeting ended: back to the resting state.
    public mutating func reset() { collapse() }

    private mutating func expand(until time: TimeInterval) {
        isExpanded = true
        collapseAt = max(collapseAt ?? time, time)
    }

    private mutating func collapse() {
        isExpanded = false
        collapseAt = nil
    }
}
