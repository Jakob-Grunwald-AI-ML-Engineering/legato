import Foundation
@testable import LegatoKeyboardCore

let t0 = Date(timeIntervalSince1970: 1_000)

func hostState(
    runID: String? = "run-1", phase: HostPhase = .listening, target: HostTarget = .keyboard,
    committed: String = "", volatile: String = "", beatAt: Date = t0, leaseUntil: Date? = nil,
    acceptsRemoteStart: Bool = false
) -> HostState {
    HostState(
        runID: runID, phase: phase, target: target, committed: committed, volatile: volatile, seq: 1,
        beatAt: beatAt, leaseUntil: leaseUntil, acceptsRemoteStart: acceptsRemoteStart)
}

func cursor(
    runID: String = "run-1", documentID: String = "doc-A", committedCount: Int = 0, volatile: String = "",
    needsSeparator: Bool = false, finalApplied: Bool = false
) -> AppliedCursor {
    AppliedCursor(
        runID: runID, documentID: documentID, committedCount: committedCount, volatile: volatile,
        needsSeparator: needsSeparator, finalApplied: finalApplied)
}
