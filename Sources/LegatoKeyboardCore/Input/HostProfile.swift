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
    /// The deadline before anything is learned: Safari's slowest measured burst showed at 348 ms (2026-11-16).
    public static let coldDeadlineMs = 400.0
    /// A learned deadline never goes below this (native hosts answer a burst in 26–51 ms, measured) nor above that.
    public static let minDeadlineMs = 100.0
    public static let maxDeadlineMs = 1_000.0
    /// Samples before the learned deadline replaces the cold one.
    public static let samplesNeeded = 3

    public enum Callbacks: String, Sendable { case perBurst, perStage }

    /// The unit a move counts in, once a look showed it (nil: as configured).
    public var movesByCharacters: Bool?
    public private(set) var windowBefore = 0
    public private(set) var windowAfter = 0
    private var burstVotes = 0
    private var stageVotes = 0
    public private(set) var latencyMs: Double?
    public private(set) var deviationMs = 0.0
    public private(set) var samples = 0

    public init() {}

    /// One callback per burst or one per stage, by the chunks seen so far (nil: none seen).
    public var callbacks: Callbacks? {
        guard burstVotes + stageVotes > 0 else { return nil }
        return stageVotes > burstVotes ? .perStage : .perBurst
    }

    /// How long a chunk's result may be missing from the reports before its check has failed.
    public var deadlineMs: Double {
        guard samples >= Self.samplesNeeded, let latencyMs else { return Self.coldDeadlineMs }
        return min(Self.maxDeadlineMs, max(Self.minDeadlineMs, latencyMs + 4 * deviationMs))
    }

    /// A report: how much it shows around the caret.
    mutating func saw(_ report: FieldQueue.Report) {
        windowBefore = max(windowBefore, FieldReader.trusted(before: report.before).count)
        windowAfter = max(windowAfter, report.after.count)
    }

    /// A chunk's result showed in a host callback `ms` after its last op, the `callbacks`-th callback since then.
    mutating func heard(afterMs ms: Double, callbacks: Int) {
        let sample = max(0, ms)
        if let latencyMs {
            deviationMs = 0.75 * deviationMs + 0.25 * abs(sample - latencyMs)
            self.latencyMs = 0.875 * latencyMs + 0.125 * sample
        } else {
            latencyMs = sample
            deviationMs = sample / 2
        }
        samples += 1
        if callbacks <= 1 { burstVotes += 1 } else { stageVotes += 1 }
    }

    /// A chunk's result did not show by the learned deadline: the host may have become slower, so the deadline backs off
    /// (later samples bring it down again). The cold deadline is not learned and stays.
    mutating func timedOut() {
        guard samples >= Self.samplesNeeded, let latencyMs else { return }
        let deadline = deadlineMs
        self.latencyMs = max(latencyMs, deadline)
        deviationMs = max(deviationMs, deadline / 4)
    }

    /// For traces and the edit journal.
    public var summary: String {
        let unit = movesByCharacters.map { $0 ? "graphemes" : "utf16" } ?? "-"
        let latency = latencyMs.map { "\(Int($0.rounded()))±\(Int(deviationMs.rounded()))" } ?? "-"
        return "unit=\(unit) window=\(windowBefore)/\(windowAfter) callbacks=\(callbacks?.rawValue ?? "-") "
            + "latency=\(latency)x\(samples) deadline=\(Int(deadlineMs))"
    }
}
