#if LEGATO_INTERNAL
import Foundation
import LegatoCore
import LegatoKeyboardCore

/// Traces a run's live cleanup into `audio-diag.jsonl` (`AudioDiagnostics`): each committed segment, each
/// rolling pass and its outcome, each revision the session published, each sent boundary, and at the end what
/// the keyboard reports it applied. Lengths, counts and times only, never text. Debug and TestFlight builds only.
@MainActor
final class LiveTrace {
    private var runID = ""
    private var started = Date()
    private var committedCount = 0
    private var segments = 0
    private var revisions = 0
    private var passes = 0
    private var published = 0
    private var sent = 0
    private var finalOutcome: String?

    func runStarted(_ run: DictationRun, delivery: HostDelivery?) {
        runID = String(run.id.uuidString.prefix(8))
        started = Date()
        committedCount = 0
        segments = 0
        revisions = 0
        passes = 0
        published = 0
        sent = 0
        finalOutcome = nil
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
            "run": runID, "n": revision.n, "start": revision.start, "rawChars": revision.raw.count,
            "textChars": revision.text.count, "ms": elapsedMs,
        ])
    }

    func traced(_ event: LiveTraceEvent) {
        switch event {
        case .pass(let pass):
            passes += 1
            if pass.outcome == .published { published += 1 }
            if pass.final { finalOutcome = pass.outcome.rawValue }
            var fields: [String: Any] = [
                "run": runID, "n": pass.n, "inChars": pass.inputCharacters, "outChars": pass.outputCharacters,
                "passMs": pass.milliseconds, "outcome": pass.outcome.rawValue, "final": pass.final, "ms": elapsedMs,
            ]
            if let backend = pass.backend { fields["backend"] = backend }
            if let device = pass.device { fields["device"] = device }
            AudioDiagnostics.log("live.pass", fields)
        case .sent(let boundary):
            sent += 1
            AudioDiagnostics.log("live.sent", [
                "run": runID, "n": sent, "rawChars": boundary.rawCharacters, "droppedChars": boundary.shownCharacters,
                "cancelledPasses": boundary.cancelledPasses, "ms": elapsedMs,
            ])
        }
    }

    func runEnded(applied: AppliedCursor?, confirmed: Bool) {
        var fields: [String: Any] = [
            "run": runID, "segments": segments, "revisions": revisions, "passes": passes, "published": published,
            "sent": sent, "final": finalOutcome ?? "none", "chars": committedCount, "ms": elapsedMs,
            "confirmed": confirmed,
        ]
        if let applied, applied.runID.hasPrefix(runID) {
            fields["handled"] = applied.revisionHandled
            fields["shown"] = applied.shownRevision
            fields["skipped"] = applied.revisionSkipped
            fields["finalApplied"] = applied.finalApplied
        }
        AudioDiagnostics.log("live.end", fields)
    }

    private var elapsedMs: Int { Int((Date().timeIntervalSince(started) * 1000).rounded()) }
}
#endif
