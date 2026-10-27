import AVFAudio
import Testing
import LegatoCore
@testable import LegatoAudio

/// The system-audio stream recorded 26 s of a 60 s meeting when the output (AirPods in headset mode) ran
/// at 24 kHz and the converter had been built for another rate. The Core Audio reads are hardware-only;
/// these pin the decisions made from what was read.
@Suite struct TapRateTests {
    /// `seconds` of a 440 Hz tone with `actualRate` and `channels`, converted the way the tap's IO block does
    /// after `TapRate` picked the converter's input rate from what the tap reported and the device runs at.
    private func convertedSeconds(
        actualRate: Double, channels: AVAudioChannelCount, reported: Double, deviceNominal: Double?, seconds: Double = 1
    ) throws -> Double {
        let rate = TapRate.effective(reported: reported, deviceNominal: deviceNominal)
        let format = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: channels, interleaved: false))
        // The buffer holds what the device delivered: `actualRate` frames per second, however the tap was described.
        let frames = AVAudioFrameCount(actualRate * seconds)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        for ch in 0..<Int(channels) {
            let p = try #require(buffer.floatChannelData?[ch])
            for i in 0..<Int(frames) { p[i] = 0.5 * sinf(2 * .pi * 440 * Float(i) / Float(actualRate)) }
        }
        let converter = try #require(BufferConverter(from: format, to: AudioFormatSpec(sampleRate: 16_000, channelCount: 1)))
        let chunk = try #require(converter.convert(buffer))
        return Double(chunk.samples.count) / 16_000
    }

    @Test(arguments: [
        (24_000.0, AVAudioChannelCount(1)), (24_000.0, 2), (48_000.0, 2), (44_100.0, 2), (48_000.0, 1),
    ])
    func everyDeviceRateYieldsOneSecondOfSixteenKilohertz(rate: Double, channels: AVAudioChannelCount) throws {
        // The tap still describes itself as it did before the device switched; the device rate decides.
        let seconds = try convertedSeconds(actualRate: rate, channels: channels, reported: 48_000, deviceNominal: rate)
        #expect(abs(seconds - 1) < 0.01, "\(rate) Hz x\(channels): \(seconds) s")
    }

    @Test func aTapReportedAtTheWrongRateWouldHaveShrunkTheAudio() throws {
        // 24 kHz audio handled as 48 kHz: half the duration (the field symptom).
        let wrong = try convertedSeconds(actualRate: 24_000, channels: 2, reported: 48_000, deviceNominal: nil)
        #expect(abs(wrong - 1) > 0.4)
    }

    @Test func theDeviceRateWinsOverTheReportedOne() {
        #expect(TapRate.effective(reported: 48_000, deviceNominal: 24_000) == 24_000)
    }

    @Test(arguments: [nil, 0.0, -1.0])
    func anUnreadableDeviceRateFallsBackToTheReportedOne(nominal: Double?) {
        #expect(TapRate.effective(reported: 44_100, deviceNominal: nominal) == 44_100)
    }

    @Test func aChangedDeviceRateAsksForARebuild() {
        #expect(TapRate.needsRebuild(built: 48_000, deviceNominal: 24_000))
        #expect(TapRate.needsRebuild(built: 24_000, deviceNominal: 48_000))
    }

    @Test func anUnchangedRateAsksForNothing() {
        #expect(!TapRate.needsRebuild(built: 48_000, deviceNominal: 48_000))
    }

    @Test(arguments: [nil, 0.0, -1.0])
    func anUnreadableRateAsksForNothing(nominal: Double?) {
        #expect(!TapRate.needsRebuild(built: 48_000, deviceNominal: nominal))
    }
}
