import Foundation

/// Which layout the keyboard shows.
public enum KeyboardMode: Sendable, Equatable {
    /// The typing keyboard.
    case full
    /// One row (`StripRow`): chevron, globe key (when iOS asks for it), magic, mic, undo, redo, delete, return.
    case strip
}

/// The chevron the keyboard shows to change its mode.
public enum ExpansionControl: Sendable, Equatable {
    /// Chevron up, on the strip: open the full keyboard.
    case expand
    /// Chevron down, on the full keyboard: back to the strip.
    case collapse
}

/// Stores only the last keyboard layout, as "collapsed": a missing value is the full keyboard, which is what
/// a first launch shows. UserDefaults is thread-safe.
public final class KeyboardExpansionPersistence: @unchecked Sendable {
    private let defaults: UserDefaults
    private let key = "keyboardCollapsed"

    public init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    fileprivate var collapsed: Bool {
        get { defaults.bool(forKey: key) }
        set { defaults.set(newValue, forKey: key) }
    }
}

/// Whether the keyboard is collapsed to the strip or expanded to the full keyboard. The chevron is always
/// there; the last choice is restored (initially expanded).
public struct KeyboardExpansion: Sendable, Equatable {
    private var collapsed = false
    private let persistence: KeyboardExpansionPersistence?

    public init(persistence: KeyboardExpansionPersistence? = nil) {
        self.persistence = persistence
        collapsed = persistence?.collapsed ?? false
    }

    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.collapsed == rhs.collapsed }

    public var mode: KeyboardMode { collapsed ? .strip : .full }

    public var control: ExpansionControl { collapsed ? .expand : .collapse }

    public mutating func toggle() {
        collapsed.toggle()
        persistence?.collapsed = collapsed
    }

    /// Re-reads the stored layout, which another retained keyboard controller may have changed.
    public mutating func reload() {
        if let persistence { collapsed = persistence.collapsed }
    }
}

/// The strip's height, in points, for the height experiment: which values are tried and how to step through them.
public enum StripHeight {
    /// 0 and 1 may leave nothing to touch; the debug picker in the app chooses the height a session starts with.
    public static let candidates: [Double] = [0, 1, 30, 54]
    public static let standard: Double = 54

    /// The candidate after `height`, wrapping around; the first one for a height that is not a candidate.
    public static func next(after height: Double) -> Double {
        guard let index = candidates.firstIndex(of: height) else { return candidates[0] }
        return candidates[(index + 1) % candidates.count]
    }

    /// The height to request from the system for a strip row of `row` points: the word row goes above it.
    /// The debug heights that leave nothing to touch (0 and 1) stay as they are.
    public static func keyRowHeight(row: Double, landscape: Bool) -> Double {
        row == standard && landscape ? 37.33 : row
    }

    public static func requested(row: Double, landscape: Bool = false) -> Double {
        row >= 30 ? keyRowHeight(row: row, landscape: landscape) + WordRowHeight.content(landscape: landscape) : row
    }

    /// The stored starting height when it is a candidate, the standard one otherwise.
    public static func resolve(stored: Double?) -> Double {
        guard let stored, candidates.contains(stored) else { return standard }
        return stored
    }
}
