import Testing
import LegatoCore
@testable import LegatoAudio

@Suite struct MicSilenceGuardTests {
    private let spec = AudioFormatSpec(sampleRate: 16_000, channelCount: 1)

    /// 0.1 s of a constant `level`.
    private func chunk(_ level: Float) -> AudioChunk {
        AudioChunk(samples: Array(repeating: level, count: 1_600), format: spec)
    }

    @Test func aWholeWindowBelowTheThresholdIsSilent() {
        var guardian = MicSilenceGuard(window: 5, peakThreshold: 0.01)
        var last = MicSilenceGuard.Verdict.undecided
        for i in 0..<49 {
            last = guardian.observe(chunk(0.007))
            #expect(last == .undecided, "chunk \(i): the window is not over")
        }
        #expect(guardian.observe(chunk(0.007)) == .silent)
    }

    @Test func aSampleAtTheThresholdMeansTheMicWorks() {
        var guardian = MicSilenceGuard(window: 5, peakThreshold: 0.01)
        #expect(guardian.observe(chunk(0.001)) == .undecided)
        #expect(guardian.observe(chunk(0.02)) == .working)
    }

    @Test func aNegativePeakCounts() {
        var guardian = MicSilenceGuard()
        #expect(guardian.observe(chunk(-0.5)) == .working)
    }

    @Test func aVerdictStays() {
        var working = MicSilenceGuard(window: 1)
        _ = working.observe(chunk(0.5))
        for _ in 0..<50 { #expect(working.observe(chunk(0)) == .working) }

        var silent = MicSilenceGuard(window: 1)
        for _ in 0..<10 { _ = silent.observe(chunk(0)) }
        #expect(silent.observe(chunk(0.5)) == .silent)
    }

    @Test func aLateSignalInsideTheWindowIsStillWorking() {
        var guardian = MicSilenceGuard(window: 5)
        for _ in 0..<40 { _ = guardian.observe(chunk(0.001)) }
        #expect(guardian.observe(chunk(0.3)) == .working)
    }
}
