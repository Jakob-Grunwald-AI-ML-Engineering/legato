import Foundation
import Synchronization
import Testing
import LegatoAudio
import LegatoClaude
import LegatoCore
import LegatoMeetings
import LegatoSoniox
@testable import LegatoAppServices

/// Claude, scripted: no key until `provideKey()`, then a summary that names Speaker 1.
final class ScriptedClaude: LLMBackend {
    let id = "claude"
    private let keyed: Mutex<Bool>
    private let prompts = Mutex<[String]>([])
    let maxPromptCharacters: Int? = 600_000
    init(keyed: Bool = true) { self.keyed = Mutex(keyed) }
    func provideKey() { keyed.withLock { $0 = true } }
    var requests: [String] { prompts.withLock { $0 } }
    var availability: LLMAvailability {
        get async { keyed.withLock { $0 } ? .available : .unavailable(reason: "No Claude API key") }
    }
    func respond(instructions: String, prompt: String) async throws -> String {
        prompts.withLock { $0.append(prompt) }
        return "## Summary\n\nSpeaker 1 opened and Speaker 2 answered."
    }
}

/// Claude that writes the summary and answers the title request (`title` nil: the request fails); `onTitle` runs
/// before it answers.
final class TitlingClaude: LLMBackend {
    let id = "claude"
    let maxPromptCharacters: Int? = 600_000
    private let title: String?
    private let onTitle: @Sendable () async -> Void
    init(title: String?, onTitle: @escaping @Sendable () async -> Void = {}) { (self.title, self.onTitle) = (title, onTitle) }
    var availability: LLMAvailability { get async { .available } }
    func respond(instructions: String, prompt: String) async throws -> String {
        guard instructions == MeetingTitle.instructions else { return "## Summary\n\nThey met." }
        await onTitle()
        guard let title else { throw LLMError.failed("offline") }
        return title
    }
}

/// `eventually` for conditions that read main-actor state.
@MainActor private func settle(
    _ what: String, sourceLocation: SourceLocation = #_sourceLocation, _ condition: @MainActor () async -> Bool
) async {
    let deadline = ContinuousClock.now + .seconds(30)
    while ContinuousClock.now < deadline {
        if await condition() { return }
        try? await Task.sleep(for: .milliseconds(2))
    }
    Issue.record("Timed out waiting for \(what)", sourceLocation: sourceLocation)
}

@MainActor private struct ServicesRig {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("legato-meetings-\(UUID().uuidString)")
    let store: MeetingStore
    let sockets: MeetingSockets
    let claude: any LLMBackend
    let services: MeetingServices

    init(sonioxKey: String = "sk-soniox", claude: any LLMBackend = ScriptedClaude(), autoSummary: Bool = true) {
        store = MeetingStore(root: root)
        let sockets = MeetingSockets()
        self.sockets = sockets
        self.claude = claude
        let defaults = UserDefaults(suiteName: "legato.meeting-services.\(UUID().uuidString)")!
        let settings = MeetingSettings(defaults: defaults)
        settings.summarizeAutomatically = autoSummary
        services = MeetingServices(
            store: store, settings: settings, sonioxKey: { sonioxKey }, claudeKeys: InMemoryAPIKeyStore(apiKey: "sk-ant"),
            claudeBackend: claude, personalPrompt: { "" }, makeSocket: { sockets.make() }, timing: .tests)
    }

    var scripted: ScriptedClaude { claude as! ScriptedClaude }

    func cleanup() { try? FileManager.default.removeItem(at: root) }

    /// A meeting on disk with a short transcript of two voices.
    func saved(state: Meeting.State, speakers: Bool = true, automaticTitle: Bool = false) async throws -> Meeting {
        var meeting = Meeting(
            title: "Weekly", date: Date(timeIntervalSince1970: 1_793_025_000), duration: 12, state: state, titleIsAutomatic: automaticTitle)
        if speakers {
            meeting.speakers = ["P1": SpeakerInfo(name: "Speaker 1", colorIndex: 0), "P2": SpeakerInfo(name: "Speaker 2", colorIndex: 1)]
        }
        try await store.create(meeting)
        try await store.appendSegment(MeetingSegment(text: "Shall we start?", start: 1, end: 3, speaker: speakers ? "P1" : nil), to: meeting.id)
        try await store.appendSegment(MeetingSegment(text: "Yes, go ahead.", start: 4, end: 6, speaker: speakers ? "P2" : nil), to: meeting.id)
        return meeting
    }
}

@Suite(.serialized, .timeLimit(.minutes(1))) @MainActor struct MeetingServicesTests {
    @Test func failedAudioProcessingStaysRecoverable() async throws {
        let rig = ServicesRig(autoSummary: false)
        defer { rig.cleanup() }
        let meeting = try await rig.saved(state: .processing)
        let folder = await rig.store.folder(for: meeting.id)
        try Data("not an audio file".utf8).write(to: folder.appendingPathComponent("mic.caf"))
        await rig.services.process(meeting.id)
        let saved = try #require(try await rig.store.meeting(id: meeting.id))
        #expect(saved.state == .processing, "A failed audio step must be retried at launch, never reported finished")
        #expect(!saved.completedSteps.contains(.audio))
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("mic.caf").path))
    }

    @Test func aMeetingRecordsWithSpeakersStopsAndIsSummarized() async throws {
        let rig = ServicesRig()
        defer { rig.cleanup() }
        let mic = MacMic(), system = MacMic()
        let session = try await rig.services.startMeeting(title: "Weekly", mic: mic, system: system)
        let id = session.meetingID
        #expect(rig.services.isRecording && rig.services.activeMeetingID == id)

        for _ in 0..<20 { await mic.emit(); await system.emit(); try await Task.sleep(for: .milliseconds(10)) }
        await settle("the stream starts") { await rig.sockets.at(0)?.configuration != nil }
        let socket = try #require(rig.sockets.at(0))
        let configuration = try #require(await socket.configuration)
        #expect(configuration.contains(#""enable_speaker_diarization":true"#) && configuration.contains("Mode: Meeting"))
        await socket.feed(#"{"tokens":[{"text":"Shall we start?","is_final":true,"start_ms":100,"end_ms":900,"speaker":"1"}]}"#)
        await socket.feed(#"{"tokens":[{"text":"Yes, go ahead.","is_final":true,"start_ms":1000,"end_ms":1800,"speaker":"2"}]}"#)
        await settle("both segments are saved") { ((try? await rig.store.segments(for: id)) ?? []).count == 2 }

        let stopped = try #require(await rig.services.stopMeeting())
        #expect(stopped.state == .processing && !rig.services.isRecording)
        await rig.services.waitForProcessing(id)

        let meeting = try #require(try await rig.store.meeting(id: id))
        #expect(meeting.state == .finished && meeting.completedSteps == [.audio, .summary] && meeting.summaryFailure == nil)
        #expect(meeting.speakers.mapValues(\.name) == ["P1": "Speaker 1", "P2": "Speaker 2"])
        let segments = try await rig.store.segments(for: id)
        #expect(segments.map(\.speaker) == ["P1", "P2"] && segments.map(\.text) == ["Shall we start?", "Yes, go ahead."])
        let folder = await rig.store.folder(for: id)
        for track in ["mic", "system", "mix"] {
            #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("\(track).m4a").path), "\(track).m4a")
            #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("\(track).caf").path), "\(track).caf is gone")
        }
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("log/room.jsonl").path))
        let request = try #require(rig.scripted.requests.first)
        #expect(request.contains("Speaker 1 [00:00]: Shall we start?") || request.contains("Speaker 1 [00:01]: Shall we start?"))
        #expect(try await rig.services.summaryText(meetingID: id)?.contains("Speaker 1 opened") == true)
        #expect(rig.services.dictationRefusal == nil)
    }

    @Test func renamingASpeakerChangesTheTranscriptAndTheSummary() async throws {
        let rig = ServicesRig()
        defer { rig.cleanup() }
        let meeting = try await rig.saved(state: .processing)
        await rig.services.process(meeting.id)
        #expect(try await rig.services.summaryText(meetingID: meeting.id)?.contains("Speaker 1 opened") == true)

        try await rig.services.renameSpeaker(meetingID: meeting.id, person: "P1", to: "Anna")
        let summary = try #require(try await rig.services.summaryText(meetingID: meeting.id))
        #expect(summary.contains("Anna opened and Speaker 2 answered") && !summary.contains("Speaker 1"))
        let transcript = try await rig.services.transcriptMarkdown(meetingID: meeting.id)
        #expect(transcript.contains("**Anna** [00:01] Shall we start?") && transcript.contains("**Speaker 2** [00:04] Yes, go ahead."))
        #expect(try await rig.services.markdown(meetingID: meeting.id).contains("Anna opened"))

        // A name someone has merges the two people, segments and summary too.
        try await rig.services.renameSpeaker(meetingID: meeting.id, person: "P2", to: "anna")
        let merged = try await rig.store.segments(for: meeting.id)
        #expect(merged.map(\.speaker) == ["P1", "P1"])
        #expect(try await rig.services.summaryText(meetingID: meeting.id)?.contains("Anna opened and Anna answered") == true)
        #expect(try await rig.store.meeting(id: meeting.id)?.speakers.keys.sorted() == ["P1"])
    }

    @Test func aMeetingWithoutASonioxKeyFailsBeforeAnythingIsRecorded() async throws {
        let rig = ServicesRig(sonioxKey: "")
        defer { rig.cleanup() }
        let mic = MacMic()
        await #expect(throws: SonioxError.missingKey) { try await rig.services.startMeeting(mic: mic) }
        #expect(!rig.services.isRecording && rig.services.session == nil)
        #expect(try await rig.store.meetings().isEmpty)
        #expect(rig.sockets.count == 0)
        #expect(await mic.starts == 0, "no source was started")
        let folders = (try? FileManager.default.contentsOfDirectory(atPath: rig.root.path)) ?? []
        #expect(folders.isEmpty, "no folder was left behind")
    }

    @Test func aMeetingAndADictationNeverRunTogether() async throws {
        let rig = ServicesRig()
        defer { rig.cleanup() }
        let mic = MacMic()
        await #expect(throws: MeetingServicesError.refused(.dictationRunning)) {
            try await rig.services.startMeeting(mic: mic, dictationActive: true)
        }
        #expect(!rig.services.isRecording)
        try await rig.services.startMeeting(mic: mic)
        #expect(rig.services.dictationRefusal == "Meeting recording")
        await #expect(throws: MeetingServicesError.refused(.alreadyRecording)) {
            try await rig.services.startMeeting(mic: MacMic())
        }
        #expect(rig.services.activeMeetingID != nil, "the refusal leaves the recording alone")
        await rig.services.stopMeeting()
        #expect(rig.services.dictationRefusal == nil)
        await rig.services.waitForProcessing(try #require(try await rig.store.meetings().first?.id))
    }

    @Test func withoutAClaudeKeyTheMeetingIsKeptAndTheSummaryCanBeRetried() async throws {
        let claude = ScriptedClaude(keyed: false)
        let rig = ServicesRig(claude: claude)
        defer { rig.cleanup() }
        let meeting = try await rig.saved(state: .processing)
        await rig.services.process(meeting.id)

        let kept = try #require(try await rig.store.meeting(id: meeting.id))
        #expect(kept.state == .finished, "the meeting is kept")
        #expect(kept.summaryFailure == "Add your Claude API key in Settings, then try the summary again.")
        #expect(!kept.completedSteps.contains(.summary))
        #expect(try await rig.store.segments(for: meeting.id).count == 2)
        #expect(try await rig.services.summaryText(meetingID: meeting.id) == nil)

        await #expect(throws: LLMError.unavailable(reason: "No Claude API key")) { try await rig.services.summarize(meetingID: meeting.id) }
        claude.provideKey()
        let text = try await rig.services.summarize(meetingID: meeting.id)
        #expect(text.contains("Speaker 1 opened"))
        let retried = try #require(try await rig.store.meeting(id: meeting.id))
        #expect(retried.summaryFailure == nil && retried.completedSteps.contains(.summary))
    }

    @Test func aMeetingIsRetitledAndFiledAndComesBackAfterARelaunch() async throws {
        let rig = ServicesRig()
        defer { rig.cleanup() }
        let meeting = try await rig.saved(state: .finished)
        let saved = try await rig.services.updateMetadata(
            meetingID: meeting.id, MeetingMetadata(title: "Kickoff", client: "Acme", project: "Website", tags: ["design"]))
        #expect(saved.title == "Kickoff")
        let relaunched = MeetingStore(root: rig.root)
        let found = try await relaunched.meetings(matching: .init(client: "acme", project: "website", tags: ["Design"], query: "kickoff"))
        #expect(found.map(\.id) == [meeting.id])
        await #expect(throws: MeetingServicesError.unknownMeeting) {
            try await rig.services.updateMetadata(meetingID: UUID(), MeetingMetadata(title: "x"))
        }
    }

    @Test func aSummaryOffLeavesItToTheUser() async throws {
        let rig = ServicesRig(autoSummary: false)
        defer { rig.cleanup() }
        let meeting = try await rig.saved(state: .processing)
        await rig.services.process(meeting.id)
        #expect(rig.scripted.requests.isEmpty)
        #expect(try await rig.store.meeting(id: meeting.id)?.state == .finished)
        try await rig.services.summarize(meetingID: meeting.id)
        #expect(rig.scripted.requests.count == 1)
    }

    @Test func aMeetingCutOffWhileRecordingComesBackInterruptedWithItsAudio() async throws {
        let rig = ServicesRig()
        defer { rig.cleanup() }
        let meeting = try await rig.saved(state: .recording)
        let writer = MeetingAudioWriter(folder: await rig.store.folder(for: meeting.id))
        try await writer.write(AudioChunk(samples: Array(repeating: 0.3, count: 32_000), format: MeetingEngineRig.format), stream: .mic)
        // The app died: the writer never finished and the meeting still says recording.

        await rig.services.recover()
        await rig.services.waitForProcessing(meeting.id)
        let back = try #require(try await rig.store.meeting(id: meeting.id))
        #expect(back.state == .interrupted && back.duration >= 6, "the length is where the last words ended")
        let folder = await rig.store.folder(for: meeting.id)
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("mic.m4a").path))
        #expect(back.completedSteps.contains(.audio))
        #expect(try await rig.store.segments(for: meeting.id).count == 2)

        await rig.services.recover()  // a second launch changes nothing
        #expect(try await rig.store.meeting(id: meeting.id)?.state == .interrupted)
        #expect(rig.scripted.requests.count == 1)
    }

    @Test func aChainThatWasCutShortRunsAgainAtLaunch() async throws {
        let rig = ServicesRig()
        defer { rig.cleanup() }
        let meeting = try await rig.saved(state: .processing)
        await rig.services.recover()
        await rig.services.waitForProcessing(meeting.id)
        #expect(try await rig.store.meeting(id: meeting.id)?.state == .finished)
        #expect(try await rig.services.summaryText(meetingID: meeting.id) != nil)
    }

    @Test func aMeetingWithoutSpeechIsNotSummarizedAutomaticallyAndSaysWhyWhenAsked() async throws {
        let rig = ServicesRig()
        defer { rig.cleanup() }
        let empty = Meeting(title: "Silent", date: Date(), state: .processing)
        try await rig.store.create(empty)
        await rig.services.process(empty.id)
        #expect(rig.scripted.requests.isEmpty)
        await #expect(throws: LLMError.emptyResponse) { try await rig.services.summarize(meetingID: empty.id) }
        #expect(try await rig.store.meeting(id: empty.id)?.summaryFailure == "Nothing was transcribed, so there is nothing to summarize.")
    }

    @Test func theDateTitleIsReplacedByASuggestedOneAfterTheFirstSummary() async throws {
        let rig = ServicesRig(claude: TitlingClaude(title: "\"Launch planning\"\n"))
        defer { rig.cleanup() }
        #expect(rig.services.newMeeting().titleIsAutomatic && !rig.services.newMeeting(title: "Mine").titleIsAutomatic)
        let meeting = try await rig.saved(state: .finished, automaticTitle: true)
        try await rig.services.summarize(meetingID: meeting.id)
        let saved = try #require(try await rig.store.meeting(id: meeting.id))
        #expect(saved.title == "Launch planning" && !saved.titleIsAutomatic && saved.completedSteps.contains(.summary))
    }

    @Test func aTitleTheUserTypedDuringTheCallWinsAndAChosenTitleIsNeverAsked() async throws {
        let hook = Mutex<(@Sendable () async -> Void)?>(nil)
        let raced = ServicesRig(claude: TitlingClaude(title: "Suggested") { await hook.withLock { $0 }?() })
        defer { raced.cleanup() }
        let meeting = try await raced.saved(state: .finished, automaticTitle: true)
        let store = raced.store
        hook.withLock { $0 = { _ = try? await store.updateMetadata(id: meeting.id, MeetingMetadata(title: "My own")) } }
        try await raced.services.summarize(meetingID: meeting.id)
        let result = try #require(try await raced.store.meeting(id: meeting.id))
        #expect(result.title == "My own" && !result.titleIsAutomatic)

        let asked = Mutex(0)
        let chosen = ServicesRig(claude: TitlingClaude(title: "Suggested") { asked.withLock { $0 += 1 } })
        defer { chosen.cleanup() }
        let kept = try await chosen.saved(state: .finished)
        try await chosen.services.summarize(meetingID: kept.id)
        let keptTitle = try await chosen.store.meeting(id: kept.id)?.title
        #expect(asked.withLock { $0 } == 0 && keptTitle == "Weekly")
    }

    @Test func aFailedTitleRequestLeavesTheSummaryAndTheDateTitle() async throws {
        let rig = ServicesRig(claude: TitlingClaude(title: nil))
        defer { rig.cleanup() }
        let meeting = try await rig.saved(state: .finished, automaticTitle: true)
        let text = try await rig.services.summarize(meetingID: meeting.id)
        let saved = try #require(try await rig.store.meeting(id: meeting.id))
        #expect(saved.title == "Weekly" && saved.titleIsAutomatic && saved.summaryFailure == nil && saved.completedSteps.contains(.summary))
        #expect(try await rig.services.summaryText(meetingID: meeting.id) == text)
    }

    @Test func aCalendarTitleReplacesTheDateTitleSoTheSummaryKeepsItAndATypedTitleStays() async throws {
        let asked = Mutex(0)
        let rig = ServicesRig(claude: TitlingClaude(title: "Suggested") { asked.withLock { $0 += 1 } })
        defer { rig.cleanup() }
        let event = CalendarEventInfo(title: " Design review ", start: Date(), end: Date().addingTimeInterval(1800), attendees: ["Ada", "Grace"])
        let meeting = try await rig.saved(state: .finished, automaticTitle: true)
        #expect(await rig.services.applyCalendarEvent(event, to: meeting.id))
        let titled = try #require(try await rig.store.meeting(id: meeting.id))
        #expect(titled.title == "Design review" && !titled.titleIsAutomatic && titled.attendees == ["Ada", "Grace"])
        try await rig.services.summarize(meetingID: meeting.id)
        #expect(try await rig.store.meeting(id: meeting.id)?.title == "Design review" && asked.withLock { $0 } == 0)

        let typed = try await rig.saved(state: .finished)
        #expect(await rig.services.applyCalendarEvent(event, to: typed.id) == false)
        let kept = try #require(try await rig.store.meeting(id: typed.id))
        #expect(kept.title == "Weekly" && kept.attendees.isEmpty)
    }
}
