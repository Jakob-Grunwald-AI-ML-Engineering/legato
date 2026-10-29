import Foundation

/// Which layout the keyboard shows.
public enum KeyboardMode: Sendable, Equatable {
    /// The typing keyboard.
    case full
    /// One row (`StripRow`): chevron, globe key (when iOS asks for it), hotkeys (undo, redo, Refine), delete, return, mic key. The "Compact keyboard" setting.
    case strip
}

/// The chevron the keyboard shows to change its mode.
public enum ExpansionControl: Sendable, Equatable {
    /// Chevron up, on the strip: open the full keyboard.
    case expand
    /// Chevron down, on the full keyboard of a strip session: back to the strip.
    case collapse
}

/// Stores only the last keyboard layout. UserDefaults is thread-safe.
public final class KeyboardExpansionPersistence: @unchecked Sendable {
    private let defaults: UserDefaults
    private let key = "keyboardExpanded"

    public init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    fileprivate var expanded: Bool {
        get { defaults.bool(forKey: key) }
        set { defaults.set(newValue, forKey: key) }
    }
}

/// Whether the keyboard is collapsed to the strip or expanded. With the strip setting on, restores
/// the last choice (initially collapsed); with it off the keyboard is always full and has no control.
public struct KeyboardExpansion: Sendable, Equatable {
    public private(set) var stripEnabled: Bool
    private var expanded = false
    private let persistence: KeyboardExpansionPersistence?

    public init(stripEnabled: Bool, persistence: KeyboardExpansionPersistence? = nil) {
        self.stripEnabled = stripEnabled
        self.persistence = persistence
        expanded = stripEnabled && (persistence?.expanded ?? false)
        if !stripEnabled { persistence?.expanded = false }
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.stripEnabled == rhs.stripEnabled && lhs.expanded == rhs.expanded
    }

    public var mode: KeyboardMode { stripEnabled && !expanded ? .strip : .full }

    public var control: ExpansionControl? {
        guard stripEnabled else { return nil }
        return expanded ? .collapse : .expand
    }

    public mutating func toggle() {
        guard stripEnabled else { return }
        expanded.toggle()
        persistence?.expanded = expanded
    }

    /// The least vertical travel, in points, that counts as a swipe.
    public static let swipeDistance = 16.0

    /// Whether a drag (screen points, y down) on the strip or the full keyboard's top bar toggles: up on the
    /// strip expands, down on the full keyboard collapses; it must be long enough and more vertical than not.
    public func swipeToggles(dx: Double, dy: Double) -> Bool {
        guard let control, abs(dy) >= Self.swipeDistance, abs(dy) > abs(dx) else { return false }
        return control == .expand ? dy < 0 : dy > 0
    }

    /// The setting as the app last stored it. A change starts a new session (collapsed); the same value
    /// reloads the global last choice, including choices made by another retained keyboard controller.
    public mutating func setStripEnabled(_ enabled: Bool) {
        guard enabled != stripEnabled else {
            if enabled, let persistence { expanded = persistence.expanded }
            return
        }
        stripEnabled = enabled
        expanded = false
        persistence?.expanded = false
    }
}

/// The strip's height, in points, for the height experiment: which values are tried and how to step through them.
public enum StripHeight {
    /// 0 and 1 may leave nothing to touch; the debug picker in the app chooses the height a session starts with.
    public static let candidates: [Double] = [0, 1, 30, 44, 56]
    public static let standard: Double = 44

    /// The candidate after `height`, wrapping around; the first one for a height that is not a candidate.
    public static func next(after height: Double) -> Double {
        guard let index = candidates.firstIndex(of: height) else { return candidates[0] }
        return candidates[(index + 1) % candidates.count]
    }

    /// The height to request from the system for a strip row of `row` points: the word row goes above it.
    /// The debug heights that leave nothing to touch (0 and 1) stay as they are.
    public static func requested(row: Double) -> Double {
        row >= 30 ? row + WordRowHeight.strip : row
    }

    /// The stored starting height when it is a candidate, the standard one otherwise.
    public static func resolve(stored: Double?) -> Double {
        guard let stored, candidates.contains(stored) else { return standard }
        return stored
    }
}
