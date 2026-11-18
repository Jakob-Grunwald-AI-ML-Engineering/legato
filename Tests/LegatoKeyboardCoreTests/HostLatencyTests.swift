import Foundation
import Testing
@testable import LegatoKeyboardCore

/// The latency/deadline core shared by the iPhone (`HostProfile`) and the Mac: cold start, smoothing, bounds, the delete
/// run's bonus and the back-off.
@Suite struct HostLatencyTests {
    @Test func theColdDeadlineHoldsUntilEnoughSamples() {
        var latency = HostLatency()
        #expect(latency.deadlineMs == HostLatency.coldDeadlineMs)
        latency.heard(afterMs: 30)
        latency.heard(afterMs: 35)
        #expect(latency.deadlineMs == HostLatency.coldDeadlineMs)
        latency.timedOut()
        #expect(latency.deadlineMs == HostLatency.coldDeadlineMs, "nothing learned yet: no back-off either")
        latency.heard(afterMs: 40)
        #expect(latency.deadlineMs == HostLatency.minDeadlineMs)
    }

    @Test func theEstimateSmoothsAndTheDeadlineIsMeanPlusFourDeviations() {
        var latency = HostLatency()
        latency.heard(afterMs: 200)
        #expect(latency.latencyMs == 200 && latency.deviationMs == 100)
        latency.heard(afterMs: 120)
        #expect(abs(latency.latencyMs! - 190) < 1e-9)
        latency.heard(afterMs: 190)
        #expect(abs(latency.deadlineMs - (latency.latencyMs! + 4 * latency.deviationMs)) < 1e-9)
    }

    @Test func aBackOffRaisesTheDeadlineAndLaterSamplesBringItDown() {
        var latency = HostLatency()
        for _ in 0..<3 { latency.heard(afterMs: 40) }
        #expect(latency.deadlineMs == HostLatency.minDeadlineMs)
        latency.timedOut()
        #expect(latency.deadlineMs > HostLatency.minDeadlineMs)
        for _ in 0..<40 { latency.heard(afterMs: 35) }
        #expect(latency.deadlineMs == HostLatency.minDeadlineMs)
    }

    @Test func aVerySlowHostIsClamped() {
        var latency = HostLatency()
        for _ in 0..<60 { latency.heard(afterMs: 5_000) }
        #expect(latency.deadlineMs == HostLatency.maxDeadlineMs)
    }

    @Test func eachDeletedGraphemeAddsTime() {
        var latency = HostLatency()
        for ms in [30.0, 62, 18, 41, 26] { latency.heard(afterMs: ms) }
        #expect(latency.deadlineMs(deletes: 0) == latency.deadlineMs)
        #expect(latency.deadlineMs(deletes: 23) == latency.deadlineMs + 23 * HostLatency.perDeleteMs)
        #expect(latency.deadlineMs(deletes: -5) == latency.deadlineMs)
    }

    @Test func theBoundsAreParameters() {
        var mac = HostLatency(coldMs: 250, minMs: 40, maxMs: 600, perDeleteMs: 1, samplesNeeded: 2)
        #expect(mac.deadlineMs == 250)
        mac.heard(afterMs: 10)
        mac.heard(afterMs: 10)
        #expect(mac.deadlineMs == 40)
        #expect(mac.deadlineMs(deletes: 10) == 50)
        for _ in 0..<60 { mac.heard(afterMs: 5_000) }
        #expect(mac.deadlineMs == 600)
    }

    @Test func itRoundTripsThroughCodable() throws {
        var latency = HostLatency()
        for ms in [30.0, 62, 18] { latency.heard(afterMs: ms) }
        let back = try JSONDecoder().decode(HostLatency.self, from: JSONEncoder().encode(latency))
        #expect(back == latency)
    }
}
