import Foundation

public struct ShiftState: Sendable, Equatable {
    public enum Mode: Sendable, Equatable { case off, once, capsLock }

    public static let doubleTapWindow: TimeInterval = 0.3

    public private(set) var mode: Mode = .off
    private var lastTapAt: Date?
    private var fromAutoCapitalization = false

    public init() {}

    public var isUppercase: Bool { mode != .off }

    public mutating func tapShift(at now: Date) {
        fromAutoCapitalization = false
        switch mode {
        case .off:
            mode = .once
            lastTapAt = now
        case .once:
            if let last = lastTapAt, now.timeIntervalSince(last) <= Self.doubleTapWindow {
                mode = .capsLock
            } else {
                mode = .off
            }
            lastTapAt = nil
        case .capsLock:
            mode = .off
            lastTapAt = nil
        }
    }

    /// A letter was typed: a one-shot shift is used up.
    public mutating func didTypeLetter() {
        lastTapAt = nil
        fromAutoCapitalization = false
        if mode == .once { mode = .off }
    }

    /// Sync with `AutoCapitalizer`. Caps lock and a shift the user tapped are left alone when it says no.
    public mutating func applyAutoCapitalization(_ capitalize: Bool) {
        switch (mode, capitalize) {
        case (.off, true):
            mode = .once
            fromAutoCapitalization = true
            lastTapAt = nil
        case (.once, false) where fromAutoCapitalization:
            mode = .off
            fromAutoCapitalization = false
        default:
            break
        }
    }
}
