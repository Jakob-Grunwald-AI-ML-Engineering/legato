import Foundation
import Testing
import LegatoRoom
@testable import LegatoSoniox

@Suite(.timeLimit(.minutes(1))) struct SonioxDiarizationTests {
    private func message(_ config: SonioxConfig) throws -> String {
        String(decoding: try config.message(), as: UTF8.self)
    }

    @Test func theDictationStartMessageIsUnchanged() throws {
        let config = SonioxConfig(mode: "Dictation", personalPrompt: "p", terms: ["Legato"])
        #expect(try message(config) == #"{"audio_format":"pcm_s16le","context":{"general":[{"key":"composer","value":"Mode: Dictation\np"}],"terms":["Legato"]},"enable_endpoint_detection":true,"enable_language_identification":true,"language_hints":["de","en"],"model":"stt-rt-v6","num_channels":1,"sample_rate":16000}"#)
    }

    @Test func diarizationIsOptInAndTheOnlyDifference() throws {
        let plain = SonioxConfig(mode: "Meeting", terms: ["Legato"])
        let diarized = SonioxConfig(mode: "Meeting", terms: ["Legato"], diarization: true)
        let off = try JSONDecoder().decode(JSONValue.self, from: plain.message())
        var on = try JSONDecoder().decode(JSONValue.self, from: diarized.message())
        #expect(off["enable_speaker_diarization"] == nil)
        #expect(on["enable_speaker_diarization"] == .bool(true))
        guard case .object(var fields) = on else {
            Issue.record("not an object")
            return
        }
        fields["enable_speaker_diarization"] = nil
        on = .object(fields)
        #expect(on == off)
    }

    @Test func tokensDecodeTheirSpeaker() throws {
        let token = try JSONDecoder().decode(SonioxToken.self, from: Data(#"{"text":" Hi","is_final":true,"speaker":"2"}"#.utf8))
        #expect(token.speaker == "2")
        let plain = try JSONDecoder().decode(SonioxToken.self, from: Data(#"{"text":" Hi","is_final":true}"#.utf8))
        #expect(plain.speaker == nil)
    }

    @Test func aSpeakerChangeClosesTheSegmentAndLabelsIt() {
        var segmenter = Segmenter()
        let output = segmenter.ingest([
            .init(text: "Hello", isFinal: true, startMs: 0, endMs: 300, speaker: "1"),
            .init(text: " there", isFinal: true, startMs: 300, endMs: 600, speaker: "1"),
            .init(text: " Hi", isFinal: true, startMs: 700, endMs: 900, speaker: "2"),
            .init(text: " you", isFinal: true, startMs: 900, endMs: 1100, speaker: "2"),
            .init(text: "<end>", isFinal: true),
        ])
        #expect(output.segments.map { $0.words.map(\.word.text) } == [["Hello", "there"], ["Hi", "you"]])
        #expect(output.segments.map(\.speaker) == ["1", "2"])
        #expect(output.segments.map(\.reason) == ["speaker", "endpoint"])
    }

    @Test func wordsWithoutASpeakerNeverSplitASegment() {
        var segmenter = Segmenter()
        let output = segmenter.ingest([
            .init(text: "one", isFinal: true, startMs: 0, endMs: 100),
            .init(text: " two", isFinal: true, startMs: 100, endMs: 200),
            .init(text: "<end>", isFinal: true),
        ])
        #expect(output.segments.count == 1 && output.segments[0].speaker == nil)
    }

    @Test func theSegmentEnvelopeCarriesThePrefixedSpeakerOnlyWhenDiarized() async throws {
        let room = Room(segmentRouting: .intercepted)
        let stream = await room.subscribe(participant: .ui, channels: [.asrSegment], buffering: .unbounded)
        var segments = stream.makeAsyncIterator()
        let client = SonioxClient(room: room, audioOrigin: 0, speakerPrefix: "2.")
        try await client.startDebug()
        try await client.injectDebugFrame(#"{"tokens":[{"text":"Hi there.","is_final":true,"start_ms":0,"end_ms":400,"speaker":"3"}]}"#)
        let diarized = try #require(await segments.next())
        #expect(diarized.payload["metadata"]?["speaker"] == .string("2.3"))
        try await client.injectDebugFrame(#"{"tokens":[{"text":"Plain.","is_final":true,"start_ms":500,"end_ms":900}]}"#)
        let plain = try #require(await segments.next())
        #expect(plain.payload["metadata"]?["speaker"] == nil)
        await client.close()
    }
}
