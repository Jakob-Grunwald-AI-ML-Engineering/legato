import Foundation
import Observation
import LegatoAudio
import LegatoClaude
import LegatoCore
import LegatoMeetings
import LegatoRoom
import LegatoSoniox
import LegatoVocabulary

/// Why ``MeetingServices`` refused to do something.
public enum MeetingServicesError: Error, Equatable, LocalizedError {
    /// A meeting cannot start now: one records already, or a dictation runs.
    case refused(MeetingStartRefusal)
    case unknownMeeting
    case alreadySummarizing

    public var errorDescription: String? {
        switch self {
        case .refused(let refusal): refusal.message
        case .unknownMeeting: "This meeting no longer exists."
        case .alreadySummarizing: "The summary is already being written."
        }
    }
}

/// What the Mac app calls to record, process and summarize meetings: the factory of ``MeetingSession`` (one Soniox
/// stream with speakers on the mix of the microphone and the system audio), the after-stop chain, and the actions on
/// saved meetings.
///
/// - **Start/stop.** ``startMeeting(title:mic:system:dictationActive:)`` refuses while a meeting or a dictation
///   runs (``MeetingServicesError/refused(_:)``), fails before anything is recorded when the Soniox key is missing,
///   and returns the live session (its `snapshots` drive the transcript). ``stopMeeting()`` stops it and starts the
///   after-stop chain: the CAF recordings become m4a, then the Claude summary when it is automatic.
/// - **Dictation and composer** ask ``dictationRefusal`` and show its notice while a meeting records.
/// - **Summary.** Claude through the user's key, one request for the transcript (map-reduce only when it would not
///   fit). A failed summary leaves the meeting as it is and keeps the reason in ``Meeting/summaryFailure``;
///   ``summarize(meetingID:)`` is also the retry.
/// - **Launch.** ``recover()`` marks meetings that were recording as interrupted and finishes any after-stop chain
///   that was cut short.
@MainActor @Observable
public final class MeetingServices {
    public let settings: MeetingSettings
    public let store: MeetingStore

    /// The meeting that records now.
    public private(set) var activeMeetingID: UUID?
    /// Its session, for the live transcript.
    public private(set) var session: MeetingSession?
    /// Meetings whose after-stop chain runs.
    public private(set) var processing: Set<UUID> = []
    /// Meetings whose summary is being written.
    public private(set) var summarizing: Set<UUID> = []

    @ObservationIgnored private let sonioxKey: @Sendable () -> String
    @ObservationIgnored private let makeClaude: @Sendable () -> any LLMBackend
    @ObservationIgnored private let makeSocket: @Sendable () -> any SonioxSocket
    @ObservationIgnored private let vocabularyURL: URL?
    @ObservationIgnored private let personalPrompt: @Sendable () -> String
    @ObservationIgnored private let timing: SonioxMeetingEngine.Timing
    @ObservationIgnored private var starting = false
    @ObservationIgnored private var chains: [UUID: Task<Void, Never>] = [:]

    /// - Parameters:
    ///   - sonioxKey: read when a meeting starts and whenever a stream connects.
    ///   - claudeKeys: where the Claude key lives; the summary asks Claude with it.
    ///   - claudeBackend: replaces the Claude backend (tests).
    ///   - vocabularyURL: the user's vocabulary, sent to Soniox as terms.
    public init(
        store: MeetingStore, settings: MeetingSettings, sonioxKey: @escaping @Sendable () -> String, claudeKeys: any APIKeyStore,
        claudeBackend: (any LLMBackend)? = nil, vocabularyURL: URL? = nil,
        personalPrompt: @escaping @Sendable () -> String = { UserDefaults.standard.string(forKey: "composer.personalPrompt") ?? "" },
        makeSocket: @escaping @Sendable () -> any SonioxSocket = { URLSessionSonioxSocket() },
        timing: SonioxMeetingEngine.Timing = SonioxMeetingEngine.Timing()
    ) {
        self.store = store
        self.settings = settings
        self.sonioxKey = sonioxKey
        self.makeClaude = { claudeBackend ?? ClaudeBackend(keyStore: claudeKeys) }
        self.vocabularyURL = vocabularyURL
        self.personalPrompt = personalPrompt
        self.makeSocket = makeSocket
        self.timing = timing
    }

    // MARK: Arbitration

    /// A meeting records, or is about to.
    public var isRecording: Bool { activeMeetingID != nil || starting }

    /// What a dictation or composer start says when it is refused because a meeting records; nil when it may go ahead.
    public var dictationRefusal: String? { MeetingArbitration.dictationRefusal(meetingActive: isRecording) }

    // MARK: Recording

    /// A new meeting set up for now: titled by its date, the default summary sections ticked.
    public func newMeeting(id: UUID = UUID(), title: String? = nil, date: Date = Date()) -> Meeting {
        Meeting(
            id: id, title: title ?? "Meeting \(date.formatted(date: .abbreviated, time: .shortened))", date: date,
            sections: settings.defaultSectionIDs)
    }

    /// The session for `meeting` without starting it: `mic` (and `system`) summed into one signal for one Soniox
    /// stream with speakers, the sources' audio recorded in the meeting's folder, the Room logged next to it.
    /// - Throws: whatever creating the meeting's folder or log throws.
    public func makeSession(
        meeting: Meeting, mic: any AudioSource, system: (any AudioSource)? = nil,
        clock: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) async throws -> MeetingSession {
        let key = sonioxKey()
        let folder = try await store.createFolder(for: meeting.id)
        let log = try SessionLog(rootDirectory: await store.logRoot(for: meeting.id), sessionID: "log", secrets: [key])
        let terms = await vocabularyTerms()
        let engine = SonioxMeetingEngine(
            apiKey: sonioxKey, config: SonioxConfig(mode: "Meeting", personalPrompt: personalPrompt(), terms: terms, diarization: true),
            log: log, makeSocket: makeSocket, timing: timing)
        var sources = [MeetingSource(stream: .mic, source: mic)]
        if let system { sources.append(MeetingSource(stream: .system, source: system)) }
        return MeetingSession(
            meeting: meeting, sources: sources, engine: engine, store: store, sink: MeetingAudioWriter(folder: folder), clock: clock)
    }

    /// Starts a meeting and returns its live session.
    /// - Parameter dictationActive: a dictation or composition holds the microphone.
    /// - Throws: ``MeetingServicesError/refused(_:)``; `SonioxError.missingKey` without a Soniox key (nothing is
    ///   recorded); the error of a source that cannot start (a denied permission). A failed start leaves nothing behind.
    @discardableResult
    public func startMeeting(
        title: String? = nil, mic: any AudioSource, system: (any AudioSource)? = nil, dictationActive: Bool = false,
        clock: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) async throws -> MeetingSession {
        if let refusal = MeetingArbitration.meetingRefusal(dictationActive: dictationActive, meetingActive: isRecording) {
            throw MeetingServicesError.refused(refusal)
        }
        starting = true
        defer { starting = false }
        let meeting = newMeeting(title: title)
        do {
            let session = try await makeSession(meeting: meeting, mic: mic, system: system, clock: clock)
            try await session.start()
            self.session = session
            activeMeetingID = meeting.id
            return session
        } catch {
            try? await store.deleteMeeting(id: meeting.id)
            throw error
        }
    }

    /// Stops the recording and starts the after-stop chain (see ``process(_:)``); `nil` when no meeting records.
    @discardableResult
    public func stopMeeting() async -> Meeting? {
        guard let session else { return nil }
        let meeting = await session.stop()
        self.session = nil
        activeMeetingID = nil
        beginChain(meeting.id)
        return meeting
    }

    /// Stops the recording and deletes everything of the meeting.
    public func discardMeeting() async {
        guard let session else { return }
        await session.discard()
        self.session = nil
        activeMeetingID = nil
    }

    // MARK: After stop

    /// The after-stop chain of a meeting that is `processing` (or `interrupted`): the recordings become m4a and the
    /// lossless CAFs go, then the summary when it is automatic and there is something to summarize. A
    /// `processing` meeting ends `finished`; an `interrupted` one stays so. A step that fails is tried again by
    /// ``recover()`` (the audio) or by the user (``summarize(meetingID:)``).
    public func process(_ id: UUID) async {
        guard var meeting = try? await store.meeting(id: id), meeting.state == .processing || meeting.state == .interrupted
        else { return }
        if !meeting.completedSteps.contains(.audio) {
            let folder = await store.folder(for: id)
            let report = await Task.detached { MeetingAudioWriter.recover(folder: folder) }.value
            if report.failed.isEmpty {
                MeetingAudioWriter.discardLossless(in: folder)
                meeting = (try? await store.update(id: id) { $0.completedSteps.insert(.audio) }) ?? meeting
            }
        }
        if settings.summarizeAutomatically, !meeting.completedSteps.contains(.summary),
            !((try? await store.segments(for: id)) ?? []).isEmpty
        {
            _ = try? await summarize(meetingID: id)
        }
        _ = try? await store.update(id: id) { if $0.state == .processing { $0.state = .finished } }
    }

    /// Waits for the after-stop chain of `id`, if one runs.
    public func waitForProcessing(_ id: UUID) async { await chains[id]?.value }

    /// At launch: meetings still `recording` were cut off (they become `interrupted` with their audio), and a
    /// chain that was cut short runs again.
    public func recover() async {
        let live = activeMeetingID.map { Set([$0]) } ?? []
        let interrupted = (try? await MeetingRecovery.run(store: store, excluding: live)) ?? []
        let unfinished = ((try? await store.meetings()) ?? []).filter { $0.state == .processing && !live.contains($0.id) }.map(\.id)
        for id in Set(interrupted + unfinished) { beginChain(id) }
    }

    private func beginChain(_ id: UUID) {
        guard chains[id] == nil else { return }
        processing.insert(id)
        chains[id] = Task { [self] in
            await process(id)
            chains[id] = nil
            processing.remove(id)
        }
    }

    // MARK: Summary

    /// Writes the meeting's summary with Claude (its ticked sections, notes, speakers' names and language) and
    /// returns it. This is Summarize, Regenerate and the retry after a failure: a failure is kept in
    /// ``Meeting/summaryFailure`` (the meeting and its transcript stay) and thrown.
    /// - Throws: ``MeetingServicesError/alreadySummarizing``, ``LLMError`` (`unavailable` without a Claude key).
    @discardableResult
    public func summarize(meetingID id: UUID) async throws -> String {
        guard !summarizing.contains(id) else { throw MeetingServicesError.alreadySummarizing }
        summarizing.insert(id)
        defer { summarizing.remove(id) }
        do {
            guard let meeting = try await store.meeting(id: id) else { throw MeetingServicesError.unknownMeeting }
            let segments = try await store.segments(for: id)
            let notes = (try? await store.notes(for: id)) ?? ""
            let picked = settings.sections(for: meeting)
            let ticked = picked.isEmpty ? SummarySection.resolve(SummarySection.defaultIDs, in: SummarySection.builtIns) : picked
            let backend = makeClaude()
            if case .unavailable(let reason) = await backend.availability { throw LLMError.unavailable(reason: reason) }
            let text = try await MeetingSummarizer(
                backend: backend, sections: ticked, notes: notes, language: meeting.locale, speakers: meeting.speakers
            ).summarize(segments: segments)
            let ids = ticked.map(\.id)
            try await store.saveSummary(text, backendID: backend.id, sections: ids, for: id)
            try await store.update(id: id) { m in
                if m.sections == nil { m.sections = ids }
                m.completedSteps.insert(.summary)
                m.summaryFailure = nil
            }
            return text
        } catch {
            if !(error is CancellationError) {
                let message = Self.failureText(error)
                _ = try? await store.update(id: id) { $0.summaryFailure = message }
            }
            throw error
        }
    }

    /// What the user reads when a summary failed.
    static func failureText(_ error: any Error) -> String {
        switch error {
        case LLMError.unavailable(let reason):
            reason.contains("No Claude API key")
                ? "Add your Claude API key in Settings, then try the summary again." : "Claude is not available: \(reason)."
        case LLMError.guardrail: "Claude declined to summarize this meeting."
        case LLMError.contextTooLong: "This transcript is too long for Claude to summarize."
        case LLMError.emptyResponse: "Nothing was transcribed, so there is nothing to summarize."
        case LLMError.failed(let message): message
        default: error.localizedDescription
        }
    }

    // MARK: Saved meetings

    /// Newest first.
    public func meetings() async throws -> [Meeting] { try await store.meetings() }

    /// Gives a person of the meeting a name. Another person with that name merges with this one, in the segments
    /// too. The summaries written before it follow: the old name is written as the new one in their text.
    /// While the meeting records the session owns the people and does it.
    public func renameSpeaker(meetingID id: UUID, person: PersonID, to name: String) async throws {
        if id == activeMeetingID, let session {
            await session.renameSpeaker(person, to: name)
            return
        }
        guard let meeting = try await store.meeting(id: id) else { throw MeetingServicesError.unknownMeeting }
        guard let oldName = meeting.speakers[person]?.name else { return }
        var directory = SpeakerDirectory(meeting: meeting)
        let merge = directory.rename(person, to: name)
        let renamed = directory
        try await store.update(id: id) { renamed.save(into: &$0) }
        if let merge {
            try await store.replaceSegments(merge.apply(to: try await store.segments(for: id)), for: id)
        }
        guard let newName = renamed.displayName(of: merge?.into ?? person), newName != oldName else { return }
        for summary in try await store.summaries(for: id) {
            let text = SummaryNames.replacing(oldName, with: newName, in: summary.text)
            guard text != summary.text else { continue }
            try await store.saveSummary(text, backendID: summary.backendID, sections: summary.sections, for: id)
        }
    }

    /// Removes a saved meeting and everything of it. A meeting that records is not touched.
    public func deleteMeeting(id: UUID) async throws {
        guard id != activeMeetingID else { return }
        try await store.deleteMeeting(id: id)
    }

    /// The newest summary, as written; nil when there is none.
    public func summaryText(meetingID id: UUID) async throws -> String? {
        MeetingListLogic.shownSummary(in: try await store.summaries(for: id))?.text
    }

    /// The meeting as Markdown: title, date, duration, summary, notes, transcript (named speakers, gaps noted).
    public func markdown(meetingID id: UUID) async throws -> String {
        try await export(id, withSummary: true)
    }

    /// The header and the transcript only.
    public func transcriptMarkdown(meetingID id: UUID) async throws -> String {
        try await export(id, withSummary: false)
    }

    private func export(_ id: UUID, withSummary: Bool) async throws -> String {
        guard let meeting = try await store.meeting(id: id) else { throw MeetingServicesError.unknownMeeting }
        return MarkdownExporter.markdown(
            meeting: meeting, segments: try await store.segments(for: id),
            summary: withSummary ? try await summaryText(meetingID: id) : nil,
            notes: withSummary ? try await store.notes(for: id) : nil)
    }

    private func vocabularyTerms() async -> [String] {
        guard let vocabularyURL else { return [] }
        return (try? await VocabularyStore(fileURL: vocabularyURL).snapshot().entries.filter { !$0.blocked }.map(\.text)) ?? []
    }
}
