import AVFAudio
import Foundation
import LegatoCore
import Testing
@testable import LegatoAppleSpeech

@Suite("Locale resolution")
struct LocaleResolverTests {
    @Test func requestedLocaleWinsOverCurrent() async throws {
        let got = try await LocaleResolver.resolve(
            requested: Locale(identifier: "en_US"), current: Locale(identifier: "de_DE")
        ) { $0 }
        #expect(got.identifier == "en_US")
    }

    @Test func nilFallsBackToCurrent() async throws {
        let got = try await LocaleResolver.resolve(requested: nil, current: Locale(identifier: "de_DE")) { $0 }
        #expect(got.identifier == "de_DE")
    }

    @Test func usesTheSupportedEquivalent() async throws {
        let got = try await LocaleResolver.resolve(requested: Locale(identifier: "en_DE"), current: .current) { _ in
            Locale(identifier: "en_US")
        }
        #expect(got.identifier == "en_US")
    }

    @Test func unsupportedThrowsTypedError() async {
        await #expect(throws: AppleSpeechError.unsupportedLocale("tlh")) {
            _ = try await LocaleResolver.resolve(requested: Locale(identifier: "tlh"), current: .current) { _ in nil }
        }
    }
}

@Suite("Phrase spacing")
struct PhraseSpacerTests {
    @Test func firstFinalHasNoLeadingSpace() {
        var s = PhraseSpacer()
        #expect(s.apply("Hello world.", isFinal: true) == "Hello world.")
    }

    @Test func laterFinalsAreSeparatedByOneSpace() {
        var s = PhraseSpacer()
        _ = s.apply("Hello world.", isFinal: true)
        #expect(s.apply("Second phrase.", isFinal: true) == " Second phrase.")
    }

    @Test func noDoubleSpaceWhenAlreadySeparated() {
        var s = PhraseSpacer()
        _ = s.apply("Hello ", isFinal: true)
        #expect(s.apply("there", isFinal: true) == "there")
        var t = PhraseSpacer()
        _ = t.apply("Hello", isFinal: true)
        #expect(t.apply(" there", isFinal: true) == " there")
    }

    @Test func volatileIsSeparatedFromCommittedButDoesNotCommit() {
        var s = PhraseSpacer()
        _ = s.apply("One.", isFinal: true)
        #expect(s.apply("tw", isFinal: false) == " tw")
        #expect(s.apply("two", isFinal: false) == " two")
        #expect(s.apply("Two.", isFinal: true) == " Two.")
    }

    @Test func volatileBeforeAnyFinalHasNoSpace() {
        var s = PhraseSpacer()
        #expect(s.apply("hel", isFinal: false) == "hel")
    }

    @Test func emptyTextStaysEmpty() {
        var s = PhraseSpacer()
        _ = s.apply("One.", isFinal: true)
        #expect(s.apply("", isFinal: true) == "")
        #expect(s.apply("", isFinal: false) == "")
    }
}

@Suite("PCM packing")
struct PCMPackerTests {
    private let spec = AudioFormatSpec(sampleRate: 16_000, channelCount: 1)

    @Test func float32TargetCopiesSamples() throws {
        let fmt = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false))
        let buf = try #require(PCMPacker.buffer(from: AudioChunk(samples: [0, 0.25, -0.5], format: spec), format: fmt))
        #expect(buf.frameLength == 3)
        #expect(buf.floatChannelData?[0][1] == 0.25)
        #expect(buf.floatChannelData?[0][2] == -0.5)
    }

    @Test func int16TargetScalesAndClamps() throws {
        let fmt = try #require(AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: false))
        let buf = try #require(PCMPacker.buffer(from: AudioChunk(samples: [0, 0.5, -0.5, 2.0, -2.0], format: spec), format: fmt))
        #expect(buf.frameLength == 5)
        let d = try #require(buf.int16ChannelData?[0])
        #expect(d[0] == 0)
        #expect(abs(Int(d[1]) - 16_384) <= 1)
        #expect(abs(Int(d[2]) + 16_384) <= 1)
        #expect(d[3] == Int16.max)
        #expect(d[4] >= -Int16.max)
    }

    @Test func emptyChunkYieldsNil() throws {
        let fmt = try #require(AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: false))
        #expect(PCMPacker.buffer(from: AudioChunk(samples: [], format: spec), format: fmt) == nil)
    }
}
