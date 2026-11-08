#if DEBUG || LEGATO_INTERNAL
import Foundation
import Testing
import LegatoSoniox
@testable import LegatoAppServices

@Suite struct DictationReplayTests {
    private static let fixture = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "scripts/device/fixtures/dictation-replay-neutral.json")

    @Test func parsesTheSpikeRecordAndDropsTheStreamsOwnEnd() throws {
        let data = Data(#"{"responses":[{"t":0.5,"tokens":[{"text":"Hi","is_final":false}]},{"t":1.0,"tokens":[{"text":"Hi","is_final":true},{"text":"<fin>","is_final":true}]},{"t":1.2,"tokens":[],"finished":true}]}"#.utf8)
        let timeline = try DictationReplayTimeline.parse(data)
        #expect(timeline.frames.map(\.at) == [0.5, 1.0])
        #expect(timeline.tokenCount == 2 && !timeline.frames[1].json.contains("<fin>"))
    }

    @Test func acceptsBareArraysAndJSONLinesAndRejectsOtherFiles() throws {
        let line = #"{"t":2,"tokens":[{"text":"a","is_final":false}]}"#
        #expect(try DictationReplayTimeline.parse(Data("[\(line)]".utf8)).frames.count == 1)
        #expect(try DictationReplayTimeline.parse(Data("\(line)\n\(line)\n".utf8)).frames.count == 2)
        #expect(throws: DictationReplayTimeline.ReplayError.unreadable) { try DictationReplayTimeline.parse(Data("not json".utf8)) }
        #expect(throws: DictationReplayTimeline.ReplayError.empty) { try DictationReplayTimeline.parse(Data(#"{"responses":[{"t":1,"tokens":[]}]}"#.utf8)) }
    }

    @Test func theNeutralFixtureSegmentsIntoFiveSentencesThroughTheProviderSegmenter() throws {
        struct Frame: Decodable { var tokens: [SonioxToken] }
        let timeline = try DictationReplayTimeline.parse(Data(contentsOf: Self.fixture))
        var segmenter = Segmenter()
        var segments: [SonioxSegment] = []
        for frame in timeline.frames {
            segments += segmenter.ingest(try JSONDecoder().decode(Frame.self, from: Data(frame.json.utf8)).tokens).segments
        }
        segments += segmenter.ingest([], finished: true).segments
        #expect(segments.count == 5 && timeline.duration > 20)
        #expect(segments[2].words.map(\.word.text).contains("there"), "The final form wins over the provisional one")
    }
}
#endif
