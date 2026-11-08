import Foundation

/// The contract between the app and the keyboard extension: the App Group, the keys, the Darwin
/// notification names and the timing constants. Every JSON value lives under a `link.*` key; every
/// Darwin note carries no payload (readers always re-read the key).
public enum LinkChannel {
    public static let appGroupID = RuntimeIdentity.current.appGroupID

    /// App Group `UserDefaults` keys.
    public enum Key {
        public static let composer = "link.composer"
        public static let composerAck = "link.composer.ack"
        public static let composerIntentPrefix = "link.composer.intent."
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
        /// app -> keyboard: `DictationPublication`.
        public static let dictation = "link.dictation"
        /// keyboard -> app: `DictationAck`.
        public static let dictationAck = "link.dictation.ack"
        /// app -> keyboard: `LiveDictationSnapshot` (the live send mode's run target).
        public static let dictationLive = "link.dictation.live"
        /// keyboard -> app: `LiveDictationAck`.
        public static let dictationLiveAck = "link.dictation.live.ack"
        /// app -> keyboard: `InstructionStrip` (instruction mode's strip).
        public static let instruction = "link.instruction"
        /// keyboard -> app: one `InstructionIntent` per tap, `link.instruction.intent.<uuid>` (the app removes each once read).
        public static let instructionIntentPrefix = "link.instruction.intent."
        /// app -> keyboard: `FieldReadRequest` (the keyboard removes it once read).
        public static let read = "link.read"
        /// keyboard -> app: `FieldReadReply` (the app removes a finished one once read).
        public static let readAck = "link.read.ack"
        /// app -> keyboard: `ScopedEdit` (an instruction's result or its undo; the keyboard removes it once read).
        public static let instructionEdit = "link.instruction.edit"
        /// keyboard -> app: `ScopedEditAck`.
        public static let instructionEditAck = "link.instruction.edit.ack"
    }

    /// Darwin notification names, one per key.
    public enum Note {
        public static let composer = "\(RuntimeIdentity.current.notificationNamespace).link.composer"
        public static let composerIntent = "\(RuntimeIdentity.current.notificationNamespace).link.composer.intent"
        public static let host = "\(RuntimeIdentity.current.notificationNamespace).link.host"
        public static let request = "\(RuntimeIdentity.current.notificationNamespace).link.request"
        public static let ack = "\(RuntimeIdentity.current.notificationNamespace).link.ack"
        public static let presence = "\(RuntimeIdentity.current.notificationNamespace).link.presence"
        public static let applied = "\(RuntimeIdentity.current.notificationNamespace).link.applied"
        public static let refine = "\(RuntimeIdentity.current.notificationNamespace).link.refine"
        public static let refined = "\(RuntimeIdentity.current.notificationNamespace).link.refined"
        public static let choice = "\(RuntimeIdentity.current.notificationNamespace).link.choice"
        public static let dictation = "\(RuntimeIdentity.current.notificationNamespace).link.dictation"
        public static let dictationAck = "\(RuntimeIdentity.current.notificationNamespace).link.dictation.ack"
        public static let dictationLive = "\(RuntimeIdentity.current.notificationNamespace).link.dictation.live"
        public static let dictationLiveAck = "\(RuntimeIdentity.current.notificationNamespace).link.dictation.live.ack"
        public static let instruction = "\(RuntimeIdentity.current.notificationNamespace).link.instruction"
        public static let instructionIntent = "\(RuntimeIdentity.current.notificationNamespace).link.instruction.intent"
        public static let read = "\(RuntimeIdentity.current.notificationNamespace).link.read"
        public static let readAck = "\(RuntimeIdentity.current.notificationNamespace).link.read.ack"
        public static let instructionEdit = "\(RuntimeIdentity.current.notificationNamespace).link.instruction.edit"
        public static let instructionEditAck = "\(RuntimeIdentity.current.notificationNamespace).link.instruction.edit.ack"
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
    /// How long the app waits for the keyboard's first answer to a field read (`reading` or the result).
    public static let readAckTimeout: TimeInterval = 1.5
    /// How long a field read that walks may take (a long field costs about 1.5 ms per character).
    public static let readTimeout: TimeInterval = 15
    /// How long the app waits for the keyboard to land an instruction's edit.
    public static let editTimeout: TimeInterval = 4
}
