import Foundation
@testable import LegatoKeyboardCore
let t0 = Date(timeIntervalSince1970: 1_000)
func hostState(phase: HostPhase = .listening, beatAt: Date = t0, leaseUntil: Date? = nil, acceptsRemoteStart: Bool = false) -> HostState {
    HostState(phase: phase, seq: 1, beatAt: beatAt, leaseUntil: leaseUntil, acceptsRemoteStart: acceptsRemoteStart)
}
