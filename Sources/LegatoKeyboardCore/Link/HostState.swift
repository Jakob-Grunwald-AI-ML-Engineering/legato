import Foundation

public enum HostPhase: String, Codable, Sendable, Equatable {
    /// No run in progress. With a `runID` this is the final state of the run that just ended.
    case idle
    case starting
    case listening
    case finishing
}

/// A durable answer for every Start accepted into one admission, including duplicate presses.
/// Cancellation is a successful settlement: it never requires reopening the app.
public struct HostStartCompletion: Codable, Sendable, Equatable {
    public var requestIDs: [String]
    public var needsForeground: Bool

    public init(requestIDs: [String], needsForeground: Bool) {
        self.requestIDs = requestIDs
        self.needsForeground = needsForeground
    }
}

/// Where a run's text goes.
public enum HostTarget: String, Codable, Sendable, Equatable {
    /// The app's own screen (hop view or home): nothing is typed into a field.
    case app
    /// Streamed into the field of the keyboard that is on screen.
    case keyboard
}

/// How the run's cleaned text reaches the field. Mirrors the app's cleanup delivery setting; nil when cleanup is
/// off (the final text is the streamed text).
public enum HostDelivery: String, Codable, Sendable, Equatable {
    /// Stream while listening; at the end the cleaned text is swapped in for the streamed text (the cleanup agent's
    /// patches on the link), only while the field still ends with it (otherwise the app puts it on the clipboard).
    case replace
    /// Stream while listening; the cleanup agent corrects the run sentence by sentence through the link's edits.
    case live

    /// A state written by an older build may name the removed modes: "hold" and "clipboard" read as `.live`.
    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        switch raw {
        case "replace": self = .replace
        case "live", "hold", "clipboard": self = .live
        default:
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "Unknown delivery \(raw)"))
        }
    }
}

/// What the app publishes to the keyboard (`link.host`): the run's text so far and whether the app
/// is alive and can be asked to start or stop without opening it.
public struct HostState: Codable, Sendable, Equatable {
    public static let version = 1

    public var v: Int
    /// Identifies the run; nil when the app has never run one (or after a restart).
    public var runID: String?
    public var phase: HostPhase
    public var target: HostTarget
    /// Everything committed in this run so far.
    public var committed: String
    /// The tentative text after `committed`.
    public var volatile: String
    /// Increments on every publish.
    public var seq: Int
    /// Refreshed every `LinkChannel.beatInterval`, only while a run or a lease exists.
    public var beatAt: Date
    /// While the mic is held between runs: when the lease ends.
    public var leaseUntil: Date?
    /// The app can start a run from where it is, without being opened (a lease is held).
    public var acceptsRemoteStart: Bool
    /// How this run's cleaned text reaches the field (set when the run starts); nil without cleanup.
    public var delivery: HostDelivery?
    /// On the final state: the post-processed text when it differs from the trimmed `committed` text.
    public var finalText: String?
    /// Set when the user asked the app to insert this (final) text (the Live Activity's Insert button): a
    /// visible keyboard types it without having followed the run, while the request is fresh
    /// (`LinkChannel.insertMaxAge`). Nil for every other state.
    public var insertAt: Date?
    /// A meeting is recording: dictation is blocked. Absent (nil) otherwise, so older readers see the same state.
    public var meetingRecording: Bool?
    /// A keyboard start is preparing selected resources; its microphone key cancels that admission.
    /// Optional for compatibility with states written by an older host.
    public var preparingRequestID: String?
    /// Retained after preparation clears, so a keyboard need not observe a fleeting pending state.
    public var startCompletion: HostStartCompletion?
    /// On a finished run's state: what its stop has to tell the user (part of the cleanup is on the clipboard),
    /// for a keyboard that followed the run to show once. Absent from the JSON unless set.
    public var notice: String?

    public init(
        runID: String?, phase: HostPhase, target: HostTarget, committed: String, volatile: String, seq: Int,
        beatAt: Date, leaseUntil: Date?, acceptsRemoteStart: Bool, delivery: HostDelivery? = nil,
        finalText: String? = nil, insertAt: Date? = nil
    ) {
        self.v = Self.version
        self.runID = runID
        self.phase = phase
        self.target = target
        self.committed = committed
        self.volatile = volatile
        self.seq = seq
        self.beatAt = beatAt
        self.leaseUntil = leaseUntil
        self.acceptsRemoteStart = acceptsRemoteStart
        self.delivery = delivery
        self.finalText = finalText
        self.insertAt = insertAt
    }

    /// The state carries an insert request that is still recent enough to act on.
    public func insertIsFresh(now: Date) -> Bool {
        guard let insertAt else { return false }
        return now.timeIntervalSince(insertAt) <= LinkChannel.insertMaxAge
    }

    /// The run is over and this is its last state.
    public var isFinal: Bool { runID != nil && phase == .idle }

    /// Whether a keyboard may follow this state. A state that says a run is going on is only believable
    /// while the app keeps beating: an app that died mid-run leaves its last "listening" state (with the
    /// run's text) behind, and that must never be typed into a field later. An idle state is the final
    /// state of a finished run (the beat stops with the run), so its age says nothing.
    public func isLive(now: Date) -> Bool {
        phase == .idle || now.timeIntervalSince(beatAt) < LinkChannel.beatFreshness
    }

    /// What the keyboard says while the app records a meeting and dictation is blocked, instead of offering
    /// to dictate. Believed only while the app keeps beating: an app that died mid-meeting leaves the flag
    /// behind. The words are `AudioPolicy.dictationNotice` in LegatoCore, which this module cannot import.
    public func meetingNotice(now: Date) -> String? {
        guard meetingRecording == true, now.timeIntervalSince(beatAt) < LinkChannel.beatFreshness else { return nil }
        return "Meeting recording"
    }
}
