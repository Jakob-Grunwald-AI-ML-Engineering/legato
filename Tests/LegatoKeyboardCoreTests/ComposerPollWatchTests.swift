import Testing
@testable import LegatoKeyboardCore

struct ComposerPollWatchTests {
    /// Ticks like the 100 ms poll (every 0.5 s here, exact in binary) up to `end`; returns what was reported.
    private func run(_ watch: inout ComposerPollWatch, from start: Double, to end: Double) -> [ComposerPollWatch.Finding] {
        stride(from: start, through: end, by: 0.5).compactMap { watch.tick(at: $0) }
    }

    @Test func quietPollIsNotStale() {
        var watch = ComposerPollWatch()
        watch.start(at: 0)
        #expect(run(&watch, from: 0.5, to: 30).isEmpty)
    }
    @Test func noteDeliveredByTheNextReadIsNotStale() {
        var watch = ComposerPollWatch()
        watch.start(at: 0)
        watch.noteArrived(at: 1)
        watch.delivered(at: 1.5)
        #expect(run(&watch, from: 0.5, to: 10).isEmpty)
    }
    @Test func noteWithoutDeliveryIsReportedOncePerEpisode() {
        var watch = ComposerPollWatch()
        watch.start(at: 0)
        _ = run(&watch, from: 0.5, to: 1)
        watch.noteArrived(at: 1)
        #expect(run(&watch, from: 1.5, to: 10) == [.staleAfterNote(age: 2.5)])
        watch.delivered(at: 10)
        watch.noteArrived(at: 11)
        #expect(run(&watch, from: 10.5, to: 20) == [.staleAfterNote(age: 2.5)])
    }
    @Test func noteRightAfterADeliveryIsNotWaitedFor() {
        var watch = ComposerPollWatch()
        watch.start(at: 0)
        watch.delivered(at: 1)
        watch.noteArrived(at: 1.125)   // the poll read the new bytes before the note landed
        #expect(run(&watch, from: 1.5, to: 10).isEmpty)
    }
    @Test func loopGapIsReported() {
        var watch = ComposerPollWatch()
        watch.start(at: 0)
        #expect(watch.tick(at: 0.5) == nil)
        #expect(watch.tick(at: 4.5) == .loopGap(gap: 4))
        #expect(watch.tick(at: 5) == nil)
    }
}
