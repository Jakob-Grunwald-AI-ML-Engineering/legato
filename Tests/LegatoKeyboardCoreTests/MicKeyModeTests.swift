import Foundation
import Testing
@testable import LegatoKeyboardCore

@Suite struct MicKeyModeTests {
    private let now = t0.addingTimeInterval(1)

    @Test func withoutFullAccessTheKeyExplainsIt() {
        let fresh = hostState(phase: .listening, beatAt: now)
        #expect(MicKeyMode.resolve(host: fresh, now: now, fullAccess: false) == .needsFullAccess)
        #expect(MicKeyMode.resolve(host: nil, now: now, fullAccess: false) == .needsFullAccess)
    }

    @Test func noHostStateMeansOpeningTheApp() {
        #expect(MicKeyMode.resolve(host: nil, now: now, fullAccess: true) == .openApp)
    }

    @Test func aStaleBeatResolvesToOpenApp() {
        let stale = hostState(
            phase: .listening, beatAt: now.addingTimeInterval(-LinkChannel.beatFreshness - 0.1),
            acceptsRemoteStart: true)
        #expect(MicKeyMode.resolve(host: stale, now: now, fullAccess: true) == .openApp)
        let idleStale = hostState(
            phase: .idle, beatAt: now.addingTimeInterval(-10), leaseUntil: now.addingTimeInterval(30),
            acceptsRemoteStart: true)
        #expect(MicKeyMode.resolve(host: idleStale, now: now, fullAccess: true) == .openApp)
    }

    @Test func aBeatJustInsideTheWindowIsFresh() {
        let host = hostState(phase: .listening, beatAt: now.addingTimeInterval(-2.4))
        #expect(MicKeyMode.resolve(host: host, now: now, fullAccess: true) == .remote(.stop))
    }

    @Test(arguments: [HostPhase.starting, .listening])
    func aRunInProgressWithAFreshBeatCanBeStoppedRemotely(phase: HostPhase) {
        let host = hostState(phase: phase, beatAt: now)
        #expect(MicKeyMode.resolve(host: host, now: now, fullAccess: true) == .remote(.stop))
    }

    @Test func anIdleHostHoldingALeaseCanBeStartedRemotely() {
        let host = hostState(
            phase: .idle, beatAt: now, leaseUntil: now.addingTimeInterval(20), acceptsRemoteStart: true)
        #expect(MicKeyMode.resolve(host: host, now: now, fullAccess: true) == .remote(.start))
    }

    @Test func anIdleHostWithoutALeaseNeedsTheAppOpened() {
        let host = hostState(phase: .idle, beatAt: now, acceptsRemoteStart: false)
        #expect(MicKeyMode.resolve(host: host, now: now, fullAccess: true) == .openApp)
    }

    @Test func anExpiredLeaseNeedsTheAppOpenedEvenIfTheFlagIsStillSet() {
        let host = hostState(
            phase: .idle, beatAt: now, leaseUntil: now.addingTimeInterval(-0.5), acceptsRemoteStart: true)
        #expect(MicKeyMode.resolve(host: host, now: now, fullAccess: true) == .openApp)
    }
}
