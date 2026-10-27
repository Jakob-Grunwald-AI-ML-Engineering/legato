import Testing
import LegatoCore
@testable import LegatoAudio

@Suite struct MicSilenceGuardTests {
    private let spec = AudioFormatSpec(sampleRate: 16_000, channelCount: 1)

    /// 0.1 s of a constant `level`.
    private func chunk(_ level: Float) -> AudioChunk {
        AudioChunk(samples: Array(repeating: level, count: 1_600), format: spec)
    }

    /// The field bug: an unused AirPods mic gives a noise floor and one spike when it switches to HFP. The spike
    /// must not make it count as working.
    @Test func aNoiseFloorWithOneSpikeIsSilent() {
        var guardian = MicSilenceGuard()
        var last = MicSilenceGuard.Verdict.undecided
        for chunk in MicSignals.chunks(MicSignals.deadAirPods()) { last = guardian.observe(chunk) }
        #expect(last == .silent)
    }

    @Test func speechIsWorking() {
        var guardian = MicSilenceGuard()
        var last = MicSilenceGuard.Verdict.undecided
        for chunk in MicSignals.chunks(MicSignals.speech(seconds: 12)) { last = guardian.observe(chunk) }
        #expect(last == .working)
    }

    @Test func aWholeWindowBelowTheFloorIsSilent() {
        var guardian = MicSilenceGuard(window: 5, grace: 0, floor: 0.01)
        var last = MicSilenceGuard.Verdict.undecided
        for i in 0..<49 {
            last = guardian.observe(chunk(0.007))
            #expect(last == .undecided, "chunk \(i): the window is not over")
        }
        #expect(guardian.observe(chunk(0.007)) == .silent)
    }

    @Test func aFrameAtTheFloorMeansTheMicWorks() {
        var guardian = MicSilenceGuard(window: 1, grace: 0, floor: 0.01)
        #expect(guardian.observe(chunk(0.001)) == .undecided)
        #expect(guardian.observe(chunk(0.02)) == .working)
    }

    @Test func aNegativeSignalCounts() {
        var guardian = MicSilenceGuard(window: 1, grace: 0)
        #expect(guardian.observe(chunk(-0.5)) == .working)
    }

    @Test func aVerdictStays() {
        var working = MicSilenceGuard(window: 1, grace: 0)
        _ = working.observe(chunk(0.5))
        for _ in 0..<50 { #expect(working.observe(chunk(0)) == .working) }

        var silent = MicSilenceGuard(window: 1, grace: 0)
        for _ in 0..<10 { _ = silent.observe(chunk(0)) }
        #expect(silent.observe(chunk(0.5)) == .silent)
    }

    @Test func aLateSignalInsideTheWindowIsStillWorking() {
        var guardian = MicSilenceGuard(window: 5, grace: 0, loudShare: 0)
        for _ in 0..<40 { _ = guardian.observe(chunk(0.001)) }
        #expect(guardian.observe(chunk(0.3)) == .working)
    }

    @Test func theGracePeriodIsNotJudged() {
        var guardian = MicSilenceGuard(window: 1, grace: 2)
        for i in 0..<20 { #expect(guardian.observe(chunk(0.5)) == .undecided, "chunk \(i) is in the grace period") }
        #expect(guardian.observe(chunk(0.5)) == .working)
    }

    @Test func aFewLoudFramesInTheWindowAreStillSilent() {
        var guardian = MicSilenceGuard(window: 8, grace: 0) // 80 frames, up to 4 loud
        var last = MicSilenceGuard.Verdict.undecided
        for i in 0..<80 { last = guardian.observe(chunk(i % 20 == 0 ? 0.1 : 0.0012)) }
        #expect(last == .silent)
    }

    @Test func framesAreCountedAcrossUnevenChunks() {
        var guardian = MicSilenceGuard()
        let samples = MicSignals.deadAirPods()
        var last = MicSilenceGuard.Verdict.undecided
        for start in stride(from: 0, to: samples.count, by: 437) {
            let piece = Array(samples[start..<min(start + 437, samples.count)])
            last = guardian.observe(AudioChunk(samples: piece, format: spec))
        }
        #expect(last == .silent)
    }
}
