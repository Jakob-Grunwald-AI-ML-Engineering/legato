import Foundation

/// The contract between the app and the keyboard extension: the App Group, the keys, the Darwin
/// notification names and the timing constants. Every JSON value lives under a `link.*` key; every
/// Darwin note carries no payload (readers always re-read the key).
public enum LinkChannel {
    public static let appGroupID = RuntimeIdentity.current.appGroupID

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
        /// keyboard -> app: `RefineRequest` (the app acks it on `ack`, and removes it once read).
        public static let refine = "link.refine"
        /// app -> keyboard: `RefineReply` (the keyboard removes it once read).
        public static let refined = "link.refined"
        /// keyboard -> app: one `ChoiceRecord` per key, `link.choice.<uuid>` (the app removes each once read).
        public static let choicePrefix = "link.choice."
        /// keyboard -> app: the field-event ring (`FeedRing`), only for runs with `HostState.fieldEdits`.
        public static let feed = "link.feed"
        /// app -> keyboard: pending `EditTransaction`s (`EditsBox`).
        public static let edits = "link.edits"
        /// keyboard -> app: how far the keyboard has taken `edits` (`EditsAck`).
        public static let editsAck = "link.edits.ack"
    }

    /// Darwin notification names, one per key.
    public enum Note {
        public static let host = "\(RuntimeIdentity.current.notificationNamespace).link.host"
        public static let request = "\(RuntimeIdentity.current.notificationNamespace).link.request"
        public static let ack = "\(RuntimeIdentity.current.notificationNamespace).link.ack"
        public static let presence = "\(RuntimeIdentity.current.notificationNamespace).link.presence"
        public static let applied = "\(RuntimeIdentity.current.notificationNamespace).link.applied"
        public static let refine = "\(RuntimeIdentity.current.notificationNamespace).link.refine"
        public static let refined = "\(RuntimeIdentity.current.notificationNamespace).link.refined"
        public static let choice = "\(RuntimeIdentity.current.notificationNamespace).link.choice"
        public static let feed = "\(RuntimeIdentity.current.notificationNamespace).link.feed"
        public static let edits = "\(RuntimeIdentity.current.notificationNamespace).link.edits"
    }

    /// How many feed batches (and unacknowledged edits) the App Group keeps; a reader further behind resyncs.
    public static let feedCapacity = 256
    /// The feed ring's encoded size stays under this; older batches are dropped first.
    public static let feedMaxBytes = 64 * 1024

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
    /// How long a finished run's text stays in `link.host` and `link.applied`, so a keyboard that was away
    /// for a moment can still apply and confirm the final state. Then the text is removed from the link.
    public static let finalTextRetention: TimeInterval = 5
    /// A keyboard acts on an insert request (`HostState.insertAt`) only this long after it was made, so a
    /// keyboard that appears later does not type text the user asked for minutes ago.
    public static let insertMaxAge: TimeInterval = 10
    /// A request older than this is ignored (a leftover in the inbox).
    public static let requestMaxAge: TimeInterval = 10
    /// A choice record older than this is dropped unread (the app was away for a week).
    public static let choiceMaxAge: TimeInterval = 7 * 24 * 3600
    /// How long the keyboard waits for a refined text once the app acked the request (a language model
    /// that loads cold takes a while).
    public static let refineTimeout: TimeInterval = 20
}
