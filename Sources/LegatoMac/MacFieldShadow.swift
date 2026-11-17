import Foundation
import LegatoKeyboardCore

/// The Mac queue's picture of a field between reads: the last known text and selection, and whether the host said
/// something changed since (`dirty`, set by an AX value/selection notification). The Mac keeps the whole field, not the
/// iPhone's windowed `ShadowDocument`, because its AX read is the whole field (30-100 us up to 10k characters in the Mac
/// VM); what is shared with the iPhone is the observation idea: a fresh read either matches the picture, is the queue's own
/// write landing, is the user's change, or is unknown.
public struct MacFieldShadow: Sendable, Equatable {
    public enum Observation: String, Sendable, Equatable {
        /// Same text and selection as the shadow.
        case matches
        /// The text is what a chunk of the queue's own that is in flight leaves (`candidates`).
        case ownWrite
        /// Something else changed and the user's input or a host notification accounts for it.
        case userChange
        /// Something else changed with no input and no notification: a host that does not notify, or a late write.
        case unknown
    }

    public private(set) var text: String
    public private(set) var selection: UTF16Range
    /// A notification arrived since the last read.
    public private(set) var dirty = false

    public init(text: String, selection: UTF16Range) { self.text = text; self.selection = selection }

    public mutating func notified() { dirty = true }

    /// Classifies a fresh read against the shadow and the texts the queue's own chunks in flight would leave, then takes
    /// the read as the new picture. `userInput`: the user's real key or click counter moved since the last read.
    @discardableResult
    public mutating func observe(text fresh: String, selection freshSelection: UTF16Range, candidates: [String] = [],
                                 userInput: Bool = false) -> Observation {
        let result: Observation
        if fresh == text, freshSelection == selection {
            result = .matches
        } else if fresh != text, candidates.contains(fresh) {
            result = .ownWrite
        } else if userInput || dirty {
            result = .userChange
        } else {
            result = .unknown
        }
        text = fresh; selection = freshSelection; dirty = false
        return result
    }
}

/// What the Mac queue learned about one field's host, remembered across bindings (`TextTarget.fieldKey`), next to
/// `CaretJumps`: how late a chunk's result shows, whether a burst of keys is checked in time, and whether the host
/// sends notifications at all.
public struct MacFieldHost: Sendable, Equatable {
    /// Derived from the Mac VM (2026-11-17), labelled as such: a burst of 31-120 synthetic keys showed its end state
    /// 34-102 ms after posting in TextEdit, Safari and Edge, an AX hunk write at once to 18 ms. Cold deadline 250 ms
    /// (above every measured burst), floor 30 ms, ceiling 1 s. Per delete 2 ms: Edge showed 19 backspaces in 37-53 ms.
    public static let latencyBounds = (coldMs: 250.0, minMs: 30.0, maxMs: 1_000.0, perDeleteMs: 2.0)
    /// Burst checks that failed before a field falls back to verified keys.
    public static let burstFailureLimit = 2

    public var latency = HostLatency(coldMs: latencyBounds.coldMs, minMs: latencyBounds.minMs, maxMs: latencyBounds.maxMs,
                                     perDeleteMs: latencyBounds.perDeleteMs)
    public var burstFailures = 0
    /// Notifications seen after the queue's own writes (nil until a write was observed).
    public var notifies: Bool?
    public init() {}
    /// A keyed field takes bursts until two of their checks failed.
    public var bursts: Bool { burstFailures < Self.burstFailureLimit }
}
