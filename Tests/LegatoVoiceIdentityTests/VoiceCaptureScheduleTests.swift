import Foundation
import Testing
@testable import LegatoVoiceIdentity

/// The recording's schedule runs on recorded audio. A step starts when it is shown, a reading step ends only when
/// the reader stops (or on Next sentence), and the labels match what was spoken.
@Suite struct VoiceCaptureScheduleTests {
    private let rate = 16000.0
    private func speech(_ seconds: Double, level: Float = 0.1) -> [Float] {
        (0..<Int(seconds * 16000)).map { sin(Float($0) * 0.09) * level * 1.41 }
    }
    private func silence(_ seconds: Double) -> [Float] { [Float](repeating: 0.0005, count: Int(seconds * 16000)) }
    private func script(_ steps: [VoiceScriptStep]) -> VoiceReadingScript { VoiceReadingScript(language: "en", steps: steps, nextCursor: 0) }
    /// Shows the next step at once, as the sheet does on its next look.
    private func show(_ schedule: inout VoiceCaptureSchedule) { schedule.markShown(step: schedule.stepIndex) }

    @Test func quietStepsLastTheirAudioTimeFromWhenShownAndLaterAudioIsNotTaken() {
        var schedule = VoiceCaptureSchedule(script: script([.init(kind: .quiet, seconds: 10), .init(kind: .quiet, seconds: 10)]))
        // However the audio arrives (tiny chunks, one large burst), each pause lasts 10 s of audio.
        for _ in 0..<500 { schedule.consume(silence(0.01)) }
        #expect(schedule.stepIndex == 0 && schedule.quietRemaining == 5)
        schedule.consume(silence(6))
        #expect(schedule.stepIndex == 1 && !schedule.stepShown)
        // The next pause starts when it is shown, 1 s later here; the audio in between belongs to neither.
        schedule.consume(silence(1)); show(&schedule)
        let taken = schedule.consume(silence(30))
        #expect(schedule.isFinished && taken == Int(10 * rate))
        #expect(schedule.intervals == [.init(kind: .quiet, startMs: 0, endMs: 10_000), .init(kind: .quiet, startMs: 12_000, endMs: 22_000)])
        #expect(schedule.progress == 1)
    }

    @Test func aReadingStepEndsWhenTheReaderStopsNotOnAShortPause() {
        var schedule = VoiceCaptureSchedule(script: script([.init(kind: .reading("One."), seconds: 8), .init(kind: .reading("Two."), seconds: 8)]))
        schedule.consume(silence(0.3))
        schedule.consume(speech(2.5)); schedule.consume(silence(0.6)); schedule.consume(speech(3))
        // Speech with a breath in it keeps the sentence going.
        #expect(schedule.stepIndex == 0)
        schedule.consume(silence(1.5))
        // About 1.2 s of silence after the sentence moves on: 0.3 + 2.5 + 0.6 + 3 + 1.2 s.
        #expect(schedule.stepIndex == 1)
        let end = schedule.intervals[0].endMs
        #expect(abs(end - 7_600) <= 40)
        #expect(schedule.intervals[0] == .init(kind: .reading, startMs: 0, endMs: end, prompt: "One."))
    }

    @Test func anEarlyPauseDoesNotEndASentenceBeforeHalfItsEstimate() {
        var schedule = VoiceCaptureSchedule(script: script([.init(kind: .reading("Long."), seconds: 10), .init(kind: .quiet, seconds: 10)]))
        schedule.consume(speech(2.5)); schedule.consume(silence(1.5))
        #expect(schedule.stepIndex == 0)
        schedule.consume(silence(2))
        // Half the estimate (5 s) has passed and the reader is silent: on to the pause.
        #expect(schedule.stepIndex == 1 && abs(schedule.intervals[0].endMs - 5_000) <= 40)
    }

    @Test func aLateStartNeverMovesOnBeforeTheReaderSpeaksAndShowsAHint() {
        var schedule = VoiceCaptureSchedule(script: script([.init(kind: .reading("Late."), seconds: 9), .init(kind: .quiet, seconds: 10)]))
        schedule.consume(silence(10))
        #expect(schedule.stepIndex == 0 && schedule.hint == nil)
        // Well past its tolerant maximum and nothing said: the sentence stays, with a hint to read it.
        schedule.consume(silence(10))
        #expect(schedule.stepIndex == 0 && schedule.hint == .readAloud)
        // A cough is not reading the sentence.
        schedule.consume(speech(0.3)); schedule.consume(silence(3))
        #expect(schedule.stepIndex == 0)
        schedule.consume(speech(6))
        #expect(schedule.stepIndex == 0 && schedule.hint == .finishWithPause)
        schedule.consume(silence(1.5))
        #expect(schedule.stepIndex == 1)
        #expect(abs(schedule.intervals[0].endMs - 30_500) <= 40)
    }

    @Test func aSlowReaderIsNeverCutOffMidSpeech() {
        var schedule = VoiceCaptureSchedule(script: script([.init(kind: .reading("Slow."), seconds: 9), .init(kind: .quiet, seconds: 10)]))
        // Reading with breaths for 40 s, far past 1.6 times the estimate: the sentence goes on, with a hint.
        for _ in 0..<20 { schedule.consume(speech(1.7, level: 0.05)); schedule.consume(silence(0.3)) }
        #expect(schedule.stepIndex == 0 && schedule.hint == .finishWithPause)
        schedule.consume(silence(1.3))
        #expect(schedule.stepIndex == 1 && abs(schedule.intervals[0].endMs - 40_900) <= 40)
    }

    @Test func theLastSentenceEndsOnlyAfterItsSpeechEnds() {
        var schedule = VoiceCaptureSchedule(script: script([.init(kind: .reading("A."), seconds: 5), .init(kind: .reading("B."), seconds: 5)]))
        schedule.consume(speech(3)); schedule.consume(silence(1.3))
        #expect(schedule.stepIndex == 1)
        show(&schedule)
        let shown = Double(schedule.sampleCount) / rate * 1000
        schedule.consume(speech(25))
        #expect(!schedule.isFinished)
        let taken = schedule.consume(silence(3))
        #expect(schedule.isFinished && abs(Double(taken) / rate - 1.2) <= 0.03)
        #expect(schedule.intervals.last?.prompt == "B." && schedule.intervals.last?.startMs == shown)
        #expect(abs(schedule.intervals.last!.endMs - (shown + 26_200)) <= 40)
    }

    @Test func backgroundSpeechInAPauseStaysQuietAndTheNextSentenceStartsWhenShown() {
        var schedule = VoiceCaptureSchedule(script: script([.init(kind: .reading("A."), seconds: 6), .init(kind: .quiet, seconds: 10),
                                                           .init(kind: .reading("B."), seconds: 6)]))
        schedule.consume(speech(3)); schedule.consume(silence(1.3))
        #expect(schedule.stepIndex == 1 && !schedule.stepShown)
        schedule.consume(silence(0.1)); show(&schedule)
        let quietStart = Double(schedule.sampleCount) / rate * 1000
        // Somebody talks in the room during the pause: it stays 10 s and is labelled quiet.
        schedule.consume(silence(1)); schedule.consume(speech(4, level: 0.05)); schedule.consume(silence(5.5))
        #expect(schedule.stepIndex == 2 && !schedule.stepShown)
        #expect(schedule.intervals[1] == .init(kind: .quiet, startMs: quietStart, endMs: quietStart + 10_000))
        // Audio before B is shown is in no step: a reader who has not seen B yet is not labelled as reading it.
        schedule.consume(silence(0.5)); schedule.consume(speech(2)); schedule.consume(silence(5))
        #expect(schedule.stepIndex == 2 && schedule.intervals.count == 2)
        show(&schedule)
        let readingStart = Double(schedule.sampleCount) / rate * 1000
        schedule.consume(silence(0.4)); schedule.consume(speech(3)); schedule.consume(silence(1.3))
        #expect(schedule.isFinished && schedule.intervals[2].startMs == readingStart && schedule.intervals[2].prompt == "B.")
    }

    @Test func nextSentenceAppliesOnlyToTheStepOnScreen() {
        var schedule = VoiceCaptureSchedule(script: script([.init(kind: .reading("A."), seconds: 8), .init(kind: .reading("B."), seconds: 8),
                                                           .init(kind: .quiet, seconds: 10)]))
        schedule.consume(speech(2))
        schedule.requestAdvance(step: 0); schedule.consume(speech(0.1))
        #expect(schedule.stepIndex == 1)
        // A second tap meant for A, before B is on screen, does not skip B.
        schedule.requestAdvance(step: 0); schedule.consume(silence(0.1)); show(&schedule)
        schedule.requestAdvance(step: 1); schedule.consume(silence(0.5))
        #expect(schedule.stepIndex == 1)
        // Skipping B without reading it moves on, but B is not labelled as read.
        schedule.consume(silence(1)); schedule.requestAdvance(step: 1); schedule.consume(silence(0.05))
        #expect(schedule.stepIndex == 2)
        #expect(schedule.intervals.map(\.prompt) == ["A."])
        // Next sentence does nothing in a pause.
        show(&schedule)
        schedule.requestAdvance(step: 2); schedule.consume(silence(1))
        #expect(schedule.stepIndex == 2 && schedule.quietRemaining == 9)
    }

    @Test func aRecordingThatNeverFinishesStopsAtItsCap() {
        var schedule = VoiceCaptureSchedule(script: script([.init(kind: .reading("A."), seconds: 5)]))
        #expect(schedule.capSeconds == 240)
        let taken = schedule.consume(silence(300))
        #expect(schedule.isOverrun && !schedule.isFinished && taken == Int(240 * rate))
        #expect(schedule.consume(silence(1)) == 0)
    }

    @Test func progressOnlyMovesForward() {
        var schedule = VoiceCaptureSchedule(script: VoiceReadingScript.setting(language: "en", cursor: 0))
        var last = 0.0
        var tick = 0
        while !schedule.isFinished {
            tick += 1
            schedule.consume(tick % 20 < 15 ? speech(0.25) : silence(0.25))
            show(&schedule)
            #expect(schedule.progress >= last)
            last = schedule.progress
            #expect(tick < 2000)
        }
        #expect(last == 1)
    }

    /// A simulated reader in front of the sheet: it sees a step 0.1 s after the step begins, starts reading after its
    /// reaction time (one starts very late), reads with short breaths (one reads very slowly, the last one at
    /// length), and somebody talks in the room during each pause. Every word lands in the right label.
    @Test(arguments: [VoiceReadingScript.setting(language: "en", cursor: 0), VoiceReadingScript.firstSetup(language: "de")])
    func labelsMatchWhatWasSpoken(_ script: VoiceReadingScript) {
        var schedule = VoiceCaptureSchedule(script: script)
        let frame = 0.02
        let sentences = script.steps.compactMap(\.prompt)
        func reader(_ sentence: Int) -> (reaction: Double, seconds: Double) {
            let estimate = VoiceReadingScript.readingSeconds(for: sentences[sentence])
            if sentence == 1 { return (11, estimate * 0.9) }                     // starts late
            if sentence == 2 { return (1, estimate * 2.5) }                      // reads slowly
            if sentence == sentences.count - 1 { return (0.8, estimate * 3) }    // a long last sentence
            return (0.6 + Double(sentence % 3) * 0.4, estimate * 0.8)
        }
        var shownStep = -1, shownAt = 0, lag = 0
        var spoken: [(ms: Double, step: Int)] = []
        var ticks = 0
        while !schedule.isFinished {
            ticks += 1
            #expect(ticks < 30_000)
            if ticks >= 30_000 { return }
            if !schedule.stepShown {
                lag += 1
                if lag >= 5 { schedule.markShown(step: schedule.stepIndex); lag = 0 }
            }
            if schedule.stepShown, schedule.stepIndex != shownStep { shownStep = schedule.stepIndex; shownAt = schedule.sampleCount }
            var talking = false
            if schedule.stepShown {
                let since = Double(schedule.sampleCount - shownAt) / rate
                if script.steps[shownStep].prompt != nil {
                    let (reaction, seconds) = reader(script.steps.prefix(shownStep).filter { $0.prompt != nil }.count)
                    talking = since >= reaction && since < reaction + seconds && (since - reaction).truncatingRemainder(dividingBy: 2) < 1.7
                } else {
                    talking = since >= 2 && since < 8
                }
            }
            if talking { spoken.append((Double(schedule.sampleCount) / rate * 1000, shownStep)) }
            schedule.consume(talking ? speech(frame, level: script.steps[shownStep].prompt == nil ? 0.05 : 0.1) : silence(frame))
        }
        #expect(!schedule.isOverrun)
        #expect(schedule.intervals.filter { $0.kind == .reading }.map(\.prompt) == sentences)
        #expect(schedule.intervals.filter { $0.kind == .quiet }.count == script.steps.count - sentences.count)
        for (ms, step) in spoken {
            let expected = script.steps[step]
            let label = schedule.intervals.first { $0.startMs <= ms && ms + frame * 1000 <= $0.endMs }
            #expect(label?.prompt == expected.prompt && label?.kind == (expected.prompt == nil ? .quiet : .reading),
                    "speech at \(ms) ms of step \(step)")
        }
        // Each quiet label is exactly its 10 s pause.
        for quiet in schedule.intervals where quiet.kind == .quiet { #expect(abs(quiet.endMs - quiet.startMs - 10_000) <= 1) }
    }
}
