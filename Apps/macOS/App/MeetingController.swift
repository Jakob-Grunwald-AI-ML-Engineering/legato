import AppKit
import Foundation
import LegatoAppServices
import LegatoAudio
import LegatoClaude
import LegatoCore
import LegatoMeetings
import LegatoSoniox
import Observation

/// What the Meetings window and the recording island show: the saved meetings, the live one, and the actions on them.
/// The engine (`MeetingServices`) records, summarizes and saves; this class only holds what the views read.
///
/// - **Recording.** `start` opens the microphone, then the system-audio tap, through `MeetingServices`; the live
///   transcript is the session's snapshots. The hotkeys for dictation and the composer ask `refusal` first.
/// - **After stop.** The services run the chain (m4a, summary); `stop` waits for it and refreshes the list so the
///   window shows each step.
/// - **The list** is read from the store and refreshed after every change made here; `shown` is it narrowed by the
///   sidebar and the search.
@MainActor @Observable
final class MeetingController {
    static let windowID = "meetings"

    enum Phase: Equatable { case idle, starting, recording, stopping }

    /// What the window shows of the meeting that records, as the session last published it.
    struct Live: Equatable {
        var meetingID: UUID
        var segments: [MeetingSegment]
        /// The tentative words of the segment in progress.
        var volatile: String
        var speakers: [PersonID: SpeakerInfo]
        var gaps: [TranscriptGap]
        /// The transcription engine is down (the audio keeps recording).
        var engineError: String?
        var audioError: String?

        init(_ snapshot: MeetingSnapshot) {
            meetingID = snapshot.meeting.id
            segments = snapshot.segments
            volatile = snapshot.volatile[.mixed] ?? ""
            speakers = snapshot.meeting.speakers
            gaps = snapshot.meeting.gaps
            engineError = snapshot.engineErrors[.mixed]
            audioError = snapshot.audioError
        }

        init(meetingID: UUID, segments: [MeetingSegment], volatile: String, speakers: [PersonID: SpeakerInfo], gaps: [TranscriptGap],
             engineError: String? = nil, audioError: String? = nil) {
            (self.meetingID, self.segments, self.volatile, self.speakers, self.gaps) = (meetingID, segments, volatile, speakers, gaps)
            (self.engineError, self.audioError) = (engineError, audioError)
        }
    }

    /// Which half of a meeting the detail shows.
    enum DetailTab: String, CaseIterable { case summary = "Summary", transcript = "Transcript" }

    let services: MeetingServices
    private(set) var phase = Phase.idle
    /// Newest first, the recording one included.
    private(set) var meetings: [Meeting] = []
    private(set) var live: Live?
    var detailTab = DetailTab.summary
    /// The details popover (title, client, project, tags) of the open meeting.
    var editingDetails = false
    /// Seconds since the meeting began, ticking while it records.
    private(set) var elapsed: TimeInterval = 0
    private(set) var tapStatus: SystemAudioStatus?
    /// What the last start, stop or action could not do, in words for the user.
    private(set) var notice: String?
    /// The notice stays until it is read (a start that failed).
    private(set) var noticeIsSticky = false
    /// Stopped meetings that have no transcript segment; with the length, what makes a meeting discardable.
    private(set) var emptyTranscripts: Set<UUID> = []
    /// Bumped when a meeting changed on disk, so open detail views reload.
    private(set) var revision = 0
    /// Set when a start should bring the Meetings window up.
    private(set) var windowRequests = 0
    var selection: UUID?
    var sidebar = MeetingSidebarItem.all
    var query = "" { didSet { if query != oldValue { search() } } }
    /// The meetings whose title, filing, summary or transcript contain every word of the query; nil without a query.
    private(set) var searchHits: Set<UUID>?

    @ObservationIgnored private var snapshotTask: Task<Void, Never>?
    @ObservationIgnored private var clockTask: Task<Void, Never>?
    @ObservationIgnored private var tapTask: Task<Void, Never>?
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var noticeTask: Task<Void, Never>?
    @ObservationIgnored private var startTask: Task<Void, Never>?

    init(root: URL, vocabularyURL: URL?, defaults: UserDefaults = .standard) {
        var sonioxKey: @Sendable () -> String = { (try? KeychainKeyStore(service: "de.gruenwald.legato.soniox").apiKey()) ?? "" }
        var claudeKeys: any APIKeyStore = KeychainKeyStore()
        var makeSocket: @Sendable () -> any SonioxSocket = { URLSessionSonioxSocket() }
        #if LEGATO_INTERNAL
        if MeetingsFaults.noSonioxKey { sonioxKey = { "" } }
        if MeetingsFaults.noClaudeKey { claudeKeys = MeetingsFaults.NoClaudeKey() }
        if let seconds = MeetingsFaults.dropSonioxAfter {
            let plan = MeetingsFaults.DropOnce(seconds: seconds)
            makeSocket = { MeetingsFaults.DroppingSocket(plan: plan) }
        }
        #endif
        services = MeetingServices(
            store: MeetingStore(root: root), settings: MeetingSettings(defaults: defaults),
            sonioxKey: sonioxKey, claudeKeys: claudeKeys, vocabularyURL: vocabularyURL, makeSocket: makeSocket)
    }

    var isRecording: Bool { phase != .idle || services.isRecording }
    /// Why dictation and the composer may not start now; nil when they may.
    var refusal: String? { MeetingArbitration.dictationRefusal(meetingActive: isRecording) }

    /// At launch: marks meetings the app died in as interrupted, finishes cut-off chains, loads the list.
    func bootstrap() {
        Task {
            await services.recover()
            await refresh()
        }
    }

    // MARK: Recording

    /// Starts a meeting. Everything that can go wrong before audio is recorded (a refusal, a missing Soniox key, a
    /// denied permission) ends up in `notice` and nothing is kept.
    func start(dictationActive: Bool) {
        guard phase == .idle else { return }
        phase = .starting
        notice = nil
        startTask = Task {
            let system = SystemAudioSource()
            do {
                let session = try await services.startMeeting(mic: AutomaticInputSource(), system: system, dictationActive: dictationActive)
                observe(session, system: system)
                phase = .recording
                windowRequests += 1
                await refresh()
                selection = session.meetingID
                sidebar = .all
                query = ""
            } catch {
                phase = .idle
                flash(Self.describe(error), seconds: nil)
            }
        }
    }

    /// Stops the recording, then follows the after-stop chain until it ends.
    func stop() {
        guard phase == .recording else { return }
        phase = .stopping
        stopObserving()
        Task {
            let meeting = await services.stopMeeting()
            phase = .idle
            live = nil
            await refresh()
            guard let meeting else { return }
            await services.waitForProcessing(meeting.id)
            await refresh()
        }
    }

    /// Stops the recording and deletes everything of it.
    func discard() {
        guard phase == .recording else { return }
        phase = .stopping
        stopObserving()
        Task {
            await services.discardMeeting()
            phase = .idle
            live = nil
            selection = nil
            await refresh()
        }
    }

    private func observe(_ session: MeetingSession, system: SystemAudioSource) {
        live = nil
        elapsed = 0
        snapshotTask = Task { for await snapshot in session.snapshots { live = Live(snapshot) } }
        clockTask = Task {
            while !Task.isCancelled {
                elapsed = session.elapsed
                try? await Task.sleep(for: .seconds(1))
            }
        }
        tapTask = Task { for await status in system.statuses { tapStatus = status } }
    }

    private func stopObserving() {
        snapshotTask?.cancel(); clockTask?.cancel(); tapTask?.cancel()
        snapshotTask = nil; clockTask = nil; tapTask = nil
        tapStatus = nil
    }

    /// What the island and the live view warn about while recording: the system-audio permission, a transcript
    /// connection that is down (the audio still records).
    var liveWarning: String? {
        switch tapStatus {
        case .systemAudioSilent: return "The other side is silent. Allow Legato under System Settings, Privacy & Security, System Audio Recording."
        case .failed(let reason): return "System audio stopped: \(reason)"
        default: break
        }
        if live?.engineError != nil { return "Transcription is offline. The audio keeps recording." }
        if let audio = live?.audioError { return "Recording problem: \(audio)" }
        return nil
    }

    func showWindow() { windowRequests += 1 }

    // MARK: Notices

    /// Shows `text` in the island and the window: for `seconds`, or until it is read (`dismissNotice()`) when nil.
    func flash(_ text: String, seconds: Double? = 5) {
        notice = text
        noticeIsSticky = seconds == nil
        noticeTask?.cancel()
        guard let seconds else { return }
        noticeTask = Task {
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            notice = nil
        }
    }

    /// The notice was read.
    func dismissNotice() {
        noticeTask?.cancel()
        notice = nil
        noticeIsSticky = false
    }

    private static func describe(_ error: any Error) -> String {
        if let error = error as? SonioxError, error == .missingKey {
            return "Add your Soniox key in Settings, API Keys, to record meetings. Nothing was recorded."
        }
        if let error = error as? SystemAudioSourceError {
            if case .coreAudio = error { return "System audio could not start. Allow Legato under System Settings, Privacy & Security, System Audio Recording." }
        }
        return (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    // MARK: Saved meetings

    func refresh() async {
        meetings = (try? await services.meetings()) ?? meetings
        var empty = Set<UUID>()
        for meeting in meetings where meeting.state != .recording {
            if !(await services.store.hasSegments(for: meeting.id)) { empty.insert(meeting.id) }
        }
        emptyTranscripts = empty
        revision += 1
        if let selection, !meetings.contains(where: { $0.id == selection }) { self.selection = nil }
        search()
    }

    func meeting(_ id: UUID?) -> Meeting? { id.flatMap { id in meetings.first { $0.id == id } } }

    /// The list: narrowed by the sidebar and by the search.
    var shown: [Meeting] {
        meetings.filter { sidebar.includes($0) && (searchHits?.contains($0.id) ?? true) }
    }

    func updateMetadata(_ id: UUID, _ metadata: MeetingMetadata) {
        Task {
            do { try await services.updateMetadata(meetingID: id, metadata) } catch { flash(Self.describe(error)) }
            await refresh()
        }
    }

    func renameSpeaker(_ id: UUID, person: PersonID, to name: String) {
        Task {
            do { try await services.renameSpeaker(meetingID: id, person: person, to: name) } catch { flash(Self.describe(error)) }
            await refresh()
        }
    }

    /// Writes the summary, or writes it again after a failure. The failure stays on the meeting.
    func summarize(_ id: UUID) {
        Task {
            _ = try? await services.summarize(meetingID: id)
            await refresh()
        }
    }

    /// A stopped meeting too short to keep or without a transcript: Discard removes it without asking.
    func canDiscard(_ meeting: Meeting) -> Bool {
        meeting.id != services.activeMeetingID && meeting.isDiscardable(transcriptIsEmpty: emptyTranscripts.contains(meeting.id))
    }

    func delete(_ id: UUID) {
        Task {
            do { try await services.deleteMeeting(id: id) } catch { flash(Self.describe(error)) }
            await refresh()
        }
    }

    // MARK: Search

    private func search() {
        searchTask?.cancel()
        let words = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty else { searchHits = nil; return }
        let candidates = meetings
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(200))
            var hits = Set<UUID>()
            for meeting in candidates {
                if Task.isCancelled { return }
                let segments = (try? await services.store.segments(for: meeting.id)) ?? []
                let summaries = ((try? await services.store.summaries(for: meeting.id)) ?? []).map(\.text)
                if MeetingListLogic.matches(words, meeting: meeting, summaries: summaries, notes: nil, segments: segments) { hits.insert(meeting.id) }
            }
            if !Task.isCancelled { searchHits = hits }
        }
    }

    #if LEGATO_INTERNAL
    /// Preview only: shows `live` as the live meeting without a session, so the window and island can be drawn.
    func previewLive(_ live: Live, elapsed: TimeInterval) {
        self.live = live
        self.elapsed = elapsed
        phase = .recording
    }
    #endif
}
