import Foundation

/// The contract between the app and the keyboard extension: the App Group, the keys, the Darwin
/// notification names and the timing constants. Every JSON value lives under a `link.*` key; every
/// Darwin note carries no payload (readers always re-read the key).
public enum LinkChannel {
    public static let appGroupID = "group.de.gruenwald.legato"

    /// App Group `UserDefaults` keys.
    public enum Key {
        /// app -> keyboard: `HostState`.
        public static let host = "link.host"
        /// keyboard -> app: `KeyboardRequest`.
        public static let request = "link.request"
        /// app -> keyboard: `KeyboardAck`.
        public static let ack = "link.ack"
        /// keyboard -> app: `KeyboardPresence`.
        public static let presence = "link.presence"
        /// keyboard -> app: `AppliedCursor`.
        public static let applied = "link.applied"
    }

    /// Darwin notification names, one per key.
    public enum Note {
        public static let host = "de.gruenwald.legato.link.host"
        public static let request = "de.gruenwald.legato.link.request"
        public static let ack = "de.gruenwald.legato.link.ack"
        public static let presence = "de.gruenwald.legato.link.presence"
        public static let applied = "de.gruenwald.legato.link.applied"
    }

    /// The host refreshes `beatAt` this often, only while a run or a lease exists.
    public static let beatInterval: TimeInterval = 1
    /// A beat older than this means the app is not alive for the keyboard.
    public static let beatFreshness: TimeInterval = 2.5
    /// The keyboard refreshes its presence this often while visible.
    public static let presenceInterval: TimeInterval = 1
    /// A presence older than this means the keyboard is not on screen.
    public static let presenceFreshness: TimeInterval = 2
    /// No ack within this long: the keyboard falls back to opening the app.
    public static let ackTimeout: TimeInterval = 0.6
    /// The host publishes state changes at most this often (phase changes go out immediately).
    public static let minPublishInterval: TimeInterval = 0.1
    /// A request older than this is ignored (a leftover in the inbox).
    public static let requestMaxAge: TimeInterval = 10
}
