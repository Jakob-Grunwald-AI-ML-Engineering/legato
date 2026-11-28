import Foundation
import Synchronization
import Testing
import LegatoAudio
@testable import LegatoAppServices
@testable import LegatoVoiceIdentity

/// The guided recording under a slow, busy app: its clock is the recorded audio, and only missing audio ends it.
@Suite struct VoiceCaptureRecorderTests {
    final class WallClock: Sendable {
        private let seconds = Mutex(1000.0)
        func advance(_ by: Double) { seconds.withLock { $0 += by } }
        var read: @Sendable () -> Double { { self.seconds.withLock { $0 } } }
    }
    private func chunk(_ seconds: Double) -> [Float] { (0..<Int(seconds * 16000)).map { sin(Float($0) * 0.09) * 0.14 } }
    private func quiet(_ seconds: Double) -> [Float] { [Float](repeating: 0.0005, count: Int(seconds * 16000)) }

    @Test func aRecordingDeliveredLateAndInBurstsFinishesWithEverySample() {
        let script = VoiceReadingScript.firstSetup(language: "en")
        let clock = WallClock()
        let recorder = VoiceCaptureRecorder(script: script, stallSeconds: 6, clock: clock.read)
        var fed = 0, bursts = 0
        // The app gets to the audio late: each 5 s of audio (3.5 s read, a pause) arrives as one burst, 8 s of wall
        // time after the last, and the sheet shows a new sentence only then. The recording neither stalls nor loses audio.
        while recorder.snapshot().state == .running {
            clock.advance(5.5)
            #expect(recorder.snapshot().state == .running)
            clock.advance(2.5)
            let snapshot = recorder.snapshot()
            recorder.markShown(step: snapshot.stepIndex)
            for samples in [chunk(3.5), quiet(1.5)] {
                fed += samples.count
                guard recorder.append(samples) else { break }
            }
            bursts += 1
            #expect(bursts < 100)
        }
        #expect(recorder.snapshot().state == .finished)
        let result = recorder.result()
        #expect(result.intervals.count == script.steps.count)
        // Every sample up to the end of the last step is in the recording; each step starts when it was shown.
        #expect(result.samples.count == Int((result.intervals.last!.endMs * 16).rounded()))
        #expect(fed - result.samples.count < 16000)
        #expect(zip(result.intervals, result.intervals.dropFirst()).allSatisfy { $0.endMs <= $1.startMs })
        #expect(Double(bursts) * 8 > script.plannedSeconds)
    }

    @Test func onlyMissingAudioOrAnEndedMicrophoneInterrupts() {
        let script = VoiceReadingScript.setting(language: "en", cursor: 0)
        let clock = WallClock()
        let recorder = VoiceCaptureRecorder(script: script, stallSeconds: 6, clock: clock.read)
        recorder.append(chunk(2))
        clock.advance(5.9)
        #expect(recorder.snapshot().state == .running)
        recorder.append(chunk(0.1))
        clock.advance(6.1)
        #expect(recorder.snapshot().state == .stalled)
        let ended = VoiceCaptureRecorder(script: script, clock: clock.read)
        ended.append(chunk(1))
        ended.markEnded()
        #expect(ended.snapshot().state == .ended)
    }

    @Test func nextSentenceReachesTheScheduleFromAnyThread() {
        let script = VoiceReadingScript.setting(language: "en", cursor: 0)
        let recorder = VoiceCaptureRecorder(script: script)
        recorder.append(chunk(2))
        recorder.requestAdvance(step: 0)
        recorder.append(chunk(0.1))
        let snapshot = recorder.snapshot()
        #expect(snapshot.stepIndex == 1 && snapshot.state == .running)
        #expect(recorder.result().intervals.first?.prompt == script.steps.first?.prompt)
    }

    @Test func aRecordingThatNeverFinishesOverrunsWithAClearMessage() {
        let script = VoiceReadingScript.firstSetup(language: "en")
        let recorder = VoiceCaptureRecorder(script: script)
        // Nobody reads: the first sentence waits, and the recording stops at its cap instead of running on.
        var appended = 0
        while recorder.append(quiet(1)) { appended += 1; #expect(appended < 1000) }
        #expect(recorder.snapshot().state == .overrun && recorder.snapshot().hint == .readAloud)
        let message = VoiceEnrollmentController.failure(VoiceEnrollmentController.EnrollmentError.tooLong(minutes: 4), firstSetup: true, name: "Alone")
        #expect(message.contains("4 minutes"))
    }

    @Test func aMissingMicrophoneSaysWhatHappened() {
        let message = VoiceEnrollmentController.failure(AutomaticInputError.noUsableInput, firstSetup: true, name: "Alone")
        #expect(message == VoiceSetupCopy.noMicrophone && !message.contains("Record"))
    }
}
