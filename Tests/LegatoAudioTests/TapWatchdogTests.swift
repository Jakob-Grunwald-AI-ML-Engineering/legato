import Foundation
import Testing
@testable import LegatoAudio

@Suite struct TapWatchdogTests {
    /// Feeds 1 buffer per second; returns the actions that were not `.none`, with their time.
    private func run(_ dog: inout TapWatchdog, seconds: Int, from start: Int = 0, allZero: Bool, outputting: Bool) -> [(Int, TapWatchdog.Action)] {
        var out: [(Int, TapWatchdog.Action)] = []
        for t in start..<(start + seconds) {
            let a = dog.observe(allZero: allZero, otherProcessOutputting: outputting, at: TimeInterval(t))
            if a != .none { out.append((t, a)) }
        }
        return out
    }

    @Test func zerosWhileOthersPlayRebuildThenReportSilent() {
        var dog = TapWatchdog(threshold: 20)
        let first = run(&dog, seconds: 21, allZero: true, outputting: true)
        #expect(first.map(\.1) == [.rebuild])
        #expect(first.first?.0 == 20)
        let second = run(&dog, seconds: 41, from: 21, allZero: true, outputting: true)
        #expect(second.map(\.1) == [.reportSilent])
    }

    @Test func zerosWhileNothingPlaysNeverTrigger() {
        var dog = TapWatchdog(threshold: 20)
        #expect(run(&dog, seconds: 600, allZero: true, outputting: false).isEmpty)
    }

    @Test func belowThresholdDoesNothing() {
        var dog = TapWatchdog(threshold: 20)
        #expect(run(&dog, seconds: 20, allZero: true, outputting: true).isEmpty)
    }

    @Test func realAudioResetsTheClock() {
        var dog = TapWatchdog(threshold: 20)
        #expect(run(&dog, seconds: 19, allZero: true, outputting: true).isEmpty)
        #expect(run(&dog, seconds: 1, from: 19, allZero: false, outputting: true).isEmpty)
        #expect(run(&dog, seconds: 19, from: 20, allZero: true, outputting: true).isEmpty)
    }

    @Test func recoveryAfterRebuildAllowsAnotherRebuildLater() {
        var dog = TapWatchdog(threshold: 20)
        #expect(run(&dog, seconds: 21, allZero: true, outputting: true).map(\.1) == [.rebuild])
        #expect(run(&dog, seconds: 5, from: 21, allZero: false, outputting: true).isEmpty)
        #expect(run(&dog, seconds: 21, from: 26, allZero: true, outputting: true).map(\.1) == [.rebuild])
    }
}
