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

    @Test func aSourceThatRunsFarAheadKeepsOnlyItsNewestSecond() {
        var mixer = MeetingMixer(sampleRate: 16_000, maxBacklog: 1)
        mixer.append(constant(0.1, 32_000) + constant(0.9, 16_000), from: .mic, at: 3)  // 3 s of audio at once
        let frames = mixer.advance(to: 3)
        #expect(frames.count == 30)
        #expect(frames[..<20].allSatisfy { approx($0, 0) })
        #expect(frames[20...].allSatisfy { approx($0, 0.9) })
    }

    @Test func aChunkIsPlacedWhereItsArrivalTimePutsIt() {
        var mixer = MeetingMixer(sampleRate: 16_000)
        mixer.append(constant(0.5, frame), from: .system, at: 1.0)  // a source that starts late: 0.9-1.0 s
        let frames = mixer.advance(to: 1.0)
        #expect(frames[..<9].allSatisfy { approx($0, 0) })
        #expect(approx(frames[9], 0.5))
    }

    @Test func aGapInASourcesAudioStaysSilent() {
        var mixer = MeetingMixer(sampleRate: 16_000)
        mixer.append(constant(0.2, frame), from: .mic, at: 0.1)
        mixer.append(constant(0.4, frame), from: .mic, at: 0.5)  // came back after 0.3 s of nothing
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
}
