import Foundation

/// What one live cleanup pass returned: the text (the input itself when nothing changed or the cleanup gave
/// up) and why it may be unchanged, with what ran it, for the trace.
public struct LivePassResult: Sendable, Equatable {
    public var text: String
    /// A language model's reply was rejected by the cleanup guard (the input was kept, all or in part).
    public var guardRejected: Bool
    /// A stage ran out of time (its input was kept).
    public var timedOut: Bool
    /// The backend that ran, and its device ("GPU"/"CPU"), when known.
    public var backend: String?
    public var device: String?

    public init(text: String, guardRejected: Bool = false, timedOut: Bool = false, backend: String? = nil, device: String? = nil) {
        self.text = text
        self.guardRejected = guardRejected
        self.timedOut = timedOut
        self.backend = backend
        self.device = device
    }
}

/// One pass of a live run, for the internal trace: lengths, counts and times only, never text.
public struct LivePassReport: Sendable, Equatable {
    public enum Outcome: String, Sendable, Equatable {
        /// Its cleaned text went out as a revision.
        case published
        /// The cleanup guard rejected the model's reply; nothing went out.
        case guardRejected
        /// The cleanup (or, at the stop, the stop's time limit) ran out; nothing went out.
        case timeout
        /// The cleaned text equals what is shown already; nothing went out.
        case unchanged
        /// Newer text took its place (a final pass at the stop, a sent boundary) or a newer result was out.
        case superseded
        /// The cleanup threw.
        case error
    }

    /// Counts the run's passes from 1.
    public var n: Int
    /// Characters of raw text the pass cleaned (its window past the length cap).
    public var inputCharacters: Int
    /// Characters of cleaned text it returned (0 when it threw or was cut).
    public var outputCharacters: Int
    public var milliseconds: Int
    public var outcome: Outcome
    /// It decided the run's final text: the stop's pass, or the pass in flight over all of it.
    public var final: Bool
    public var backend: String?
    public var device: String?

    public init(
        n: Int, inputCharacters: Int, outputCharacters: Int, milliseconds: Int, outcome: Outcome, final: Bool,
        backend: String? = nil, device: String? = nil
    ) {
        self.n = n
        self.inputCharacters = inputCharacters
        self.outputCharacters = outputCharacters
        self.milliseconds = milliseconds
        self.outcome = outcome
        self.final = final
        self.backend = backend
        self.device = device
    }
}

/// A sent boundary (the field the run streamed into was cleared, as by sending a message), for the trace.
public struct LiveSentReport: Sendable, Equatable {
    /// Raw characters that went with it (since the previous boundary).
    public var rawCharacters: Int
    /// Characters of the text the field showed for them (cleaned as far as it was).
    public var shownCharacters: Int
    /// Passes over the sent text that were in flight and dropped.
    public var cancelledPasses: Int

    public init(rawCharacters: Int, shownCharacters: Int, cancelledPasses: Int) {
        self.rawCharacters = rawCharacters
        self.shownCharacters = shownCharacters
        self.cancelledPasses = cancelledPasses
    }
}

/// What a live run reports for the internal trace.
public enum LiveTraceEvent: Sendable, Equatable {
    case pass(LivePassReport)
    case sent(LiveSentReport)
}
