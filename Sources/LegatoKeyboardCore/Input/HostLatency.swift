import Foundation

/// A field host's latency from a chunk's last op to the callback that shows its result, as a running estimate (smoothed
/// mean and mean deviation), and the check deadline derived from it. Platform-neutral and pure: the iPhone queue
/// (`HostProfile`) and the Mac queue each keep one per field and may pass their own bounds.
///
/// The deadline is the estimate with a margin (mean plus four mean deviations) within `minDeadlineMs...maxDeadlineMs`;
/// until `samplesNeeded` samples exist it is `coldDeadlineMs`. A deadline that ran out backs it off (`timedOut`).
public struct HostLatency: Sendable, Equatable, Codable {
    /// The iPhone's bounds, measured. Cold: Safari's slowest burst showed at 348 ms (2026-11-16). Floor: native hosts answer
    /// a burst in 26–51 ms.
    public static let coldDeadlineMs = 400.0
    public static let minDeadlineMs = 100.0
    public static let maxDeadlineMs = 1_000.0
    public static let samplesNeeded = 3
    /// A host applies a delete run one delete at a time, so a chunk's result shows later the more it deletes. Device run 4
    /// (WhatsApp, 2026-11-17): a chunk deleting 9 graphemes showed at 46 ms, one deleting 23 at about 104 ms, just past its
    /// learned 104 ms deadline, and the failed check cost a 1.8 s read walk. About 4 ms a delete: two samples, an estimate
    /// (Notes applies 500 deletes in about 300 ms).
    public static let perDeleteMs = 4.0

    public let coldMs: Double
    public let minMs: Double
    public let maxMs: Double
    public let perDeleteBonusMs: Double
    public let neededSamples: Int
    public private(set) var latencyMs: Double?
    public private(set) var deviationMs = 0.0
    public private(set) var samples = 0

    public init(coldMs: Double = coldDeadlineMs, minMs: Double = minDeadlineMs, maxMs: Double = maxDeadlineMs,
                perDeleteMs: Double = perDeleteMs, samplesNeeded: Int = samplesNeeded) {
        self.coldMs = coldMs
        self.minMs = minMs
        self.maxMs = maxMs
        self.perDeleteBonusMs = perDeleteMs
        self.neededSamples = samplesNeeded
    }

    /// How long a chunk's result may be missing from the reports before its check has failed.
    public var deadlineMs: Double {
        guard samples >= neededSamples, let latencyMs else { return coldMs }
        return min(maxMs, max(minMs, latencyMs + 4 * deviationMs))
    }

    /// The deadline of a chunk that deletes `deletes` graphemes: the learned one plus the delete run's own time.
    public func deadlineMs(deletes: Int) -> Double { deadlineMs + perDeleteBonusMs * Double(max(0, deletes)) }

    /// A chunk's result showed `ms` after its last op.
    public mutating func heard(afterMs ms: Double) {
        let sample = max(0, ms)
        if let latencyMs {
            deviationMs = 0.75 * deviationMs + 0.25 * abs(sample - latencyMs)
            self.latencyMs = 0.875 * latencyMs + 0.125 * sample
        } else {
            latencyMs = sample
            deviationMs = sample / 2
        }
        samples += 1
    }

    /// A chunk's result did not show by the learned deadline: the host may have become slower, so the deadline backs off
    /// (later samples bring it down again). The cold deadline is not learned and stays.
    public mutating func timedOut() {
        guard samples >= neededSamples, let latencyMs else { return }
        let deadline = deadlineMs
        self.latencyMs = max(latencyMs, deadline)
        deviationMs = max(deviationMs, deadline / 4)
    }

    /// For traces and journals: `latency=<mean>±<deviation>x<samples> deadline=<ms>`.
    public var summary: String {
        let latency = latencyMs.map { "\(Int($0.rounded()))±\(Int(deviationMs.rounded()))" } ?? "-"
        return "latency=\(latency)x\(samples) deadline=\(Int(deadlineMs))"
    }
}
