import Foundation
import LegatoCore

/// Decides what the Live Activity of the held microphone should do for each composer state. Pure: the app's
/// presenter feeds it observed state and performs the returned step.
public struct HoldActivityPlanner: Sendable {
    public enum Step: Equatable, Sendable {
        case request(DictationPhase, tail: String)
        case update(DictationPhase, tail: String)
        case end
    }

    /// Tail updates are rare so a take's text does not hammer ActivityKit.
    public static let tailInterval: TimeInterval = 1

    private var active = false
    /// Armed was seen since the last release; one request attempt per hold, so a refusal is not retried.
    private var requested = false
    private var phase = DictationPhase.held
    private var tail = ""
    private var tailAt = Date.distantPast

    public init() {}

    public static func phase(listening: Bool, recovering: Bool = false) -> DictationPhase {
        recovering ? .recovering : (listening ? .listening : .held)
    }

    public mutating func plan(armed: Bool, listening: Bool, tail: String, recovering: Bool = false, now: Date = Date()) -> Step? {
        guard armed else {
            requested = false
            guard active else { return nil }
            active = false
            return .end
        }
        let phase = Self.phase(listening: listening, recovering: recovering)
        let tail = phase == .listening ? tail : ""
        guard active else {
            guard !requested else { return nil }
            requested = true
            return .request(phase, tail: tail)
        }
        let phaseChanged = phase != self.phase
        guard phaseChanged || (tail != self.tail && now.timeIntervalSince(tailAt) >= Self.tailInterval) else { return nil }
        return .update(phase, tail: tail)
    }

    /// Records that `step` was carried out (`succeeded` is false when ActivityKit refused a request).
    public mutating func performed(_ step: Step, succeeded: Bool = true, now: Date = Date()) {
        switch step {
        case .request(let phase, let tail):
            guard succeeded else { return }
            active = true; self.phase = phase; self.tail = tail; tailAt = now
        case .update(let phase, let tail):
            self.phase = phase; self.tail = tail; tailAt = now
        case .end:
            active = false
        }
    }
}
