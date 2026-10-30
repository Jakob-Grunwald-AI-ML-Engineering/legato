import Foundation
import Synchronization

/// Diagnostics of every cleanup model call and model load (no user text): the app installs a sink (internal
/// builds: `audio-diag.jsonl`, with a memory sample; DEBUG: the e2e log), so a device run shows how many calls a
/// run made, of which kind, on which backend, and what a load cost.
///
/// - `cleanup.call kind=<session|agent|other> run=<id> backend=<name> ms=<n> outcome=<…>`
/// - `cleanup.skip kind=session run=<id> reason=agent` (the session's own pass, gated off for the agent)
/// - `model.loaded key=<resource> ms=<n>`
public enum CleanupCallTrace {
    public typealias Sink = @Sendable (_ event: String, _ fields: [String: String]) -> Void

    private static let state = Mutex<(sink: Sink?, run: String?)>((nil, nil))

    /// What a cleanup call is for, set by its caller around it (the session's rewrite); unset: `other` (refine, meetings).
    @TaskLocal public static var kind = "other"
    /// Replaces the installed sink for the calls made in this task (tests).
    @TaskLocal public static var override: Sink?

    public static func install(_ sink: Sink?) { state.withLock { $0.sink = sink } }

    /// The dictation run calls belong to now (the first 8 characters of its id); nil between runs.
    public static var currentRun: String? {
        get { state.withLock { $0.run } }
        set { state.withLock { $0.run = newValue.map { String($0.prefix(8)) } } }
    }

    public static func emit(_ event: String, _ fields: [String: String]) {
        guard let sink = override ?? state.withLock({ $0.sink }) else { return }
        var fields = fields
        if fields["run"] == nil { fields["run"] = currentRun ?? "-" }
        sink(event, fields)
    }

    /// The milliseconds since `start`.
    static func milliseconds(since start: ContinuousClock.Instant) -> String {
        String(Int(start.duration(to: .now) / .milliseconds(1)))
    }
}
