import Foundation
import LegatoCore
import LegatoMeetings
import Synchronization
import Testing
@testable import LegatoAppServices

/// Records the order things happen in, across the fakes.
private final class Log: Sendable {
    private let items = Mutex<[String]>([])
    var all: [String] { items.withLock { $0 } }
    func add(_ s: String) { items.withLock { $0.append(s) } }
    func count(_ s: String) -> Int { all.filter { $0 == s }.count }
}

private final class FakeAudio: MeetingAudioFinalizing {
    let log: Log
    let failFinalize: Mutex<Int>
    /// Streams `finalizeAudio` reports as not converted.
    let unconvertible: [TranscriptEvent.Stream]
    /// Runs inside `finalizeAudio`, e.g. to edit the meeting while the chain is working.
    let onFinalize: @Sendable () async -> Void
    init(
        log: Log, failFinalizeTimes: Int = 0, unconvertible: [TranscriptEvent.Stream] = [],
        onFinalize: @escaping @Sendable () async -> Void = {}
    ) {
        self.log = log
        failFinalize = Mutex(failFinalizeTimes)
        self.unconvertible = unconvertible
        self.onFinalize = onFinalize
    }

    func duration(of stream: TranscriptEvent.Stream) async throws -> TimeInterval { 20 }
    func samples(of stream: TranscriptEvent.Stream, in range: Range<TimeInterval>) async throws -> [Float] {
        [Float](repeating: 0.5, count: Int((range.upperBound - range.lowerBound) * 16_000))
    }
    func finalizeAudio() async throws -> [TranscriptEvent.Stream] {
        let fail = failFinalize.withLock { n -> Bool in if n > 0 { n -= 1; return true }; return false }
        if fail { throw CancellationError() }
        await onFinalize()
        log.add("m4a")
        return unconvertible
    }
}

private final class FakeTranscriber: BatchTranscriber {
    let id = "fake-batch"
    let log: Log
    init(log: Log) { self.log = log }
    func transcribe(samples: [Float], stream: TranscriptEvent.Stream) async throws -> [TranscriptEvent] {
        log.add("post-pass")
        return [TranscriptEvent(stream: stream, text: stream == .mic ? "accurate mine" : "accurate theirs", isFinal: true, range: 0..<5)]
    }
}

private final class FakeLLM: LLMBackend {
    let id: String
    let log: Log
    let prompts = Mutex<[String]>([])
    init(id: String = "fake-llm", log: Log) { self.id = id; self.log = log }
    var maxPromptCharacters: Int? { nil }
    var availability: LLMAvailability { get async { .available } }
    func respond(instructions: String, prompt: String) async throws -> String {
        log.add("summary")
        prompts.withLock { $0.append(instructions + "||" + prompt) }
        return "## Summary\nDone."
    }
}

private struct Rig {
    let store = MeetingStore(root: FileManager.default.temporaryDirectory.appending(path: "legato-pipeline-\(UUID().uuidString)"))
    let log = Log()
    let llm: FakeLLM
    let audio: FakeAudio
    let id = UUID()

    init(failFinalizeTimes: Int = 0, unconvertible: [TranscriptEvent.Stream] = [], onFinalize: @escaping @Sendable () async -> Void = {}) {
        llm = FakeLLM(log: log)
        audio = FakeAudio(log: log, failFinalizeTimes: failFinalizeTimes, unconvertible: unconvertible, onFinalize: onFinalize)
    }

    func seed(state: Meeting.State = .processing, steps: Set<Meeting.Step> = []) async throws {
        try await store.create(Meeting(id: id, title: "Sync", date: Date(), duration: 20, engineID: "live", state: state, completedSteps: steps))
        try await store.appendSegment(MeetingSegment(stream: .mic, text: "live mine", start: 0, end: 4), to: id)
        try await store.appendSegment(MeetingSegment(stream: .system, text: "live theirs", start: 5, end: 9), to: id)
    }

    func pipeline(transcriber: Bool = true, backend: Bool = true, prompt: String = "") -> MeetingPipeline {
        let log = self.log, audio = self.audio, llm = self.llm
        let batch = FakeTranscriber(log: log)
        return MeetingPipeline(
            store: store,
            audio: { _ in audio },
            transcriber: { transcriber ? batch : nil },
            backend: { backend ? llm : nil },
            prompt: { prompt },
            releaseModels: { log.add("release") },
            releasePostPassModels: { log.add("release-post-pass") })
    }

    func meeting() async throws -> Meeting { try #require(try await store.meeting(id: id)) }
}

@Suite struct MeetingPipelineTests {
    @Test func theChainRunsPostPassThenM4aThenSummaryAndFinishes() async throws {
        let rig = Rig()
        try await rig.seed()
        let outcome = try await rig.pipeline().run(meetingID: rig.id)

        let order = rig.log.all.filter { $0 != "release" }
        #expect(order.first == "post-pass")
        #expect(order.last == "summary")
        #expect(order.firstIndex(of: "m4a")! > order.lastIndex(of: "post-pass")!)
        #expect(order.firstIndex(of: "m4a")! < order.firstIndex(of: "summary")!)

        let meeting = try await rig.meeting()
        #expect(meeting.state == .finished)
        #expect(meeting.postPassID == "fake-batch")
        #expect(meeting.completedSteps == [.postPass, .audio, .summary])
        #expect(outcome.summaryBackendID == "fake-llm")

        let summaries = try await rig.store.summaries(for: rig.id)
        #expect(summaries.map(\.backendID) == ["fake-llm"])
        #expect(summaries.first?.text == "## Summary\nDone.")
        // The summary reads the post-pass text.
        let sent = try #require(rig.llm.prompts.withLock { $0.first })
        #expect(sent.contains("accurate mine") && !sent.contains("live mine"))
    }

    @Test func nemotronIsReleasedBeforeThePostPass() async throws {
        let rig = Rig()
        try await rig.seed()
        _ = try await rig.pipeline().run(meetingID: rig.id)
        let log = rig.log.all
        #expect(log.firstIndex(of: "release")! < log.firstIndex(of: "post-pass")!)
        #expect(rig.log.count("release") == 1)
    }

    @Test func withoutAPostPassModelTheLiveTextIsSummarised() async throws {
        let rig = Rig()
        try await rig.seed()
        _ = try await rig.pipeline(transcriber: false).run(meetingID: rig.id)
        #expect(rig.log.count("post-pass") == 0)
        #expect(rig.log.count("release") == 0)
        #expect(rig.log.all == ["m4a", "summary"])
        let meeting = try await rig.meeting()
        #expect(meeting.state == .finished)
        #expect(meeting.postPassID == nil)
        let sent = try #require(rig.llm.prompts.withLock { $0.first })
        #expect(sent.contains("live mine"))
    }

    @Test func noSummaryBackendStillFinishesTheMeeting() async throws {
        let rig = Rig()
        try await rig.seed()
        let outcome = try await rig.pipeline(backend: false).run(meetingID: rig.id)
        let meeting = try await rig.meeting()
        #expect(meeting.state == .finished)
        #expect(!meeting.completedSteps.contains(.summary))
        #expect(outcome.summaryBackendID == nil)
        #expect(outcome.notes.contains { $0.localizedCaseInsensitiveContains("summary") })
        #expect(try await rig.store.summaries(for: rig.id).isEmpty)
    }

    @Test func theCustomPromptReachesTheBackend() async throws {
        let rig = Rig()
        try await rig.seed()
        _ = try await rig.pipeline(prompt: "Only list decisions.").run(meetingID: rig.id)
        #expect(rig.llm.prompts.withLock { $0.first }?.hasPrefix("Only list decisions.||") == true)
    }

    @Test func anInterruptedChainResumesWithoutRepeatingDoneSteps() async throws {
        let rig = Rig(failFinalizeTimes: 1)
        try await rig.seed()
        let pipeline = rig.pipeline()
        await #expect(throws: CancellationError.self) { try await pipeline.run(meetingID: rig.id) }

        var meeting = try await rig.meeting()
        #expect(meeting.state == .processing)
        #expect(meeting.completedSteps == [.postPass])
        let postPasses = rig.log.count("post-pass")
        #expect(postPasses == 2, "one per stream")

        _ = try await pipeline.run(meetingID: rig.id)
        meeting = try await rig.meeting()
        #expect(meeting.state == .finished)
        #expect(meeting.completedSteps == [.postPass, .audio, .summary])
        #expect(rig.log.count("post-pass") == postPasses, "the post-pass was not repeated")
        #expect(rig.log.count("summary") == 1)
        #expect(rig.log.count("m4a") == 1)
    }

    @Test func aMeetingRecoveredAsInterruptedIsProcessedToo() async throws {
        let rig = Rig()
        try await rig.seed(state: .interrupted)
        _ = try await rig.pipeline().run(meetingID: rig.id)
        #expect(try await rig.meeting().state == .finished)
    }

    @Test func aRunningOrFinishedMeetingIsLeftAlone() async throws {
        for state in [Meeting.State.recording, .finished] {
            let rig = Rig()
            try await rig.seed(state: state)
            _ = try await rig.pipeline().run(meetingID: rig.id)
            #expect(rig.log.all.isEmpty, "\(state)")
            #expect(try await rig.meeting().state == state)
        }
    }

    @Test func aFailingPostPassKeepsTheLiveTextAndTheChainGoesOn() async throws {
        let rig = Rig()
        try await rig.seed()
        let log = rig.log, audio = rig.audio, llm = rig.llm
        struct Broken: BatchTranscriber {
            let id = "broken"
            func transcribe(samples: [Float], stream: TranscriptEvent.Stream) async throws -> [TranscriptEvent] {
                throw DictationError.assetsNotInstalled
            }
        }
        let pipeline = MeetingPipeline(
            store: rig.store, audio: { _ in audio }, transcriber: { Broken() }, backend: { llm }, prompt: { "" },
            releaseModels: { log.add("release") }, releasePostPassModels: { log.add("release-post-pass") })
        let outcome = try await pipeline.run(meetingID: rig.id)
        let meeting = try await rig.meeting()
        #expect(meeting.state == .finished)
        #expect(!meeting.completedSteps.contains(.postPass))
        #expect(outcome.notes.contains { $0.localizedCaseInsensitiveContains("post-pass") })
        #expect(try await rig.store.segments(for: rig.id).map(\.text).contains("live mine"))
    }

    @Test func improveTranscriptRerunsThePostPassThenTheSummary() async throws {
        let rig = Rig()
        try await rig.seed()
        let pipeline = rig.pipeline()
        _ = try await pipeline.run(meetingID: rig.id)
        #expect(rig.log.count("summary") == 1)

        _ = try await pipeline.improveTranscript(meetingID: rig.id)
        #expect(rig.log.count("post-pass") == 4, "both streams, twice")
        #expect(rig.log.count("summary") == 2)
        #expect(rig.log.count("m4a") == 1, "the audio was already converted")
        #expect(try await rig.meeting().state == .finished)
        let order = rig.log.all
        #expect(order.lastIndex(of: "post-pass")! < order.lastIndex(of: "summary")!)
    }

    @Test func stepsAreReportedAsTheyFinish() async throws {
        let rig = Rig()
        try await rig.seed()
        let seen = Mutex<[Meeting.Step]>([])
        let base = rig.pipeline()
        let pipeline = base.reporting { step in seen.withLock { $0.append(step) } }
        _ = try await pipeline.run(meetingID: rig.id)
        #expect(seen.withLock { $0 } == [.postPass, .audio, .summary])
    }

    @Test func anExplicitSummaryWritesItsOwnFileAndLeavesTheState() async throws {
        let rig = Rig()
        try await rig.seed(state: .finished, steps: [.postPass, .audio, .summary])
        let claude = FakeLLM(id: "claude", log: rig.log)
        let url = try await rig.pipeline().summarize(meetingID: rig.id, using: claude)
        #expect(url.lastPathComponent == "summary-claude.md")
        #expect(try await rig.store.summaries(for: rig.id).map(\.backendID) == ["claude"])
        #expect(try await rig.meeting().state == .finished)
    }

    @Test func theLiveEngineIsReleasedBeforeThePostPassAndTheBatchModelBeforeTheSummary() async throws {
        let rig = Rig()
        try await rig.seed()
        _ = try await rig.pipeline().run(meetingID: rig.id)
        let order = rig.log.all
        #expect(order.firstIndex(of: "release")! < order.firstIndex(of: "post-pass")!)
        #expect(order.lastIndex(of: "post-pass")! < order.firstIndex(of: "release-post-pass")!)
        #expect(order.firstIndex(of: "release-post-pass")! < order.firstIndex(of: "summary")!)
        #expect(rig.log.count("release-post-pass") == 1)
    }

    @Test func theBatchModelIsReleasedEvenWhenThePostPassFails() async throws {
        let rig = Rig()
        try await rig.seed()
        let log = rig.log, audio = rig.audio, llm = rig.llm
        struct Broken: BatchTranscriber {
            let id = "broken"
            func transcribe(samples: [Float], stream: TranscriptEvent.Stream) async throws -> [TranscriptEvent] {
                throw DictationError.assetsNotInstalled
            }
        }
        let pipeline = MeetingPipeline(
            store: rig.store, audio: { _ in audio }, transcriber: { Broken() }, backend: { llm }, prompt: { "" },
            releaseModels: { log.add("release") }, releasePostPassModels: { log.add("release-post-pass") })
        _ = try await pipeline.run(meetingID: rig.id)
        #expect(log.all.firstIndex(of: "release-post-pass")! < log.all.firstIndex(of: "summary")!)
    }

    @Test func noPostPassMeansNothingToRelease() async throws {
        let rig = Rig()
        try await rig.seed(steps: [.postPass])
        _ = try await rig.pipeline().run(meetingID: rig.id)
        #expect(rig.log.count("release-post-pass") == 0)
    }

    @Test func aStreamThatCouldNotBeConvertedLeavesAudioUnfinishedWithANote() async throws {
        let rig = Rig(unconvertible: [.system])
        try await rig.seed()
        let outcome = try await rig.pipeline().run(meetingID: rig.id)
        let meeting = try await rig.meeting()
        #expect(!meeting.completedSteps.contains(.audio))
        #expect(meeting.completedSteps.contains(.summary))
        #expect(outcome.notes.contains { $0.contains("system") && $0.localizedCaseInsensitiveContains("audio") })
    }

    @Test func aRenameWhileTheChainRunsSurvivesEveryStep() async throws {
        let store = MeetingStore(root: FileManager.default.temporaryDirectory.appending(path: "legato-pipeline-\(UUID().uuidString)"))
        let id = UUID()
        let rig = Rig(onFinalize: {
            _ = try? await store.update(id: id) { $0.title = "Renamed mid-chain" }
        })
        // Rig's own store is a fresh one; build the pipeline over the shared store instead.
        try await store.create(Meeting(id: id, title: "Sync", date: Date(), duration: 20, engineID: "live", state: .processing))
        try await store.appendSegment(MeetingSegment(stream: .mic, text: "live mine", start: 0, end: 4), to: id)
        let log = rig.log, audio = rig.audio, llm = rig.llm
        let batch = FakeTranscriber(log: log)
        let pipeline = MeetingPipeline(
            store: store, audio: { _ in audio }, transcriber: { batch }, backend: { llm }, prompt: { "" },
            releaseModels: {}, releasePostPassModels: {})
        _ = try await pipeline.run(meetingID: id)
        let saved = try #require(try await store.meeting(id: id))
        #expect(saved.title == "Renamed mid-chain")
        #expect(saved.state == .finished)
        #expect(saved.completedSteps == [.postPass, .audio, .summary])
    }
}
