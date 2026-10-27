import Testing
import LegatoCore
@testable import LegatoAudio

@Suite struct SessionMappingTests {
    @Test func pauseOthersHasNeitherMixNorDuck() {
        let d = SessionDescription(AudioPolicy.pauseOthers.sessionConfig)
        #expect(d.category == .playAndRecord)
        #expect(!d.mixWithOthers)
        #expect(!d.duckOthers)
        #expect(d.allowBluetoothA2DP)
        #expect(d.defaultToSpeaker)
    }

    @Test func duckMusicPauseSpokenMapsDuckAndInterruptSpoken() {
        let d = SessionDescription(AudioPolicy.duckMusicPauseSpoken.sessionConfig)
        #expect(d.duckOthers)
        #expect(d.interruptSpokenAudio)
        #expect(!d.mixWithOthers)
        #expect(!SessionDescription(AudioPolicy.duckOthers.sessionConfig).interruptSpokenAudio)
    }

    #if os(iOS)
    @Test func duckMusicPauseSpokenAvOptions() {
        // `.interruptSpokenAudioAndMixWithOthers` carries the mix bit itself (raw 0x11), so the exact set
        // is asserted rather than the absence of `.mixWithOthers`.
        let o = SessionDescription(AudioPolicy.duckMusicPauseSpoken.sessionConfig).avOptions
        #expect(o == [.duckOthers, .interruptSpokenAudioAndMixWithOthers, .allowBluetoothA2DP, .defaultToSpeaker])
    }
    #endif

    @Test func meetingSessionMapsMixAndBluetoothHFPOnly() {
        let d = SessionDescription(SessionConfig.meeting)
        #expect(d.category == .playAndRecord)
        #expect(d.mode == .default)
        #expect(d.mixWithOthers)
        #expect(d.allowBluetoothHFP)
        #expect(!d.duckOthers)
        #expect(!d.allowBluetoothA2DP)
        #expect(!d.defaultToSpeaker)
        #expect(!d.interruptSpokenAudio)
    }

    @Test func onlyDictationPinsTheBuiltInMic() {
        // A meeting lets a Bluetooth headset be the input (AirPods), so it must not pin the built-in mic.
        #expect(SessionDescription(SessionConfig.meeting).prefersBuiltInMic == false)
        for policy in AudioPolicy.allCases {
            #expect(SessionDescription(policy.sessionConfig).prefersBuiltInMic)
        }
    }

    @Test func dictationPoliciesDoNotAllowBluetoothHFP() {
        for policy in AudioPolicy.allCases {
            #expect(!SessionDescription(policy.sessionConfig).allowBluetoothHFP)
        }
    }

    #if os(iOS)
    @Test func meetingSessionAvOptions() {
        #expect(SessionDescription(SessionConfig.meeting).avOptions == [.mixWithOthers, .allowBluetoothHFP])
    }
    #endif

    @Test func duckOthersHasDuck() {
        let d = SessionDescription(AudioPolicy.duckOthers.sessionConfig)
        #expect(d.duckOthers)
        #expect(!d.mixWithOthers)
    }

    @Test func mixWithOthersHasMix() {
        let d = SessionDescription(AudioPolicy.mixWithOthers.sessionConfig)
        #expect(d.mixWithOthers)
        #expect(!d.duckOthers)
    }

    #if os(macOS)
    @Test func macOSSupportsNoPolicies() {
        #expect(AudioSessionController().supportedPolicies.isEmpty)
    }

    @Test func macOSActivateDeactivateAreNoOps() throws {
        let c = AudioSessionController()
        try c.activate(AudioPolicy.duckOthers.sessionConfig)
        c.deactivate()
    }
    #endif
}
