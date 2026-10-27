import Foundation
import LegatoCore
import LegatoFluidAudio
import LegatoMeetings
import Synchronization
import Testing
@testable import LegatoAppServices

/// Records the order things happen in, across the fakes.
private final class Log: Sendable {
    private let items = Mutex<[String]>([])
    var all: [String] { items.withLock { $0 } }
    func reset() { items.withLock { $0 = [] } }
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
    /// Length of the mix recording; 0 is a meeting from before the mix existed (the post-pass runs per stream).
    let mixDuration: TimeInterval
    /// How loud the mic and the system recordings are (0.5 each unless a test says otherwise).
    let micLevel: Float
    let systemLevel: Float
    init(
        log: Log, failFinalizeTimes: Int = 0, unconvertible: [TranscriptEvent.Stream] = [],
        onFinalize: @escaping @Sendable () async -> Void = {}, mixDuration: TimeInterval = 0,
        micLevel: Float = 0.5, systemLevel: Float = 0.5
    ) {
        self.log = log
        failFinalize = Mutex(failFinalizeTimes)
        self.unconvertible = unconvertible
        self.onFinalize = onFinalize
        self.mixDuration = mixDuration
        self.micLevel = micLevel
        self.systemLevel = systemLevel
    }

    func duration(of stream: TranscriptEvent.Stream) async throws -> TimeInterval { stream == .mixed ? mixDuration : 20 }
    func samples(of stream: TranscriptEvent.Stream, in range: Range<TimeInterval>) async throws -> [Float] {
        let level = stream == .system ? systemLevel : stream == .mic ? micLevel : 0.5
        return [Float](repeating: level, count: Int((range.upperBound - range.lowerBound) * 16_000))
    }
    func finalizeAudio() async throws -> [TranscriptEvent.Stream] {
        let fail = failFinalize.withLock { n -> Bool in if n > 0 { n -= 1; return true }; return false }
        if fail { throw CancellationError() }
        await onFinalize()
        log.add("m4a")
        return unconvertible
    }
    func discardLosslessAudio() async { log.add("caf-deleted") }
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

private struct FailingTranscriber: BatchTranscriber {
    let id = "failing-batch"
    func transcribe(samples: [Float], stream: TranscriptEvent.Stream) async throws -> [TranscriptEvent] {
        throw LLMError.failed("boom")
    }
}

private final class FakeDiarizer: BatchDiarizer {
    let result: [SpeakerTurn]
    let log: Log
    let sampleCounts = Mutex<[Int]>([])
    init(_ result: [SpeakerTurn], log: Log) { self.result = result; self.log = log }
    func diarize(samples: [Float]) async throws -> [SpeakerTurn] {
        log.add("diarize")
        sampleCounts.withLock { $0.append(samples.count) }
        return result
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

    init(
        failFinalizeTimes: Int = 0, unconvertible: [TranscriptEvent.Stream] = [], onFinalize: @escaping @Sendable () async -> Void = {},
        mixDuration: TimeInterval = 0, micLevel: Float = 0.5, systemLevel: Float = 0.5
    ) {
        llm = FakeLLM(log: log)
        audio = FakeAudio(
            log: log, failFinalizeTimes: failFinalizeTimes, unconvertible: unconvertible, onFinalize: onFinalize,
            mixDuration: mixDuration, micLevel: micLevel, systemLevel: systemLevel)
    }

    func seed(
        state: Meeting.State = .processing, steps: Set<Meeting.Step> = [], templateID: String = SummaryTemplate.summaryID,
        locale: String? = nil, speakers: [PersonID: SpeakerInfo] = [:]
    ) async throws {
        try await store.create(Meeting(
            id: id, title: "Sync", date: Date(), duration: 20, engineID: "live", speakers: speakers, locale: locale,
            templateID: templateID, state: state, completedSteps: steps))
        try await store.appendSegment(MeetingSegment(stream: .mic, text: "live mine", start: 0, end: 4), to: id)
        try await store.appendSegment(MeetingSegment(stream: .system, text: "live theirs", start: 5, end: 9), to: id)
    }

    /// A meeting recorded with one live engine on the mix: `.mixed` segments, a 20 s mix recording.
    func seedMixed(speakers: [PersonID: SpeakerInfo] = [:], liveTurns: [SpeakerTurn] = []) async throws {
        try await store.create(Meeting(
            id: id, title: "Sync", date: Date(), duration: 20, engineID: "live", speakers: speakers, state: .processing))
        try await store.appendSegment(MeetingSegment(stream: .mixed, text: "first part", start: 0, end: 9), to: id)
        try await store.appendSegment(MeetingSegment(stream: .mixed, text: "second part", start: 11, end: 19), to: id)
        if !liveTurns.isEmpty { try await store.saveLiveTurns(liveTurns, for: id) }
    }

    func pipeline(
        transcriber: Bool = true, backend: Bool = true, templates: [SummaryTemplate] = [], diarizer: FakeDiarizer? = nil,
        diarization: Bool = true
    ) -> MeetingPipeline {
        let log = self.log, audio = self.audio, llm = self.llm
        let batch = FakeTranscriber(log: log)
        return MeetingPipeline(
            store: store,
            audio: { _ in audio },
            transcriber: { transcriber ? batch : nil },
            backend: { backend ? llm : nil },
            templates: { templates },
            batchDiarizer: { diarizer },
            diarizationEnabled: { diarization },
            releaseDiarizer: { log.add("release-diarizer") },
            releaseModels: { log.add("release") },
            releasePostPassModels: { log.add("release-post-pass") })
    }

    func meeting() async throws -> Meeting { try #require(try await store.meeting(id: id)) }
}

@Suite struct MeetingPipelineTests {
    @Test func theChainRunsM4aThenPostPassThenSummaryAndFinishes() async throws {
        let rig = Rig()
        try await rig.seed()
        let outcome = try await rig.pipeline().run(meetingID: rig.id)

        let order = rig.log.all.filter { $0 != "release" }
        #expect(order.first == "m4a", "the audio is converted first, so the meeting plays at once")
        #expect(order.last == "summary")
        #expect(order.firstIndex(of: "m4a")! < order.firstIndex(of: "post-pass")!)
        #expect(order.lastIndex(of: "post-pass")! < order.firstIndex(of: "summary")!)

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
        #expect(rig.log.all == ["m4a", "caf-deleted", "summary"])
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

    @Test func theMeetingsCustomTemplateReachesTheBackendAndFilesTheSummaryUnderIt() async throws {
        let rig = Rig()
        try await rig.seed(templateID: "mine")
        let mine = SummaryTemplate(id: "mine", name: "Mine", prompt: "Only list decisions.")
        _ = try await rig.pipeline(templates: [mine]).run(meetingID: rig.id)
        #expect(rig.llm.prompts.withLock { $0.first }?.hasPrefix("Only list decisions.||") == true)
        #expect(try await rig.store.summaries(for: rig.id).map(\.templateID) == ["mine"])
    }

    @Test func aTemplateThatIsGoneFallsBackToSummary() async throws {
        let rig = Rig()
        try await rig.seed(templateID: "deleted")
        _ = try await rig.pipeline().run(meetingID: rig.id)
        #expect(rig.llm.prompts.withLock { $0.first }?.hasPrefix(SummaryTemplate.summary.prompt) == true)
        #expect(try await rig.store.summaries(for: rig.id).map(\.templateID) == ["summary"])
    }

    @Test func theSummaryGetsTheTemplateNotesLanguageAndSpeakerNames() async throws {
        let rig = Rig()
        try await rig.seedMixed(speakers: ["P1": SpeakerInfo(name: "Ann", colorIndex: 0)])
        try await rig.store.update(id: rig.id) { $0.templateID = "action-items"; $0.locale = "de-DE" }
        try await rig.store.saveNotes("Budget is fixed at 5k", for: rig.id)
        try await rig.store.replaceSegments(
            [MeetingSegment(stream: .mixed, text: "we ship friday", start: 0, end: 5, speaker: "P1")], for: rig.id)
        _ = try await rig.pipeline(transcriber: false).run(meetingID: rig.id)

        let sent = try #require(rig.llm.prompts.withLock { $0.first })
        #expect(sent.hasPrefix(SummaryTemplate.actionItems.prompt))
        #expect(sent.contains("Write the summary in German."))
        #expect(sent.contains("Notes from the user (treat as facts):\nBudget is fixed at 5k"))
        #expect(sent.contains("Ann [00:00]: we ship friday"))
        #expect(try await rig.store.summaries(for: rig.id).map(\.templateID) == ["action-items"])
    }

    @Test func anExplicitSummaryAlsoGetsTheNotesAndTheMeetingsLanguage() async throws {
        let rig = Rig()
        try await rig.seed(locale: "fr-FR")
        try await rig.store.saveNotes("Mention the audit", for: rig.id)
        let claude = FakeLLM(id: "claude", log: rig.log)
        _ = try await rig.pipeline().summarize(meetingID: rig.id, using: claude)
        let sent = try #require(claude.prompts.withLock { $0.first })
        #expect(sent.contains("Write the summary in French."))
        #expect(sent.contains("Mention the audit"))
    }

    // MARK: Lossless audio for the heavy steps

    @Test func theLosslessCafsAreDeletedOnlyAfterThePostPassAndTheSpeakerPass() async throws {
        let rig = Rig(mixDuration: 20)
        try await rig.seedMixed()
        let diarizer = FakeDiarizer([SpeakerTurn(speaker: "S1", start: 0, end: 20)], log: rig.log)
        _ = try await rig.pipeline(diarizer: diarizer).run(meetingID: rig.id)

        let order = rig.log.all
        let deleted = try #require(order.firstIndex(of: "caf-deleted"), "the CAFs are deleted at the end")
        #expect(rig.log.count("caf-deleted") == 1)
        #expect(order.firstIndex(of: "m4a")! < order.firstIndex(of: "post-pass")!, "m4a written at stop, CAF still there")
        #expect(order.lastIndex(of: "post-pass")! < deleted)
        #expect(order.lastIndex(of: "diarize")! < deleted)
    }

    @Test func theAudioStepAloneKeepsTheCafs() async throws {
        let rig = Rig()
        try await rig.seed()
        _ = try await rig.pipeline().runAudio(meetingID: rig.id)
        #expect(rig.log.all == ["m4a"])
    }

    @Test func aMeetingInterruptedAfterTheAudioStepStillDeletesItsCafsAfterTheDeferredSteps() async throws {
        let rig = Rig()
        try await rig.seed(state: .interrupted, steps: [.audio])
        _ = try await rig.pipeline().runDeferred(meetingID: rig.id)
        let order = rig.log.all
        #expect(!order.contains("m4a"))
        let deleted = try #require(order.firstIndex(of: "caf-deleted"))
        #expect(order.firstIndex(of: "post-pass")! < deleted)
    }

    @Test func aFailedPostPassKeepsTheCafsForTheNextRun() async throws {
        let rig = Rig()
        try await rig.seed()
        let broken = FailingTranscriber()
        let pipeline = MeetingPipeline(
            store: rig.store, audio: { _ in rig.audio }, transcriber: { broken }, backend: { nil },
            releaseModels: {}, releasePostPassModels: {})
        _ = try await pipeline.run(meetingID: rig.id)
        #expect(rig.log.count("caf-deleted") == 0)
    }

    // MARK: Audio now, the rest later

    @Test func theAudioStepAloneConvertsTheRecordingsAndLeavesTheMeetingProcessing() async throws {
        let rig = Rig()
        try await rig.seed()
        let outcome = try await rig.pipeline().runAudio(meetingID: rig.id)
        #expect(rig.log.all == ["m4a"])
        let meeting = try await rig.meeting()
        #expect(meeting.completedSteps == [.audio])
        #expect(meeting.state == .processing, "the heavy steps are still to come")
        #expect(outcome.notes.isEmpty)
        // Repeating it converts nothing again.
        _ = try await rig.pipeline().runAudio(meetingID: rig.id)
        #expect(rig.log.count("m4a") == 1)
    }

    @Test func theDeferredStepsRunPostPassDiarizeAndSummaryThenFinish() async throws {
        let rig = Rig(mixDuration: 20)
        try await rig.seedMixed()
        let diarizer = FakeDiarizer(
            [SpeakerTurn(speaker: "c0", start: 0, end: 10), SpeakerTurn(speaker: "c1", start: 10, end: 20)],
            log: rig.log)
        let pipeline = rig.pipeline(diarizer: diarizer)
        _ = try await pipeline.runAudio(meetingID: rig.id)
        rig.log.reset()
        _ = try await pipeline.runDeferred(meetingID: rig.id)

        #expect(rig.log.all == ["release", "post-pass", "release-post-pass", "diarize", "release-diarizer", "caf-deleted", "summary"])
        let meeting = try await rig.meeting()
        #expect(meeting.state == .finished)
        #expect(meeting.completedSteps == [.audio, .postPass, .diarize, .summary])
    }

    @Test func theDeferredStepsDoNothingToAMeetingThatIsStillRecording() async throws {
        let rig = Rig()
        try await rig.seed(state: .recording)
        _ = try await rig.pipeline().runDeferred(meetingID: rig.id)
        #expect(rig.log.all.isEmpty)
        #expect(try await rig.meeting().state == .recording)
    }

    // MARK: Speakers after the meeting

    @Test func theOfflinePassGivesEverySegmentItsSpeakerAndSavesTheTurns() async throws {
        let rig = Rig(mixDuration: 20)
        try await rig.seedMixed()
        let turns = [SpeakerTurn(speaker: "c0", start: 0, end: 10), SpeakerTurn(speaker: "c1", start: 10, end: 20)]
        let diarizer = FakeDiarizer(turns, log: rig.log)
        _ = try await rig.pipeline(transcriber: false, diarizer: diarizer).run(meetingID: rig.id)

        #expect(diarizer.sampleCounts.withLock { $0 } == [20 * 16_000], "the whole mix went in")
        let segments = try await rig.store.segments(for: rig.id)
        #expect(segments.map(\.speaker) == ["P1", "P2"])
        let meeting = try await rig.meeting()
        #expect(Set(meeting.speakers.keys) == ["P1", "P2"])
        #expect(meeting.speakers["P1"]?.name == "Speaker 1")
        #expect(try await rig.store.offlineTurns(for: rig.id)?.map(\.speaker) == ["P1", "P2"])
    }

    @Test func theOfflineClustersKeepTheLivePeopleAndTheirNames() async throws {
        let rig = Rig(mixDuration: 20)
        let people = [
            "P1": SpeakerInfo(name: "Ann", colorIndex: 0),
            "P2": SpeakerInfo(name: "Bob", colorIndex: 1),
        ]
        try await rig.seedMixed(
            speakers: people,
            liveTurns: [SpeakerTurn(speaker: "P1", start: 0, end: 10), SpeakerTurn(speaker: "P2", start: 10, end: 19)])
        // The offline model numbers its clusters the other way round and finds a third voice at the end.
        let turns = [
            SpeakerTurn(speaker: "x", start: 10.5, end: 19), SpeakerTurn(speaker: "y", start: 0, end: 9.5),
            SpeakerTurn(speaker: "z", start: 19.2, end: 20),
        ]
        let diarizer = FakeDiarizer(turns, log: rig.log)
        _ = try await rig.pipeline(transcriber: false, diarizer: diarizer).run(meetingID: rig.id)

        let meeting = try await rig.meeting()
        #expect(meeting.speakers["P1"]?.name == "Ann")
        #expect(meeting.speakers["P2"]?.name == "Bob")
        #expect(meeting.speakers["P3"]?.name == "Speaker 3", "an unmatched cluster is a new person")
        #expect(try await rig.store.segments(for: rig.id).map(\.speaker) == ["P1", "P2"])
    }

    @Test func theOfflinePassIsSkippedWhenOffNotInstalledOrThereIsNoMix() async throws {
        let off = Rig(mixDuration: 20)
        try await off.seedMixed()
        let diarizer = FakeDiarizer([SpeakerTurn(speaker: "c0", start: 0, end: 20)], log: off.log)
        _ = try await off.pipeline(transcriber: false, diarizer: diarizer, diarization: false).run(meetingID: off.id)
        #expect(off.log.count("diarize") == 0)
        #expect(!(try await off.meeting().completedSteps.contains(.diarize)))
        #expect(try await off.meeting().state == .finished)

        let missing = Rig(mixDuration: 20)
        try await missing.seedMixed()
        _ = try await missing.pipeline(transcriber: false, diarizer: nil).run(meetingID: missing.id)
        #expect(!(try await missing.meeting().completedSteps.contains(.diarize)))

        let legacy = Rig(mixDuration: 0)  // two per-stream recordings, no mix
        try await legacy.seed()
        let other = FakeDiarizer([], log: legacy.log)
        _ = try await legacy.pipeline(transcriber: false, diarizer: other).run(meetingID: legacy.id)
        #expect(legacy.log.count("diarize") == 0)
        #expect(try await legacy.store.segments(for: legacy.id).allSatisfy { $0.speaker == nil })
    }

    @Test func anInterruptedAudioStepResumesAndTheRestFollows() async throws {
        let rig = Rig(failFinalizeTimes: 1)
        try await rig.seed()
        let pipeline = rig.pipeline()
        await #expect(throws: CancellationError.self) { try await pipeline.run(meetingID: rig.id) }

        var meeting = try await rig.meeting()
        #expect(meeting.state == .processing)
        #expect(meeting.completedSteps.isEmpty, "nothing after the audio ran")
        #expect(rig.log.count("post-pass") == 0)

        _ = try await pipeline.run(meetingID: rig.id)
        meeting = try await rig.meeting()
        #expect(meeting.state == .finished)
        #expect(meeting.completedSteps == [.audio, .postPass, .summary])
        #expect(rig.log.count("m4a") == 1)
        #expect(rig.log.count("summary") == 1)
    }

    @Test func aChainCutShortAfterTheAudioResumesWithoutRepeatingIt() async throws {
        let rig = Rig()
        try await rig.seed()
        let first = rig.pipeline()
        _ = try await first.runAudio(meetingID: rig.id)
        // The app is suspended while the deferred steps run: the post-pass is cancelled.
        let log = rig.log, audio = rig.audio, llm = rig.llm
        struct Cancelled: BatchTranscriber {
            let id = "cancelled"
            func transcribe(samples: [Float], stream: TranscriptEvent.Stream) async throws -> [TranscriptEvent] { throw CancellationError() }
        }
        let cut = MeetingPipeline(
            store: rig.store, audio: { _ in audio }, transcriber: { Cancelled() }, backend: { llm },
            releaseModels: { log.add("release") }, releasePostPassModels: { log.add("release-post-pass") })
        await #expect(throws: CancellationError.self) { try await cut.runDeferred(meetingID: rig.id) }
        #expect(try await rig.meeting().completedSteps == [.audio])
        #expect(try await rig.meeting().state == .processing)

        _ = try await first.run(meetingID: rig.id)
        let meeting = try await rig.meeting()
        #expect(meeting.state == .finished)
        #expect(meeting.completedSteps == [.audio, .postPass, .summary])
        #expect(log.count("m4a") == 1, "the audio was not converted again")
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
            store: rig.store, audio: { _ in audio }, transcriber: { Broken() }, backend: { llm },
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
        #expect(seen.withLock { $0 } == [.audio, .postPass, .summary])
    }

    @Test func anExplicitSummaryWritesItsOwnFileAndLeavesTheState() async throws {
        let rig = Rig()
        try await rig.seed(state: .finished, steps: [.postPass, .audio, .summary])
        let claude = FakeLLM(id: "claude", log: rig.log)
        let url = try await rig.pipeline().summarize(meetingID: rig.id, using: claude)
        #expect(url.path.hasSuffix("/summaries/summary/claude.md"))
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
            store: rig.store, audio: { _ in audio }, transcriber: { Broken() }, backend: { llm },
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
            store: store, audio: { _ in audio }, transcriber: { batch }, backend: { llm },
            releaseModels: {}, releasePostPassModels: {})
        _ = try await pipeline.run(meetingID: id)
        let saved = try #require(try await store.meeting(id: id))
        #expect(saved.title == "Renamed mid-chain")
        #expect(saved.state == .finished)
        #expect(saved.completedSteps == [.audio, .postPass, .summary])
    }
}
