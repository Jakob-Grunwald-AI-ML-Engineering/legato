import Foundation
import Testing
@testable import LegatoKeyboardCore

@Suite struct CleanupIndicatorTests {
    private let t0 = Date(timeIntervalSince1970: 1_000)
    private func snapshot(_ run: String, _ version: Int, complete: Bool) -> LiveDictationSnapshot {
        .init(runID: run, version: version, segments: [.init(id: 0, text: "words", cleaned: complete, final: complete)], complete: complete)
    }

    @Test func onFromTheStopUntilTheCompleteVersionLands() {
        var indicator = CleanupIndicator()
        indicator.received(snapshot("a", 3, complete: false), at: t0)
        #expect(!indicator.isActive)
        indicator.stopped(runID: "a", at: t0)
        #expect(indicator.isActive)
        indicator.applied(runID: "a", version: 3, complete: false)
        #expect(indicator.isActive, "the raw words landing is not the cleanup")
        indicator.received(snapshot("a", 5, complete: true), at: t0)
        indicator.applied(runID: "a", version: 4, complete: true)
        #expect(indicator.isActive, "an older version is not the cleaned text")
        indicator.applied(runID: "a", version: 5, complete: true)
        #expect(!indicator.isActive)
        // The same version seen again does not turn it back on; a late cleanup (a newer version) does, until it lands.
        indicator.received(snapshot("a", 5, complete: true), at: t0)
        #expect(!indicator.isActive)
        indicator.received(snapshot("a", 6, complete: true), at: t0)
        #expect(indicator.isActive)
        indicator.applied(runID: "a", version: 6, complete: true)
        #expect(!indicator.isActive)
    }

    @Test func aCompleteSnapshotWithoutAStopTurnsItOn() {
        var indicator = CleanupIndicator()
        indicator.received(snapshot("a", 2, complete: true), at: t0)
        #expect(indicator.isActive && indicator.runID == "a")
    }

    @Test func aNewTakeAClearOrTheBoundEndsIt() {
        var indicator = CleanupIndicator()
        indicator.stopped(runID: "a", at: t0)
        indicator.received(snapshot("b", 1, complete: false), at: t0)
        #expect(!indicator.isActive, "a new take")
        indicator.stopped(runID: "b", at: t0)
        indicator.clear()
        #expect(!indicator.isActive, "dropped, field switch or keyboard closed")
        indicator.stopped(runID: "c", at: t0)
        indicator.expire(now: t0.addingTimeInterval(CleanupIndicator.limit - 1))
        #expect(indicator.isActive)
        indicator.expire(now: t0.addingTimeInterval(CleanupIndicator.limit))
        #expect(!indicator.isActive, "no cleanup came")
    }
}

@Suite struct CleanupDeliveryStatusTests {
    @Test func completedCleanupWaitsAsApplyingAndFailureCannotRestartFromPolling() {
        let now = Date(timeIntervalSince1970: 1_000)
        let snapshot = LiveDictationSnapshot(runID: "take", version: 2,
            segments: [.init(id: 0, text: "Clean words.", cleaned: true, final: true)], complete: true)
        var indicator = CleanupIndicator()
        indicator.stopped(runID: "take", at: now)
        #expect(indicator.isActive && !indicator.isApplying)
        indicator.received(snapshot, at: now)
        #expect(indicator.isApplying)
        indicator.failed(runID: "take")
        indicator.received(snapshot, at: now.addingTimeInterval(1))
        #expect(!indicator.isActive && !indicator.isApplying)
        indicator.stopped(runID: "next", at: now.addingTimeInterval(2))
        #expect(indicator.isActive && !indicator.isApplying)
    }

    @Test func aDeliveryDeadlineIsTerminalForThatTake() {
        let now = Date(timeIntervalSince1970: 1_000)
        let snapshot = LiveDictationSnapshot(runID: "take", version: 2,
            segments: [.init(id: 0, text: "Clean words.", cleaned: true, final: true)], complete: true)
        var indicator = CleanupIndicator()
        indicator.received(snapshot, at: now)
        indicator.expire(now: now.addingTimeInterval(CleanupIndicator.limit))
        indicator.received(snapshot, at: now.addingTimeInterval(CleanupIndicator.limit + 1))
        #expect(!indicator.isActive)
    }
}
