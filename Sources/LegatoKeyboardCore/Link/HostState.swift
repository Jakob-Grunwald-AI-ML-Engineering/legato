import Foundation

public enum HostPhase: String, Codable, Sendable, Equatable {
    /// No run in progress. With a `runID` this is the final state of the run that just ended.
    case idle
    case starting
    case listening
    case finishing
}

/// Where a run's text goes.
public enum HostTarget: String, Codable, Sendable, Equatable {
    /// The app's own screen (hop view or home): nothing is typed into a field.
    case app
    /// Streamed into the field of the keyboard that is on screen.
    case keyboard
}

/// How the run's text reaches the field when post-processing (cleanup) changed it. Mirrors the app's
/// cleanup delivery setting; nil when cleanup is off (the final text is the streamed text).
public enum HostDelivery: String, Codable, Sendable, Equatable {
    /// Stream while listening; at the end swap the streamed text for `finalText` in one edit, when the
    /// field still ends with it (otherwise the app puts `finalText` on the clipboard).
    case replace
    /// Stream while listening; the field keeps the streamed text, the app puts `finalText` on the clipboard.
    case clipboard
    /// Type nothing while listening; insert the final text (`finalText`, else the committed text) at the end.
    case hold
    /// Stream while listening; each `HostState.revisions` entry (a cleaned segment) replaces its raw span
    /// while the field still ends with it from there; a span the user typed around is skipped.
    case live
}

/// A committed span the app's live cleanup replaced (`HostDelivery.live`). Positions count characters of
/// `HostState.committed`, which stays the raw text; a run's revisions never overlap and come in order.
public struct HostRevision: Codable, Sendable, Equatable {
    /// Where the span starts in `committed`.
    public var start: Int
    /// The span's raw text.
    public var raw: String
    /// What replaces it (the cleaned text with the raw span's surrounding whitespace).
    public var text: String

    public init(start: Int, raw: String, text: String) {
        self.start = start
        self.raw = raw
        self.text = text
    }

    public var end: Int { start + raw.count }
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
    /// How this run's final text reaches the field (set when the run starts); nil without cleanup.
    public var delivery: HostDelivery?
    /// On the final state: the post-processed text when it differs from the trimmed `committed` text.
    public var finalText: String?
    /// Set when the user asked the app to insert this (final) text (the Live Activity's Insert button): a
    /// visible keyboard types it without having followed the run, while the request is fresh
    /// (`LinkChannel.insertMaxAge`). Nil for every other state.
    public var insertAt: Date?
    /// `.live`: the revisions of this run so far, in order; nil before the first.
    public var revisions: [HostRevision]?
    /// A meeting is recording: dictation is blocked. Absent (nil) otherwise, so older readers see the same state.
    public var meetingRecording: Bool?

    public init(
        runID: String?, phase: HostPhase, target: HostTarget, committed: String, volatile: String, seq: Int,
        beatAt: Date, leaseUntil: Date?, acceptsRemoteStart: Bool, delivery: HostDelivery? = nil,
        finalText: String? = nil, insertAt: Date? = nil, revisions: [HostRevision]? = nil
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
        self.revisions = revisions
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
}
