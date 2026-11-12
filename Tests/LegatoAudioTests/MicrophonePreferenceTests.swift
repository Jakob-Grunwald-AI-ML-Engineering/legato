import AVFAudio
import Foundation
import LegatoCore
import Testing
@testable import LegatoAudio

private func input(_ id: String, _ kind: AudioInputCandidate.Kind, uid: String? = nil, alive: Bool = true) -> AudioInputCandidate {
    .init(id: id, name: id, kind: kind, available: alive, channels: 1, sampleRate: 48_000, uid: uid)
}

private let desk = [input("70", .continuity, uid: "iphone-uid"), input("55", .bluetooth, uid: "airpods-uid"),
                    input("60", .wired, uid: "usb-uid"), input("50", .builtIn, uid: "builtin-uid"),
                    input("80", .virtual, uid: "blackhole-uid")]

@Test(arguments: [MicrophonePreference.automatic, .systemDefault, .device(uid: "BuiltInMicrophoneDevice")])
func microphonePreferenceRoundTripsThroughItsStoredValue(_ preference: MicrophonePreference) {
    #expect(MicrophonePreference(storageValue: preference.storageValue) == preference)
}

@Test(arguments: [nil, "", "device:", "bogus"])
func unknownStoredMicrophoneReadsAsAutomatic(_ value: String?) {
    #expect(MicrophonePreference(storageValue: value) == .automatic)
}

@Test func automaticRanksBuiltInOverWiredOverAirPodsOverIPhoneWhateverTheDefault() {
    let order = AudioInputCandidate.ordered(desk, preference: .automatic, defaultID: "70")
    #expect(order.map(\.id) == ["50", "60", "55", "70"])
}

@Test func systemDefaultGoesFirstWithAutomaticAsFallback() {
    let order = AudioInputCandidate.ordered(desk, preference: .systemDefault, defaultID: "70")
    #expect(order.map(\.id) == ["70", "50", "60", "55"])
    #expect(AudioInputCandidate.ordered(desk, preference: .systemDefault, defaultID: nil).map(\.id) == ["50", "60", "55", "70"])
}

@Test func chosenDeviceGoesFirstByUIDEvenWhenAutomaticWouldSkipIt() {
    #expect(AudioInputCandidate.ordered(desk, preference: .device(uid: "usb-uid"), defaultID: nil).map(\.id) == ["60", "50", "55", "70"])
    #expect(AudioInputCandidate.ordered(desk, preference: .device(uid: "blackhole-uid"), defaultID: nil).first?.id == "80")
}

@Test func chosenDeviceThatIsGoneOrDeadFallsBackToAutomatic() {
    #expect(AudioInputCandidate.ordered(desk, preference: .device(uid: "unplugged"), defaultID: nil).map(\.id) == ["50", "60", "55", "70"])
    let dead = [input("60", .wired, uid: "usb-uid", alive: false), input("50", .builtIn)]
    #expect(AudioInputCandidate.ordered(dead, preference: .device(uid: "usb-uid"), defaultID: nil).map(\.id) == ["50"])
}

/// A MacBook Pro's built-in microphone is a three-channel array; the plain AVAudioFormat initializer refuses more
/// than two channels, which made dictation skip the built-in mic for a Continuity iPhone.
@Test func threeChannelBuiltInMicrophoneConvertsToMonoFromItsFirstChannel() throws {
    let format = try #require(BufferConverter.deinterleavedFloat(sampleRate: 48_000, channels: 3))
    #expect(format.channelCount == 3 && !format.isInterleaved && format.commonFormat == .pcmFormatFloat32)
    let spec = AudioFormatSpec(sampleRate: 48_000, channelCount: 1)
    let converter = try #require(BufferConverter.forInput(format, to: spec))
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 480))
    buffer.frameLength = 480
    let channels = try #require(buffer.floatChannelData)
    for i in 0..<480 { channels[0][i] = 0.25; channels[1][i] = 1; channels[2][i] = -1 }
    let chunk = try #require(converter.convert(buffer))
    #expect(!chunk.samples.isEmpty)
    #expect(chunk.samples.allSatisfy { abs($0 - 0.25) < 0.01 })
}
