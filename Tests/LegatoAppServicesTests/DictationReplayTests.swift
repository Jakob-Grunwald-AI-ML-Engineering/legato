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

    @Test func originalPCMRunsBeforeMatchingResponseAndRetainsEndpointDelay() throws {
        let timeline = DictationReplayTimeline(frames: [.init(at: 0.2, json: "endpoint"), .init(at: 0.5, json: "delayed")])
        let pcm = try DictationReplayPCM(Data(count: 6_400)) // Ten original 20 ms quiet frames.
        var cursor = DictationReplayCursor(timeline: timeline, pcm: pcm)
        var activity = DictationActivity()
        var audioFrames = 0
        var responses: [Double] = []
        while let event = cursor.next() {
            switch event {
            case .pcm(_, let data):
                audioFrames += 1
                activity.receive(data)
            case .response(let response):
                #expect(audioFrames == 10)
                let admitted = activity.boundary("endpoint")
                #expect(admitted)
                responses.append(response.at)
            }
        }
        #expect(responses == [0.2, 0.5])
    }

    @Test func PCMValidationRejectsEmptyOddAndOversizedInputsAndRetainsShortFinalFrame() throws {
        for data in [Data(), Data(count: 1), Data(count: DictationReplayPCM.maximumBytes + 2)] {
            #expect(throws: DictationReplayTimeline.ReplayError.invalidPCM) { try DictationReplayPCM(data) }
        }
        var cursor = DictationReplayCursor(timeline: .init(frames: []), pcm: try .init(Data(count: 960)))
        #expect(cursor.next() == .pcm(at: 0.02, Data(count: 640)))
        #expect(cursor.next() == .pcm(at: 0.03, Data(count: 320)))
        #expect(cursor.next() == nil)
    }

    @Test func replayFilesMustBeBoundedRegularBasenames() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data([0, 0]).write(to: root.appendingPathComponent("take.pcm"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link.pcm"), withDestinationURL: root.appendingPathComponent("take.pcm"))
        #expect(try DictationReplayTimeline.readFile("take.pcm", in: root, maximumBytes: 2) == Data([0, 0]))
        for name in ["../take.pcm", "/take.pcm", ".take.pcm", "a\\take.pcm", "link.pcm"] {
            #expect(throws: DictationReplayTimeline.ReplayError.invalidFile) { try DictationReplayTimeline.readFile(name, in: root, maximumBytes: 2) }
        }
        #expect(throws: DictationReplayTimeline.ReplayError.invalidFile) { try DictationReplayTimeline.readFile("take.pcm", in: root, maximumBytes: 1) }
    }

    @MainActor @Test(arguments: [false, true]) func stoppingReplayJoinsItsAudioAndTokenClock(cancelCaller: Bool) async throws {
        let sink = ReplayActivitySink()
        let engine = DictationEngine(sink: sink, sonioxKey: { "test" }, makeSocket: { TestSocket() },
                                     vocabularyURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        engine.open()
        let timeline = DictationReplayTimeline(frames: [.init(at: 10, json: #"{"tokens":[{"text":"later","is_final":true}]}"#)])
        let pcm = try DictationReplayPCM(Data(repeating: 32, count: 32_000))
        let replay = Task { try await engine.debugReplay(timeline, pcm: pcm) }
        // Let original PCM enter the real activity classifier, then close while token pacing is suspended.
        let deadline = ContinuousClock.now + .seconds(2)
        while sink.activityCount == 0, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        #expect(sink.activityCount > 0)
        if cancelCaller { replay.cancel() } else { await engine.close() }
        if case .success = await replay.result { Issue.record("Stopping the route must cancel its replay") }
        let count = sink.activityCount
        #expect(!engine.isReplaying)
        try await Task.sleep(for: .milliseconds(60))
        #expect(sink.activityCount == count && sink.lines.isEmpty)
        await engine.close()
    }

    /// With original PCM only quiet audio admits the recorded endpoint as a pause. A token-only replay has no audio:
    /// its endpoints are the pauses (#299: otherwise no gap ever opens and per-sentence cleanup waits for the stop).
    enum ReplayAudio: CaseIterable { case none, quiet, loud }
    @MainActor @Test(arguments: ReplayAudio.allCases) func theRecordedEndpointIsAPauseUnlessOriginalAudioIsLoud(audio: ReplayAudio) async throws {
        let sink = ReplayActivitySink()
        let engine = DictationEngine(sink: sink, sonioxKey: { "test" }, makeSocket: { TestSocket() },
                                     vocabularyURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        engine.open()
        let timeline = DictationReplayTimeline(frames: [.init(at: 0.2, json: #"{"tokens":[{"text":"<end>","is_final":true}]}"#)])
        let loud = Data((0..<3_200).flatMap { _ in [UInt8(0), UInt8(64)] })
        let pcm: DictationReplayPCM? = switch audio {
        case .none: nil
        case .quiet: try DictationReplayPCM(Data(count: 6_400))
        case .loud: try DictationReplayPCM(loud)
        }
        try await engine.debugReplay(timeline, pcm: pcm)
        let deadline = ContinuousClock.now + .seconds(2)
        while !sink.boundaries.contains("finished"), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        #expect(sink.boundaries.contains("finished"))
        #expect(sink.boundaries.contains("endpoint") == (audio != .loud))
        await engine.close()
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

@MainActor private final class ReplayActivitySink: DictationRouteSink {
    var activityCount = 0
    var lines: [DictationRouteLine] = []
    var boundaries: [String] = []
    func receive(_ line: DictationRouteLine) async { lines.append(line) }
    func speechActivity() { activityCount += 1 }
    func boundary(_ reason: String) { boundaries.append(reason) }
    func reset() async {}
}
#endif
