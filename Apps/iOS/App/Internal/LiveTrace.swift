#if LEGATO_INTERNAL
import Foundation
import LegatoAppServices
import LegatoCore
import LegatoKeyboardCore

/// Traces a keyboard run into `audio-diag.jsonl` (`AudioDiagnostics`): each committed segment, the linked stop,
/// and at the end what the keyboard reports it applied. Lengths, counts and times only, never text. Debug and
/// TestFlight builds only.
@MainActor
final class LiveTrace {
    private var runID = ""
    private var started = Date()
    private var committedCount = 0
    private var segments = 0

    func runStarted(_ run: DictationRun, delivery: HostDelivery?) {
        runID = String(run.id.uuidString.prefix(8))
        started = Date()
        committedCount = 0
        segments = 0
        AudioDiagnostics.log("live.run", ["run": runID, "target": "\(run.target)", "delivery": delivery?.rawValue ?? "none"])
    }

    func update(committed: String) {
        let count = committed.count
        guard count > committedCount else { return }
        segments += 1
        AudioDiagnostics.log("live.segment", [
            "run": runID, "n": segments, "chars": count - committedCount, "ms": elapsedMs,
        ])
        committedCount = count
    }

    func runEnded(applied: AppliedCursor?, confirmed: Bool) {
        var fields: [String: Any] = [
            "run": runID, "segments": segments, "chars": committedCount, "ms": elapsedMs, "confirmed": confirmed,
        ]
        if let applied, applied.runID.hasPrefix(runID) {
            fields["finalApplied"] = applied.finalApplied
        }
        AudioDiagnostics.log("live.end", fields)
    }

    /// The linked stop: which branch it took, how long it waited for the keyboard,
    /// how many edits it sent and got outcomes for (`LinkedCleanupRun.StopReport`).
    func linkedStop(_ report: LinkedCleanupRun.StopReport) {
        var fields: [String: Any] = [
            "run": runID, "mode": report.mode.rawValue, "branch": report.branch.rawValue, "waitMs": report.waitMs,
            "sent": report.sent, "acked": report.acked, "steps": report.steps, "copied": report.copied,
            "landed": report.landed, "ms": elapsedMs,
            "patched": "\(report.patched)/\(report.patches)", "outOfWindow": report.outOfWindow,
        ]
        if let reason = report.reason { fields["reason"] = reason }
        AudioDiagnostics.log("linked.stop", fields)
    }

    private var elapsedMs: Int { Int((Date().timeIntervalSince(started) * 1000).rounded()) }
}
#endif
