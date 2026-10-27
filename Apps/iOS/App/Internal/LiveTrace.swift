#if LEGATO_INTERNAL
import Foundation
import LegatoCore
import LegatoKeyboardCore

/// Traces a run's live cleanup into `audio-diag.jsonl` (`AudioDiagnostics`): each committed segment, each
/// revision the session published, and at the end what the keyboard reports it applied. Lengths, counts and
/// times only, never text. Debug and TestFlight builds only.
@MainActor
final class LiveTrace {
    private var runID = ""
    private var started = Date()
    private var committedCount = 0
    private var segments = 0
    private var revisions = 0

    func runStarted(_ run: DictationRun, delivery: HostDelivery?) {
        runID = String(run.id.uuidString.prefix(8))
        started = Date()
        committedCount = 0
        segments = 0
        revisions = 0
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

    func revised(_ revision: TranscriptRevision) {
        revisions += 1
        AudioDiagnostics.log("live.revise", [
            "run": runID, "n": revisions, "start": revision.start, "rawChars": revision.raw.count,
            "textChars": revision.text.count, "ms": elapsedMs,
        ])
    }

    func runEnded(applied: AppliedCursor?, confirmed: Bool) {
        var fields: [String: Any] = [
            "run": runID, "segments": segments, "revisions": revisions, "chars": committedCount, "ms": elapsedMs,
            "confirmed": confirmed,
        ]
        if let applied, applied.runID.hasPrefix(runID) {
            fields["handled"] = applied.revisionsHandled
            fields["skipped"] = applied.revisionSkipped
            fields["finalApplied"] = applied.finalApplied
        }
        AudioDiagnostics.log("live.end", fields)
    }

    private var elapsedMs: Int { Int((Date().timeIntervalSince(started) * 1000).rounded()) }
}
#endif
