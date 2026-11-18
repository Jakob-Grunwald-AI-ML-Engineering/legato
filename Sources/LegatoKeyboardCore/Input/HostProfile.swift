import Foundation

/// What the queue learns about the bound field's host while it edits it (#299 round 4): no host table. It starts over
/// with a new field (`FieldQueue.reset`). Pure.
///
/// - The unit of a move (UTF-16 code units or graphemes), from a hop's look (`FieldQueue.look`).
/// - The window: the most text a report showed on each side of the caret.
/// - The callback pattern: whether a burst of ops comes back as one host callback (WhatsApp, Notes) or one per stage
///   (Safari), from the callbacks between a chunk's last op and the one that showed it.
/// - The latency from a chunk's last op to the callback that shows it, as a running estimate (smoothed mean and mean
///   deviation). The check's deadline is that estimate with a margin, within bounds; until enough samples exist it is
///   the cold-start default.
public struct HostProfile: Sendable, Equatable {
    public enum Callbacks: String, Sendable { case perBurst, perStage }

    /// The unit a move counts in, once a look showed it (nil: as configured).
    public var movesByCharacters: Bool?
    public private(set) var windowBefore = 0
    public private(set) var windowAfter = 0
    private var burstVotes = 0
    private var stageVotes = 0
    /// The latency learner and the deadline (`HostLatency`, shared with the Mac).
    public private(set) var latency = HostLatency()
    public var latencyMs: Double? { latency.latencyMs }
    public var deviationMs: Double { latency.deviationMs }
    public var samples: Int { latency.samples }

    public init() {}

    /// One callback per burst or one per stage, by the chunks seen so far (nil: none seen).
    public var callbacks: Callbacks? {
        guard burstVotes + stageVotes > 0 else { return nil }
        return stageVotes > burstVotes ? .perStage : .perBurst
    }

    /// How long a chunk's result may be missing from the reports before its check has failed.
    public var deadlineMs: Double { latency.deadlineMs }

    /// The deadline of a chunk that deletes `deletes` graphemes (`HostLatency.deadlineMs(deletes:)`).
    public func deadlineMs(deletes: Int) -> Double { latency.deadlineMs(deletes: deletes) }

    /// A report: how much it shows around the caret.
    mutating func saw(_ report: FieldQueue.Report) {
        windowBefore = max(windowBefore, FieldReader.trusted(before: report.before).count)
        windowAfter = max(windowAfter, report.after.count)
    }

    /// A chunk's result showed in a host callback `ms` after its last op, the `callbacks`-th callback since then.
    mutating func heard(afterMs ms: Double, callbacks: Int) {
        latency.heard(afterMs: ms)
        if callbacks <= 1 { burstVotes += 1 } else { stageVotes += 1 }
    }

    /// A chunk's result did not show by the learned deadline: the deadline backs off (`HostLatency.timedOut`).
    mutating func timedOut() { latency.timedOut() }

    /// For traces and the edit journal.
    public var summary: String {
        let unit = movesByCharacters.map { $0 ? "graphemes" : "utf16" } ?? "-"
        return "unit=\(unit) window=\(windowBefore)/\(windowAfter) callbacks=\(callbacks?.rawValue ?? "-") "
            + latency.summary
    }
}
