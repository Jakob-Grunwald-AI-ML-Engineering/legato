import Testing
@testable import LegatoCore

@Suite struct AudioPolicyTests {
    @Test func defaultIsDuck() { #expect(AudioPolicy.default == .duckOthers) }

    @Test func offeredPoliciesExcludePauseOthers() {
        #expect(!AudioPolicy.offeredPolicies.contains(.pauseOthers))
        #expect(Set(AudioPolicy.offeredPolicies) == [.duckOthers, .mixWithOthers])
    }

    @Test func experimentalPoliciesAreNeverOffered() {
        #expect(Set(AudioPolicy.experimentalPolicies) == [.pauseOthers, .duckMusicPauseSpoken])
        #expect(Set(AudioPolicy.offeredPolicies).isDisjoint(with: AudioPolicy.experimentalPolicies))
    }

    @Test func duckMusicPauseSpokenConfig() {
        let c = AudioPolicy.duckMusicPauseSpoken.sessionConfig
        #expect(c.category == .playAndRecord)
        #expect(c.options.contains(.duckOthers))
        #expect(c.options.contains(.interruptSpokenAudio))
        #expect(!c.options.contains(.mixWithOthers))
        #expect(c.options.contains(.allowBluetoothA2DP))
        #expect(c.options.contains(.defaultToSpeaker))
    }

    @Test func duckConfig() {
        let c = AudioPolicy.duckOthers.sessionConfig
        #expect(c.category == .playAndRecord)
        #expect(c.options.contains(.duckOthers))
        #expect(!c.options.contains(.mixWithOthers))
        #expect(c.options.contains(.allowBluetoothA2DP))
        #expect(c.options.contains(.defaultToSpeaker))
    }

    @Test func mixConfig() {
        let c = AudioPolicy.mixWithOthers.sessionConfig
        #expect(c.category == .playAndRecord)
        #expect(c.options.contains(.mixWithOthers))
        #expect(!c.options.contains(.duckOthers))
        #expect(c.options.contains(.allowBluetoothA2DP))
        #expect(c.options.contains(.defaultToSpeaker))
    }

    @Test func pauseConfigHasNeitherMixNorDuck() {
        let c = AudioPolicy.pauseOthers.sessionConfig
        #expect(c.category == .playAndRecord)
        #expect(!c.options.contains(.mixWithOthers))
        #expect(!c.options.contains(.duckOthers))
        #expect(c.options.contains(.allowBluetoothA2DP))
        #expect(c.options.contains(.defaultToSpeaker))
    }

    @Test func bluetoothConfigMixesAndAllowsBluetoothHFPOnly() {
        let c = SessionConfig(options: [.mixWithOthers, .allowBluetoothHFP])
        #expect(c.category == .playAndRecord)
        #expect(c.mode == .default)
        #expect(c.options == [.mixWithOthers, .allowBluetoothHFP])
    }

    @Test func noDictationPolicyAllowsBluetoothHFP() {
        for policy in AudioPolicy.allCases {
            #expect(!policy.sessionConfig.options.contains(.allowBluetoothHFP))
        }
    }
}

@Suite struct TranscriptAssemblerTests {
    @Test func volatileReplacesVolatile() {
        var a = TranscriptAssembler()
        #expect(a.apply(.init(text: "hel", isFinal: false)) == [.replaceVolatile("hel")])
        #expect(a.apply(.init(text: "hello wor", isFinal: false)) == [.replaceVolatile("hello wor")])
        #expect(a.volatileText == "hello wor")
        #expect(a.committedText == "")
    }

    @Test func finalCommitsAndClearsVolatile() {
        var a = TranscriptAssembler()
        _ = a.apply(.init(text: "hello wor", isFinal: false))
        let edits = a.apply(.init(text: "hello world", isFinal: true))
        #expect(edits == [.replaceVolatile(""), .commit(delta: "hello world")])
        #expect(a.committedText == "hello world")
        #expect(a.volatileText == "")
    }

    @Test func finalWithoutVolatileOnlyCommits() {
        var a = TranscriptAssembler()
        #expect(a.apply(.init(text: "hi", isFinal: true)) == [.commit(delta: "hi")])
    }

    @Test func successiveFinalsAccumulate() {
        var a = TranscriptAssembler()
        _ = a.apply(.init(text: "one", isFinal: true))
        _ = a.apply(.init(text: " two", isFinal: true))
        #expect(a.committedText == "one two")
    }

    @Test func emptyFinalCommitsNothing() {
        var a = TranscriptAssembler()
        _ = a.apply(.init(text: "x", isFinal: false))
        #expect(a.apply(.init(text: "", isFinal: true)) == [.replaceVolatile("")])
        #expect(a.committedText == "")
    }

    @Test func streamTagAndRangePassThroughEvent() {
        let e = TranscriptEvent(stream: .system, text: "t", isFinal: true, range: 0..<1.5)
        #expect(e.stream == .system)
        #expect(e.range == 0..<1.5)
    }
}
