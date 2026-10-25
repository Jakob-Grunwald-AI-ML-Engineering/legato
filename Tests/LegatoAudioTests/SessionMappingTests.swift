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
        let o = SessionDescription(AudioPolicy.duckMusicPauseSpoken.sessionConfig).avOptions
        #expect(o.contains(.duckOthers))
        #expect(o.contains(.interruptSpokenAudioAndMixWithOthers))
        #expect(!o.contains(.mixWithOthers))
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
