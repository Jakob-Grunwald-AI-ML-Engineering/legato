import AVFAudio
import Testing
@testable import LegatoAudio

/// The decisions around a `MicSource` bound to one input device. Binding itself is hardware-only (proven by a
/// probe on a Mac); these cover what AVAudioEngine gets wrong around it.
@Suite struct MicSourceDeviceTests {
    private func format(_ rate: Double, _ channels: AVAudioChannelCount) throws -> AVAudioFormat {
        // More than two channels (voice processing) need a layout.
        let layout = try #require(AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | channels))
        return AVAudioFormat(standardFormatWithSampleRate: rate, channelLayout: layout)
    }

    /// The field bug: the AirPods (24 kHz in headset mode) were the default input; bound to the built-in mic
    /// (48 kHz), the input node still reported 24 kHz, so the tap was refused ("Format mismatch … Failed to
    /// create tap") and no buffer ever arrived.
    @Test func aBoundPlainInputIsTappedAtTheDevicesOwnFormat() throws {
        let stale = try format(24_000, 1), device = try format(48_000, 1)
        let tap = MicSource.tapFormat(output: stale, hardware: device, bound: true, voiceProcessing: false)
        #expect(tap.sampleRate == 48_000 && tap.channelCount == 1)
    }

    @Test func anUnboundInputKeepsTheNodesOutputFormat() throws {
        let output = try format(48_000, 1), hardware = try format(44_100, 2)
        let tap = MicSource.tapFormat(output: output, hardware: hardware, bound: false, voiceProcessing: false)
        #expect(tap.sampleRate == 48_000 && tap.channelCount == 1)
    }

    /// Voice processing delivers its own (multichannel) format, whatever the device's.
    @Test func aVoiceProcessingInputKeepsTheNodesOutputFormat() throws {
        let output = try format(48_000, 7), hardware = try format(44_100, 10)
        let tap = MicSource.tapFormat(output: output, hardware: hardware, bound: true, voiceProcessing: true)
        #expect(tap.sampleRate == 48_000 && tap.channelCount == 7)
    }

    /// Binding posts one configuration change while the engine keeps running on the device; rebuilding on it
    /// made a fresh engine, which bound again and posted again: an endless loop with no audio.
    @Test func aBoundEngineStillRunningOnItsDeviceIsNotRebuilt() {
        #expect(!MicSource.needsRebuild(running: true, current: 92, bound: 92))
    }

    @Test func aBoundEngineThatStoppedIsRebuilt() {
        #expect(MicSource.needsRebuild(running: false, current: 92, bound: 92))
    }

    /// AVAudioEngine moves its unit back to the default input when the default changes.
    @Test func aBoundEngineMovedToAnotherDeviceIsRebuilt() {
        #expect(MicSource.needsRebuild(running: true, current: 220, bound: 92))
        #expect(MicSource.needsRebuild(running: true, current: nil, bound: 92))
    }

    /// Dictation (no device) rebuilds on every configuration change, as before.
    @Test func anUnboundEngineIsAlwaysRebuilt() {
        #expect(MicSource.needsRebuild(running: true, current: 92, bound: nil))
        #expect(MicSource.needsRebuild(running: false, current: nil, bound: nil))
    }
}
