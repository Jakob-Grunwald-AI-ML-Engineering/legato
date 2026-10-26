import Foundation

/// Whether the keyboard follows the host's state into its field right now, and if not, why not (the
/// wake probe logs the reason). It is the keyboard's whole gate: a run goes into the field only when
/// the app marked it `HostTarget.keyboard`. A final state this keyboard never followed is typed only
/// when it carries a fresh insert request (`HostState.insertAt`, the Live Activity's Insert button);
/// nothing else types text the keyboard did not ask for.
public enum HostApplyDecision: Sendable, Equatable {
    case apply
    case skip(Reason)

    public enum Reason: String, Sendable, Equatable {
        case notVisible
        case noHost
        /// A running state whose beat stopped: an app that died mid-run.
        case stale
        /// The last state of a run this keyboard never followed (an old dictation seen again).
        case unseenFinal
        /// The run belongs to the app's own screen.
        case otherTarget
        /// No field is bound (the keyboard is appearing, or the host's field is gone).
        case noDocument
    }

    public static func decide(
        host: HostState?, cursor: AppliedCursor?, visible: Bool, documentID: String?, now: Date
    ) -> HostApplyDecision {
        guard visible else { return .skip(.notVisible) }
        guard let host else { return .skip(.noHost) }
        guard host.isLive(now: now) else { return .skip(.stale) }
        if cursor?.runID != host.runID, host.phase == .idle, !host.insertIsFresh(now: now) { return .skip(.unseenFinal) }
        guard host.target == .keyboard else { return .skip(.otherTarget) }
        guard documentID != nil else { return .skip(.noDocument) }
        return .apply
    }
}
