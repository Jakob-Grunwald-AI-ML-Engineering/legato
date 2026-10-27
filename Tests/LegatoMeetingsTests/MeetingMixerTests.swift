import Foundation
import Testing
import LegatoCore
@testable import LegatoMeetings

@Suite struct MeetingMixerTests {
    let frame = 1_600  // 100 ms at 16 kHz

    func constant(_ value: Float, _ count: Int) -> [Float] { Array(repeating: value, count: count) }

    func approx(_ a: [Float], _ value: Float) -> Bool { a.allSatisfy { abs($0 - value) < 1e-6 } }

    @Test func eachFrameSumsWhatEverySourceDelivered() {
        var mixer = MeetingMixer(sampleRate: 16_000)
        mixer.append(constant(0.2, frame), from: .mic, at: 0.1)
        mixer.append(constant(0.3, frame), from: .system, at: 0.1)
        let frames = mixer.advance(to: 0.1)
        #expect(frames.count == 1)
        #expect(frames[0].count == frame)
        #expect(approx(frames[0], 0.5))
    }

    @Test func aLateSourceIsSilenceForTheFrameAndNeverHoldsTheMixUp() {
        var mixer = MeetingMixer(sampleRate: 16_000)
        mixer.append(constant(0.25, 3 * frame), from: .mic, at: 0.3)  // the system source has delivered nothing yet
        let frames = mixer.advance(to: 0.3)
        #expect(frames.count == 3)
        #expect(frames.allSatisfy { approx($0, 0.25) })

        // When it does arrive, it joins the next frame; the mic has nothing left, which is silence too.
        mixer.append(constant(0.5, frame), from: .system, at: 0.4)
        let next = mixer.advance(to: 0.4)
        #expect(next.count == 1 && approx(next[0], 0.5))
    }

    @Test func aSourceThatDeliveredLessThanAFrameIsPaddedWithSilence() {
        var mixer = MeetingMixer(sampleRate: 16_000)
        mixer.append(constant(0.4, frame / 2), from: .mic, at: 0.05)
        let frames = mixer.advance(to: 0.1)
        #expect(approx(Array(frames[0][..<(frame / 2)]), 0.4))
        #expect(approx(Array(frames[0][(frame / 2)...]), 0))
    }

    @Test func aMutedSourceIsSilencedBeforeTheMixAndTheOthersAreNot() {
        var mixer = MeetingMixer(sampleRate: 16_000)
        mixer.append(constant(0.2, 3 * frame), from: .mic, at: 0.3)
        mixer.append(constant(0.3, 3 * frame), from: .system, at: 0.3)
        mixer.mute(.mic, at: 0.1)
        let frames = mixer.advance(to: 0.3)
        #expect(approx(frames[0], 0.5))  // before the mute
        #expect(approx(frames[1], 0.3))  // the mic is silent, the system is not
        #expect(approx(frames[2], 0.3))
    }

    @Test func aFrameTouchedByAMuteIsSilentAndAudioHeardWhileMutedIsNeverPlayedLater() {
        var mixer = MeetingMixer(sampleRate: 16_000)
        mixer.append(constant(0.1, frame) + constant(0.2, frame) + constant(0.3, frame), from: .mic, at: 0.3)
        mixer.mute(.mic, at: 0.12)  // inside frame 1
        mixer.unmute(.mic, at: 0.15)  // still inside frame 1
        let frames = mixer.advance(to: 0.3)
        #expect(approx(frames[0], 0.1))
        #expect(approx(frames[1], 0))  // any muted instant silences the frame
        #expect(approx(frames[2], 0.3))  // the 0.2 audio was dropped, not postponed
    }

    @Test func pauseSilencesEverySourceAndIsLiftedOnResume() {
        var mixer = MeetingMixer(sampleRate: 16_000)
        mixer.append(constant(0.2, 3 * frame), from: .mic, at: 0.3)
        mixer.append(constant(0.3, 3 * frame), from: .system, at: 0.3)
        mixer.pause(at: 0.1)
        mixer.resume(at: 0.2)
        let frames = mixer.advance(to: 0.3)
        #expect(approx(frames[0], 0.5))
        #expect(approx(frames[1], 0))
        #expect(approx(frames[2], 0.5))
    }

    @Test func muteAndPauseAreIndependent() {
        var mixer = MeetingMixer(sampleRate: 16_000)
        mixer.append(constant(0.2, 2 * frame), from: .mic, at: 0.2)
        mixer.append(constant(0.3, 2 * frame), from: .system, at: 0.2)
        mixer.mute(.mic, at: 0)
        mixer.pause(at: 0.1)
        mixer.resume(at: 0.2)
        let frames = mixer.advance(to: 0.2)
        #expect(approx(frames[0], 0.3))
        #expect(approx(frames[1], 0))
    }

    @Test func theMixIsExactlyAsLongAsTheMeeting() {
        var mixer = MeetingMixer(sampleRate: 16_000)
        mixer.append(constant(0.1, 5_600), from: .mic, at: 0.35)
        let whole = mixer.advance(to: 0.35)
        #expect(whole.count == 3)  // only whole frames while running
        let rest = mixer.flush(to: 0.35)
        #expect(whole.reduce(0) { $0 + $1.count } + rest.reduce(0) { $0 + $1.count } == 5_600)  // 0.35 s
        #expect(mixer.emittedSamples == 5_600)
        #expect(mixer.flush(to: 0.35).isEmpty)
        #expect(mixer.advance(to: 0.35).isEmpty)
    }

    @Test func anEmptyMeetingHasAnEmptyMix() {
        var mixer = MeetingMixer(sampleRate: 16_000)
        #expect(mixer.advance(to: 0).isEmpty)
        #expect(mixer.flush(to: 0).isEmpty)
    }

    @Test func overlappingSourcesAreScaledDownWithoutClippingAndQuietMixesAreUntouched() {
        var mixer = MeetingMixer(sampleRate: 16_000)
        let loud = constant(0.8, frame / 2) + constant(0.4, frame / 2)
        mixer.append(loud, from: .mic, at: 0.1)
        mixer.append(loud, from: .system, at: 0.1)
        let hot = mixer.advance(to: 0.1)[0]
        #expect(hot.allSatisfy { abs($0) <= 1.0 })
        #expect(abs(hot[0] - 1.0) < 1e-5)  // 1.6 scaled to 1.0 ...
        #expect(abs(hot[frame - 1] - 0.5) < 1e-5)  // ... the balance inside the frame is kept

        mixer.append(constant(0.5, frame), from: .mic, at: 0.2)
        #expect(approx(mixer.advance(to: 0.2)[0], 0.5))
    }

    // A1: a source is placed by counting its own samples from its start, so a backlog that arrives at once
    // keeps its place on the timeline; only a count that runs ahead of the clock is pulled back.
    @Test func aBacklogThatArrivesAtOnceKeepsItsPlaceOnTheTimeline() {
        var mixer = MeetingMixer(sampleRate: 16_000)
        mixer.begin(.mic, at: 0)
        mixer.append(constant(0.1, 32_000) + constant(0.9, 16_000), from: .mic, at: 3)  // 3 s of audio at once
        let frames = mixer.advance(to: 3)
        #expect(frames.count == 30)
        #expect(frames[..<20].allSatisfy { approx($0, 0.1) })
        #expect(frames[20...].allSatisfy { approx($0, 0.9) })
    }

    @Test func aCountThatRunsAheadOfTheClockIsPulledBackToIt() {
        var mixer = MeetingMixer(sampleRate: 16_000, maxLead: 0.5)
        mixer.begin(.mic, at: 0)
        mixer.append(constant(0.1, 8_000), from: .mic, at: 0.5)
        mixer.append(constant(0.9, 32_000), from: .mic, at: 0.6)  // 2 s more by 0.6 s: impossible, so it ends at 0.6 s
        let frames = mixer.advance(to: 0.6)
        #expect(frames.count == 6)
        #expect(frames.allSatisfy { approx($0, 0.9) }, "the newest audio is where the clock puts it")
    }

    @Test func aBurstAfterADelayedStartStaysAlignedAndAudibleAndTheMixIsAsLongAsTheMeeting() {
        var mixer = MeetingMixer(sampleRate: 16_000)
        mixer.begin(.mic, at: 0)
        mixer.begin(.system, at: 1.0)  // the system tap took a second to start
        // The mic's first second was queued meanwhile and arrives at once, in small chunks.
        for _ in 0..<50 { mixer.append(constant(0.25, 320), from: .mic, at: 1.0) }
        var mix: [Float] = []
        for step in 11...50 {
            let t = Double(step) / 10
            mixer.append(constant(0.25, 1_600), from: .mic, at: t)
            mixer.append(constant(0.5, 1_600), from: .system, at: t)
            mix += mixer.advance(to: t - 0.2).flatMap { $0 }  // the session runs the mix 0.2 s behind the clock
        }
        mix += mixer.flush(to: 5.0).flatMap { $0 }
        #expect(mix.count == 80_000, "5 s of meeting, 5 s of mix")
        #expect(approx(Array(mix[..<16_000]), 0.25), "the queued second is where it was heard")
        #expect(approx(Array(mix[16_000...]), 0.75), "the mic stays audible next to the system audio")
    }

    @Test func aSourceThatStartsLateLinesUpWithWhereItStarted() {
        var mixer = MeetingMixer(sampleRate: 16_000)
        mixer.begin(.system, at: 0.5)
        mixer.append(constant(0.5, 1_600), from: .system, at: 0.65)  // delivered a little after it was heard
        let frames = mixer.advance(to: 0.7)
        #expect(frames[..<5].allSatisfy { approx($0, 0) })
        #expect(approx(frames[5], 0.5), "0.5-0.6 s, where its first sample belongs")
        #expect(approx(frames[6], 0))
    }

    @Test func aSourceThatStaysLateIsPlacedByTheClockAgain() {
        var mixer = MeetingMixer(sampleRate: 16_000)
        mixer.begin(.mic, at: 0)
        var frames: [[Float]] = []
        for step in 1...10 {  // live until 1 s
            mixer.append(constant(0.3, 1_600), from: .mic, at: Double(step) / 10)
            frames += mixer.advance(to: Double(step) / 10 - 0.2)
        }
        for step in 11...15 { frames += mixer.advance(to: Double(step) / 10 - 0.2) }  // half a second lost, unreported
        for step in 16...30 {
            mixer.append(constant(0.3, 1_600), from: .mic, at: Double(step) / 10)
            frames += mixer.advance(to: Double(step) / 10 - 0.2)
        }
        #expect(frames.count == 28)
        #expect(frames[..<10].allSatisfy { approx($0, 0.3) })
        #expect(frames[21...].allSatisfy { approx($0, 0.3) }, "within half a second it is heard again")
    }

    @Test func aSourceNobodyBeganIsPlacedByItsFirstChunksArrival() {
        var mixer = MeetingMixer(sampleRate: 16_000)
        mixer.append(constant(0.5, frame), from: .system, at: 1.0)  // a source that starts late: 0.9-1.0 s
        let frames = mixer.advance(to: 1.0)
        #expect(frames[..<9].allSatisfy { approx($0, 0) })
        #expect(approx(frames[9], 0.5))
    }

    @Test func aGapTheSourceReportsStaysSilent() {
        var mixer = MeetingMixer(sampleRate: 16_000)
        mixer.append(constant(0.2, frame), from: .mic, at: 0.1)
        // A1: gaps come from the session (a source's resumption), not from arrival times.
        mixer.skip(.mic, seconds: 0.3)  // came back after 0.3 s of nothing
        mixer.append(constant(0.4, frame), from: .mic, at: 0.5)
        let frames = mixer.advance(to: 0.5)
        #expect(approx(frames[0], 0.2))
        #expect(frames[1...3].allSatisfy { approx($0, 0) })
        #expect(approx(frames[4], 0.4))
    }

    @Test func jitterBetweenChunksIsNotAGap() {
        var mixer = MeetingMixer(sampleRate: 16_000)
        mixer.append(constant(0.2, frame / 2), from: .mic, at: 0.05)
        mixer.append(constant(0.2, frame / 2), from: .mic, at: 0.11)  // 10 ms late: still contiguous
        #expect(approx(mixer.advance(to: 0.1)[0], 0.2))
    }

    @Test func audioThatArrivesAfterItsFrameWentOutIsDropped() {
        var mixer = MeetingMixer(sampleRate: 16_000)
        _ = mixer.advance(to: 1.0)
        mixer.append(constant(0.5, frame), from: .mic, at: 0.5)  // belongs to 0.4-0.5 s: far too late
        #expect(mixer.advance(to: 1.1).allSatisfy { approx($0, 0) })
        mixer.append(constant(0.5, frame), from: .mic, at: 1.2)
        #expect(approx(mixer.advance(to: 1.2)[0], 0.5))
    }

    @Test func framesFollowTheSampleRate() {
        var mixer = MeetingMixer(sampleRate: 48_000)
        mixer.append(constant(0.5, 4_800), from: .mic, at: 0.1)
        let frames = mixer.advance(to: 0.1)
        #expect(frames.count == 1 && frames[0].count == 4_800)
    }

    // MARK: A source that runs behind the clock

    /// Drives `mixer` the way the session does: a ticker every 50 ms cuts the mix 0.2 s behind the clock, and
    /// the mic delivers chunk `k` (its samples all `value(k)`) at `arrival(k)`. At the end the mix is flushed to
    /// the last arrival, the meeting's end. Calls `each` with every frame of the mix.
    func runOnTheSessionCadence(
        _ mixer: inout MeetingMixer, chunks: Int, chunkSamples: Int, arrival: (Int) -> TimeInterval,
        value: (Int) -> Float = { _ in 0.25 }, each: ([Float]) -> Void
    ) -> TimeInterval {
        var tick = 0.05
        var meetingEnd: TimeInterval = 0
        for k in 0..<chunks {
            let at = arrival(k)
            while tick < at - 1e-9 {
                for frame in mixer.advance(to: max(0, tick - 0.2)) { each(frame) }
                tick += 0.05
            }
            mixer.append(constant(value(k), chunkSamples), from: .mic, at: at)
            meetingEnd = at
        }
        for frame in mixer.flush(to: meetingEnd) { each(frame) }
        return meetingEnd
    }

    @Test func aSourceThatRunsBehindTheClockLosesNothingOnTheSessionCadence() {
        var mixer = MeetingMixer(sampleRate: 16_000)
        mixer.begin(.mic, at: 0)
        let chunk = 1_360  // 85 ms, a mic tap's buffer
        // Chunk k was heard over [0.085 k, 0.085 (k + 1)) and arrives 0.15 s after it ended.
        var heard = [Int: Int]()
        _ = runOnTheSessionCadence(
            &mixer, chunks: 118, chunkSamples: chunk, arrival: { 0.085 * Double($0 + 1) + 0.15 },
            value: { Float($0 + 1) / 1_024 }
        ) { frame in
            for v in frame where v != 0 { heard[Int((v * 1_024).rounded()) - 1, default: 0] += 1 }
        }
        let afterOneSecond = (0..<118).filter { 0.085 * Double($0 + 1) + 0.15 > 1 }
        let lost = afterOneSecond.filter { heard[$0, default: 0] != chunk }
        #expect(lost.isEmpty, "chunks cut short after the first second: \(lost.count) of \(afterOneSecond.count)")
    }

    @Test func aDeviceClockSlowerThanTheHostLosesAlmostNothingOverALongMeeting() {
        // A low sample rate keeps half an hour of audio cheap; the timing is the same as at 16 kHz.
        let rate = 1_600.0
        var mixer = MeetingMixer(sampleRate: rate)
        mixer.begin(.mic, at: 0)
        let chunk = 136  // 85 ms
        let chunks = 21_000  // ~30 min
        let slow = 1 + 100e-6  // +100 ppm: the device's second lasts a little longer than the host's
        var mixed = 0, length = 0
        let end = runOnTheSessionCadence(
            &mixer, chunks: chunks, chunkSamples: chunk, arrival: { 0.085 * Double($0 + 1) * slow + 0.01 }
        ) { frame in
            length += frame.count
            mixed += frame.reduce(0) { $0 + (abs($1 - 0.25) < 1e-6 ? 1 : 0) }
        }
        let delivered = chunks * chunk
        let lost = Double(delivered - mixed) / Double(delivered)
        #expect(lost < 0.001, "lost \(lost * 100) % of the mic")
        #expect(length == Int((end * rate).rounded()), "the mix is as long as the meeting")
    }

    @Test func aRestartGapNobodyReportedLosesNothingAfterIt() {
        var mixer = MeetingMixer(sampleRate: 16_000)
        mixer.begin(.mic, at: 0)
        let chunk = 1_360
        // At chunk 60 (~5 s) the mic restarts: 0.12 s pass with nothing, below the session's gap tolerance,
        // so nobody tells the mixer.
        let gap = 0.12
        var heard = [Int: Int]()
        _ = runOnTheSessionCadence(
            &mixer, chunks: 140, chunkSamples: chunk,
            arrival: { 0.085 * Double($0 + 1) + 0.01 + ($0 >= 60 ? gap : 0) }, value: { Float($0 + 1) / 1_024 }
        ) { frame in
            for v in frame where v != 0 { heard[Int((v * 1_024).rounded()) - 1, default: 0] += 1 }
        }
        let lost = (60..<140).filter { heard[$0, default: 0] != chunk }
        #expect(lost.isEmpty, "chunks cut short after the gap: \(lost.count) of 80")
    }
}
