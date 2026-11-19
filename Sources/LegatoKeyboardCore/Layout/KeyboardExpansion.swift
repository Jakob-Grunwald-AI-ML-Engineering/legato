import Foundation

/// Which layout the keyboard shows.
public enum KeyboardMode: Sendable, Equatable {
    /// The typing keyboard: the top row (dictation key and transcript) above the key grid.
    case full
    /// Two rows of keys beside the transcript (`TopRowLayout`): the dictation key, then delete and return (and the globe key
    /// when iOS asks for it).
    case minimised
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

/// Whether the keyboard is minimised or full. The dictation key's swipes change it; the last choice is restored (initially
/// full).
public struct KeyboardExpansion: Sendable, Equatable {
    private var collapsed = false
    private let persistence: KeyboardExpansionPersistence?

    public init(persistence: KeyboardExpansionPersistence? = nil) {
        self.persistence = persistence
        collapsed = persistence?.collapsed ?? false
    }

    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.collapsed == rhs.collapsed }

    public var mode: KeyboardMode { collapsed ? .minimised : .full }

    public mutating func toggle() {
        collapsed.toggle()
        persistence?.collapsed = collapsed
    }

    /// Re-reads the stored layout, which another retained keyboard controller may have changed.
    public mutating func reload() {
        if let persistence { collapsed = persistence.collapsed }
    }
}
