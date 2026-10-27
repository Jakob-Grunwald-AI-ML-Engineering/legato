import AppKit
import Foundation
import LegatoAppServices
import LegatoAudio
import LegatoClaude
import LegatoCore
import LegatoMac
import LegatoMeetings
import Observation
import Synchronization
import os

/// Records meetings: the mic and the system audio are mixed into one stream of one `MeetingSession`, with
/// one live engine and speakers told apart by diarization.
///
/// - `start` opens the mic first, on the call app's input device (with a fallback to no voice processing when it does
///   not work, and a notice when it hears nothing), then the system-audio tap (the tap excludes our own process, which only
///   exists for Core Audio once the mic has touched it).
/// - `stop` ends the capture and runs the after-stop chain (post-pass, m4a, on-device summary) in a task.
/// - Pause silences everything and keeps the timeline; End and Discard are the window's own, behind a confirmation.
/// - The mic is muted when `AutoMutePolicy` says the call app closed its mic, or when the user says so.
///   `MeetingMuteState` combines them: the user's choice wins in both directions until the automatic
///   decision next changes.
/// - The meeting's mic is a second `AVAudioEngine` input beside push-to-talk dictation's own `MicSource`.
///   Two engines on the same input device are allowed by Core Audio; not driven on a device by the author.
/// - A meeting never touches the dictation session.
@MainActor @Observable
final class MeetingController {
    static let windowID = "meetings"

    private static let log = Logger(subsystem: "de.gruenwald.legato", category: "meetings")

    enum Phase: Equatable { case idle, starting, recording, stopping }

    private(set) var phase = Phase.idle

    /// Newest first.
    private(set) var meetings: [Meeting] = []
    /// The live meeting as the session last published it.
    private(set) var live: MeetingSnapshot?
    /// Seconds since the meeting began, ticking once a second while recording.
    private(set) var elapsed: TimeInterval = 0
    private(set) var tapStatus: SystemAudioStatus?
    /// The engine the running meeting uses ("Apple Speech", a model's id), and why it differs from the pick.
    private(set) var engineName: String?
    private(set) var engineFallback: String?
    private(set) var mute = MeetingMuteState()
    /// Meetings whose after-stop chain or an explicit action is running.
    private(set) var busy: Set<UUID> = []
    /// What to tell the user, per meeting; each notice is dismissible and goes when it stops being true.
    private(set) var notices = MeetingNotices()
    /// What the heavy steps of each meeting are doing (waiting in the queue, or running a step), as the services report it.
    private(set) var processing: [UUID: ProcessingStage] = [:]
    /// A Claude key is stored. Read from the Keychain at launch and when the key changes, not per view update.
    private(set) var hasClaudeKey = false
    /// Bumped when a meeting finished or changed on disk, so open detail views reload.
    private(set) var revision = 0
    /// Set when a start or stop should bring the Meetings window up.
    private(set) var windowRequests = 0
    /// The meeting a live session owns, while one records.
    private(set) var liveMeetingID: UUID?
    /// The card line (summary one-liner, else the first transcript line) of each meeting.
    private(set) var cards: [UUID: String] = [:]
    /// The recorder is shrunk to the floating pill.
    private(set) var pillVisible = false
    /// The meeting language for the next start (a locale identifier); nil is Auto. Remembered.
    var language: String? {
        didSet { settings.language = language }
    }

    @ObservationIgnored let services: MeetingServices
    @ObservationIgnored let settings: MeetingSettings
    @ObservationIgnored private let store: MeetingStore
    @ObservationIgnored private let keyStore: KeychainKeyStore
    @ObservationIgnored private let defaults: UserDefaults

    @ObservationIgnored private var session: MeetingSession?
    @ObservationIgnored private var snapshotTask: Task<Void, Never>?
    @ObservationIgnored private var tapTask: Task<Void, Never>?
    @ObservationIgnored private var micNoticeTask: Task<Void, Never>?
    @ObservationIgnored private var cleaningNoticeTask: Task<Void, Never>?
    @ObservationIgnored private var startTask: Task<Void, Never>?
    @ObservationIgnored private var autoMuteTask: Task<Void, Never>?
    @ObservationIgnored private var clockTask: Task<Void, Never>?
    @ObservationIgnored private var muteWriter: Task<Void, Never>?
    @ObservationIgnored private var muteCommands: AsyncStream<Bool>.Continuation?
    @ObservationIgnored private var policy = AutoMutePolicy(ownPID: ProcessInfo.processInfo.processIdentifier)
    @ObservationIgnored private var lastProcesses: [AutoMuteProcess] = []
    @ObservationIgnored private var recovered = false
    @ObservationIgnored private var cardSignatures: [UUID: String] = [:]
    @ObservationIgnored private lazy var pill = MeetingPillPanelController(meetings: self)

    init(models: ModelServices, root: URL? = nil, defaults: UserDefaults = .standard) {
        let root = root ?? URL.applicationSupportDirectory
            .appending(path: "Legato", directoryHint: .isDirectory)
            .appending(path: "Meetings", directoryHint: .isDirectory)
        let store = MeetingStore(root: root)
        let settings = MeetingSettings(defaults: defaults)
        let keys = KeychainKeyStore()
        self.store = store
        self.settings = settings
        self.defaults = defaults
        language = settings.language
        keyStore = keys
        hasClaudeKey = Self.keyExists(keys)
        let activity = MacActivitySampler()
        services = MeetingServices(
            models: models, store: store, settings: settings, keyStore: keys,
            sampler: { IdleSample(cpuLoad: activity.cpuLoad(), secondsSinceInput: activity.secondsSinceInput()) })
        services.onProgress = { [weak self] id, stage in
            self?.processing[id] = stage
        }
        services.onProcessed = { [weak self] id, outcome, error in
            guard let self else { return }
            // What the last run found replaces what the run before it found.
            if let outcome { notices.set(outcome.notes, kind: .processing, meeting: id) }
            if let error, !(error is CancellationError) {
                Self.log.error("Processing failed: \(String(describing: type(of: error)), privacy: .public)")
                notices.set(["Processing failed: \(error.localizedDescription)"], kind: .processing, meeting: id)
            }
            Task { await self.refresh() }
        }
    }

    private func setPhase(_ new: Phase) {
        phase = new
        services.setRecording(isRecording)
    }

    // MARK: Derived state

    /// The latest notice about the app itself (a start that failed): the menu shows it.
    var notice: String? { notices.latestGlobal?.text }

    func dismissNotice(_ id: Int) { notices.dismiss(id) }

    /// The meeting's heavy steps are running, or the app is doing something to it.
    func isWorking(_ id: UUID) -> Bool { busy.contains(id) || processing[id]?.isRunning == true }

    /// What the banner of the meeting's document says: waiting, a recording in the way, or the step that runs.
    func banner(for meeting: Meeting) -> MeetingBanner {
        MeetingBanner.make(
            meeting: meeting, stage: processing[meeting.id], recordingActive: isRecording, actionRunning: busy.contains(meeting.id),
            device: "Mac")
    }

    var isRecording: Bool { phase == .recording || phase == .starting || phase == .stopping }
    var isMuted: Bool { mute.effective }
    var isPaused: Bool { live?.isPaused ?? false }
    var pillState: MeetingPillState {
        let pillPhase: MeetingPillState.Phase = switch phase {
        case .idle: .idle
        case .starting: .starting
        case .recording: .recording
        case .stopping: .stopping
        }
        return MeetingPillState(phase: pillPhase, paused: isPaused, muted: isMuted)
    }
    /// The microphone is muted because because the call app closed its mic, and the user has not said otherwise.
    var autoMute: Bool { mute.autoWants && mute.manualOverride == nil }

    var systemAudioWarning: String? {
        switch tapStatus {
        case .systemAudioSilent:
            "System audio is silent although something is playing. Turn Legato on in System Settings > Privacy & Security > System Audio Recording Only."
        case .failed(let message):
            "System audio failed: \(message)"
        default:
            nil
        }
    }

    var statusText: String {
        switch phase {
        case .idle: "No meeting"
        case .starting: "Starting meeting…"
        case .recording: isPaused ? "Recording · paused" : isMuted ? "Recording · muted" : "Recording"
        case .stopping: "Saving meeting…"
        }
    }

    // MARK: Start and stop

    func start() async {
        guard phase == .idle else { return }
        guard startTask == nil else {
            notices.post("Still cancelling the last start. Try again in a moment.", kind: .start, meeting: nil)
            return
        }
        notices.clear(kind: .start, meeting: nil)
        setPhase(.starting)
        let task = Task { await performStart() }
        startTask = task
        await task.value
        startTask = nil
    }

    /// Cancel while "Starting meeting…". The window is free at once; the start winds down behind it (a model
    /// load cannot be interrupted, so it ends when the load returns), stops what it started and removes the
    /// meeting folder. A new start waits until then.
    func cancelStart() {
        guard phase == .starting, let startTask else { return }
        startTask.cancel()
        setPhase(.idle)
        notices.post("Meeting start cancelled.", kind: .start, meeting: nil)
    }

    private func performStart() async {
        let language = settings.language.map { Locale(identifier: $0) }
        let engines = await services.engines(for: .macOS, locale: language)
        guard !Task.isCancelled else { return }
        engineName = engines.engineID == "apple-speech" ? "Apple Speech" : engines.engineID
        engineFallback = engines.fallbackReason

        let meeting = services.newMeeting(title: Self.defaultTitle(Date()), engines: engines)
        let id = meeting.id
        let folder: URL
        do { folder = try await store.createFolder(for: id) } catch {
            guard !Task.isCancelled else { return }
            setPhase(.idle)
            notices.post("Could not create the meeting folder: \(error.localizedDescription)", kind: .start, meeting: nil)
            return
        }
        guard !Task.isCancelled else {
            try? FileManager.default.removeItem(at: folder)
            return
        }
        // The mic the call app records from, not just the default input (which may be a headset mic nobody uses).
        let monitor = MicInUseMonitor()
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let mic = VoiceProcessingFallbackMic(
            voiceProcessing: engines.voiceProcessing, device: monitor.meetingMic(ownPID: ownPID).pinned,
            devices: MicDevices(
                defaultInput: { AudioDevices.defaultInput() }, name: { AudioDevices.name(of: $0) },
                callInput: { monitor.meetingMic(ownPID: ownPID).pinned }))
        let system = SystemAudioSource()
        #if DEBUG
        let counter = ZeroCountingSource(system)
        let tap: any AudioSource = measureTap ? counter : system
        selfTestSource = measureTap ? counter : nil
        #else
        let tap: any AudioSource = system
        #endif
        let made = services.makeSession(
            meeting: meeting, mic: mic, system: tap, engines: engines, sink: MeetingAudioWriter(folder: folder))
        let session = made.session
        do {
            try await session.start()
        } catch {
            try? FileManager.default.removeItem(at: folder)
            // A cancelled start already told the user and freed the window.
            guard !(error is CancellationError), !Task.isCancelled else { return }
            Self.log.error("meeting start failed: \(String(describing: type(of: error)), privacy: .public)")
            setPhase(.idle)
            notices.post("Could not start the meeting: \(error.localizedDescription)", kind: .start, meeting: nil)
            return
        }
        guard !Task.isCancelled else {
            _ = await session.stop()
            try? FileManager.default.removeItem(at: folder)
            return
        }
        beginObserving(session: session, system: system, mic: mic, cleaningNotices: made.notices, meetingID: meeting.id)
        liveMeetingID = meeting.id
        setPhase(.recording)
        windowRequests += 1
    }

    /// Ends the capture. The after-stop chain runs in a task unless `runPipeline` is false (the self-test).
    @discardableResult
    func stop(runPipeline: Bool = true) async -> Meeting? {
        guard phase == .recording, let session else { return nil }
        setPhase(.stopping)
        stopObserving()
        let meeting = await session.stop()
        endLive(meeting.id)
        await refresh()
        if runPipeline { process(meeting.id) }
        return meeting
    }

    /// Stops the capture and removes the meeting with everything recorded. The window asked first.
    func discard() async {
        guard phase == .recording, let session else { return }
        let id = session.meetingID
        setPhase(.stopping)
        stopObserving()
        await session.discard()
        endLive(id)
        notices.removeMeeting(id)
        await refresh()
    }

    private func endLive(_ id: UUID) {
        // What was said about the recording is no longer true once it ended.
        notices.clear(kind: .live, meeting: id)
        session = nil
        live = nil
        liveMeetingID = nil
        tapStatus = nil
        mute = MeetingMuteState()
        hidePill()
        setPhase(.idle)
    }

    // MARK: Pause

    func togglePause() {
        guard phase == .recording, let session else { return }
        Task { if isPaused { await session.resume() } else { await session.pause() } }
    }

    // MARK: Pill

    /// The recorder as a floating pill: the toolbar button, the menu item and ⌃⌘M. Shrinking closes the
    /// Meetings window; expanding brings it back.
    func togglePill() {
        if pillVisible {
            hidePill()
            windowRequests += 1
        } else if phase == .recording {
            pillVisible = true
            pill.show()
            for window in NSApp.windows where window.title == "Meetings" { window.close() }
        }
    }

    private func hidePill() {
        guard pillVisible else { return }
        pillVisible = false
        pill.hide()
    }

    func toggle() async {
        if phase == .recording { await stop() } else { await start() }
    }

    // MARK: Mute

    /// The button, menu item and hotkey: flips what is in effect now, whether it was muted by hand or by the
    /// call app.
    func toggleManualMute() {
        guard phase == .recording else { return }
        mute.toggle()
        reevaluateMute()
    }

    private func reevaluateMute() {
        let wantsAuto = settings.autoMute
            && policy.update(systemAudioActive: tapStatus != nil && !isTapFailed, processes: lastProcesses)
        mute.setAuto(wantsAuto)
        muteCommands?.yield(mute.effective)
    }

    private var isTapFailed: Bool {
        if case .failed = tapStatus { return true }
        return false
    }

    // MARK: Observing a running meeting

    private func beginObserving(
        session: MeetingSession, system: SystemAudioSource, mic: VoiceProcessingFallbackMic, cleaningNotices: AsyncStream<String>,
        meetingID: UUID
    ) {
        self.session = session
        mute = MeetingMuteState()
        policy = AutoMutePolicy(ownPID: ProcessInfo.processInfo.processIdentifier)
        lastProcesses = []

        snapshotTask = Task { [weak self, snapshots = session.snapshots] in
            for await snapshot in snapshots { self?.live = snapshot }
        }
        tapTask = Task { [weak self, statuses = system.statuses] in
            for await status in statuses {
                self?.tapStatus = status
                self?.reevaluateMute()
            }
        }
        micNoticeTask = Task { [weak self, notices = mic.notices] in
            for await text in notices { self?.notices.post(text, kind: .live, meeting: meetingID) }
        }
        cleaningNoticeTask = Task { [weak self] in
            for await text in cleaningNotices { self?.notices.post(text, kind: .live, meeting: meetingID) }
        }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        autoMuteTask = Task { [weak self] in
            for await processes in MicInUseMonitor().processChanges() {
                guard let self else { return }
                lastProcesses = processes
                reevaluateMute()
                // A call that starts later, or moves to another mic, takes the meeting mic along. A call app that
                // closes its mic (muted) leaves it where it is.
                if let device = MeetingMicRoute.choose(processes: processes, ownPID: ownPID, defaultInput: nil).pinned {
                    await mic.follow(device: device)
                }
            }
        }
        clockTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.elapsed = session.elapsed
                try? await Task.sleep(for: .seconds(1))
            }
        }
        // One writer, so mute and unmute reach the session in the order they were decided.
        let (commands, continuation) = AsyncStream.makeStream(of: Bool.self)
        muteCommands = continuation
        muteWriter = Task {
            var last = false
            for await muted in commands where muted != last {
                last = muted
                await session.setMuted(muted, stream: .mic)
            }
        }
    }

    private func stopObserving() {
        autoMuteTask?.cancel()
        clockTask?.cancel()
        tapTask?.cancel()
        micNoticeTask?.cancel()
        micNoticeTask = nil
        cleaningNoticeTask?.cancel()
        cleaningNoticeTask = nil
        muteCommands?.finish()
        autoMuteTask = nil
        clockTask = nil
        tapTask = nil
        muteCommands = nil
        // The snapshot task ends by itself when the session finishes its stream; the mute writer when its stream ends.
        snapshotTask = nil
        muteWriter = nil
        elapsed = 0
    }

    // MARK: Library

    func refresh() async {
        meetings = (try? await store.meetings()) ?? []
        revision += 1
        await updateCards()
    }

    /// Reads the card line of every meeting that changed since its last read: its state, its template, or the
    /// summary its card shows (written again by Regenerate or Claude).
    private func updateCards() async {
        var next: [UUID: String] = [:]
        for meeting in meetings where meeting.state != .recording {
            let summaries = (try? await store.summaries(for: meeting.id)) ?? []
            let signature = MeetingListLogic.cardSignature(meeting: meeting, summaries: summaries)
            if cardSignatures[meeting.id] == signature, let line = cards[meeting.id] {
                next[meeting.id] = line
                continue
            }
            var line = MeetingListLogic.cardLine(meeting: meeting, summaries: summaries, segments: [])
            if line.isEmpty {
                let segments = (try? await store.segments(for: meeting.id)) ?? []
                line = MeetingListLogic.cardLine(meeting: meeting, summaries: [], segments: segments)
            }
            next[meeting.id] = line
            cardSignatures[meeting.id] = signature
        }
        cards = next
    }

    /// The meetings that match a search, by title, summaries, notes, speaker names and transcript.
    func search(_ query: String) async -> Set<UUID> {
        var found: Set<UUID> = []
        for meeting in meetings where meeting.id != liveMeetingID {
            if Task.isCancelled { return found }
            let summaries = ((try? await store.summaries(for: meeting.id)) ?? []).map(\.text)
            let notes = (try? await store.notes(for: meeting.id)) ?? nil
            let segments = (try? await store.segments(for: meeting.id)) ?? []
            if MeetingListLogic.matches(query, meeting: meeting, summaries: summaries, notes: notes, segments: segments) {
                found.insert(meeting.id)
            }
        }
        return found
    }

    /// At launch: marks meetings the app died in as interrupted and finishes the after-stop chain of every
    /// meeting that is waiting for it.
    func recoverAtLaunch() async {
        guard !recovered else { return }
        recovered = true
        // A meeting started while the app was launching is alive, not crashed.
        _ = try? await MeetingRecovery.run(store: store, excluding: liveMeetingIDs)
        await refresh()
        for meeting in meetings where meeting.state == .processing || meeting.state == .interrupted {
            process(meeting.id)
        }
    }

    /// The meeting a live session owns, if any: recovery and the after-stop chain leave it alone.
    private var liveMeetingIDs: Set<UUID> { session.map { [$0.meetingID] } ?? [] }

    func transcript(of id: UUID) async -> [MeetingSegment] {
        (try? await store.segments(for: id)) ?? []
    }

    func summaries(of id: UUID) async -> [MeetingStore.Summary] {
        (try? await store.summaries(for: id)) ?? []
    }

    func folder(of id: UUID) async -> URL { await store.folder(for: id) }

    func notes(of id: UUID) async -> String { ((try? await store.notes(for: id)) ?? nil) ?? "" }

    /// Saves the private notes (while recording and afterwards). A changed note makes the summary stale.
    func saveNotes(_ text: String, for id: UUID) async {
        try? await store.saveNotes(text, for: id)
        revision += 1
    }

    /// The meeting's template: the next Regenerate (or Generate) uses it.
    func setTemplate(_ templateID: String, for id: UUID) async {
        _ = try? await store.update(id: id) { $0.templateID = templateID }
        await refresh()
    }

    /// Gives a person a name. The same name as another person's merges the two everywhere: segments and turns.
    func renameSpeaker(_ person: PersonID, to name: String, in id: UUID) async {
        // While recording the session owns the people: it takes the rename and keeps it through later turn updates.
        if id == liveMeetingID {
            await session?.renameSpeaker(person, to: name)
            return
        }
        guard let meeting = try? await store.meeting(id: id) else { return }
        var directory = SpeakerDirectory(meeting: meeting)
        let merge = directory.rename(person, to: name)
        let renamed = directory
        _ = try? await store.update(id: id) { renamed.save(into: &$0) }
        if let merge {
            try? await store.replaceSegments(merge.apply(to: await transcript(of: id)), for: id)
            if let live = try? await store.liveTurns(for: id), !live.isEmpty {
                try? await store.saveLiveTurns(merge.apply(to: live), for: id)
            }
            if let offline = try? await store.offlineTurns(for: id) {
                try? await store.saveOfflineTurns(merge.apply(to: offline), for: id)
            }
        }
        await refresh()
    }

    /// Writes the summary again with the on-device backend: the meeting's template, notes and speakers.
    func regenerate(_ id: UUID) {
        guard !busy.contains(id) else { return }
        busy.insert(id)
        notices.clear(kind: .action, meeting: id)
        Task { [weak self] in
            guard let self else { return }
            do {
                guard await services.summaryBackend() != nil else {
                    notices.post("No on-device model is available for a summary.", kind: .action, meeting: id)
                    busy.remove(id)
                    return
                }
                try await services.regenerate(meetingID: id)
            } catch {
                if !(error is CancellationError) {
                    notices.post("The summary failed: \(error.localizedDescription)", kind: .action, meeting: id)
                }
            }
            busy.remove(id)
            await refresh()
        }
    }

    /// Waiting to be processed does not stop a delete; a step that is running does.
    func delete(_ meeting: Meeting) async {
        guard meeting.state != .recording, !isWorking(meeting.id) else { return }
        let folder = await store.folder(for: meeting.id)
        try? FileManager.default.trashItem(at: folder, resultingItemURL: nil)
        notices.removeMeeting(meeting.id)
        processing[meeting.id] = nil
        await refresh()
    }

    /// Renames the meeting. The list and the document show the new title at once, not after the file is written.
    func rename(_ meeting: Meeting, to title: String) async {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if let index = meetings.firstIndex(where: { $0.id == meeting.id }) { meetings[index].title = trimmed }
        _ = try? await store.update(id: meeting.id) { $0.title = trimmed }
        await refresh()
    }

    // MARK: Actions on a meeting

    /// The after-stop chain (or its remainder) for a meeting: the audio now, the rest when the Mac is idle.
    func process(_ id: UUID) {
        guard !liveMeetingIDs.contains(id), !busy.contains(id), processing[id] == nil else { return }
        busy.insert(id)  // only for the audio step: waiting for an idle Mac is not being busy
        Task { [weak self] in
            guard let self else { return }
            do {
                let outcome = try await services.processAfterStop(id)
                for note in outcome.notes { notices.post(note, kind: .action, meeting: id) }
            } catch {
                if !(error is CancellationError) {
                    notices.post("Processing failed: \(error.localizedDescription)", kind: .action, meeting: id)
                }
            }
            busy.remove(id)
            await refresh()
        }
    }

    /// "Process now": the heavy steps without waiting for an idle Mac.
    func processNow(_ id: UUID) {
        Task { await services.processNow(id) }
    }

    /// "Improve transcript": the post-pass again, then the summary again.
    func improve(_ id: UUID) {
        run(id, label: "Improving the transcript") { services in
            try await services.improveTranscript(meetingID: id)
        }
    }

    private func run(
        _ id: UUID, label: String,
        _ work: @escaping @MainActor (MeetingServices) async throws -> MeetingPipeline.Outcome
    ) {
        guard !busy.contains(id) else { return }
        busy.insert(id)
        notices.clear(kind: .action, meeting: id)
        Task { [weak self] in
            guard let self else { return }
            do {
                let outcome = try await work(services)
                notices.set(outcome.notes, kind: .processing, meeting: id)
            } catch is CancellationError {
                // The meeting stays `processing` and resumes at the next launch.
            } catch {
                Self.log.error("\(label, privacy: .public) failed: \(String(describing: type(of: error)), privacy: .public)")
                notices.post("\(label) failed: \(error.localizedDescription)", kind: .action, meeting: id)
            }
            busy.remove(id)
            await refresh()
        }
    }

    // MARK: Claude

    var claudeDisclosureAccepted: Bool {
        get { settings.claudeDisclosureAccepted }
        set { settings.claudeDisclosureAccepted = newValue }
    }

    /// Stores the key in the Keychain. The key itself is never logged or kept in an observable property.
    /// A new or removed key asks for the disclosure again.
    func saveClaudeKey(_ key: String) -> String? {
        do {
            try settings.storeClaudeKey(key, in: keyStore)
            hasClaudeKey = Self.keyExists(keyStore)
            return nil
        } catch {
            return "The Keychain refused the key (\((error as NSError).code))."
        }
    }

    private static func keyExists(_ store: KeychainKeyStore) -> Bool { ((try? store.apiKey()) ?? nil)?.isEmpty == false }

    /// One meeting's summary from Claude. The caller has shown the one-time disclosure.
    func summarizeWithClaude(_ id: UUID) {
        guard !busy.contains(id) else { return }
        busy.insert(id)
        notices.clear(kind: .action, meeting: id)
        Task { [weak self] in
            guard let self else { return }
            do {
                try await services.summarizeWithClaude(meetingID: id)
            } catch {
                notices.post("Claude summary failed: \(error.localizedDescription)", kind: .action, meeting: id)
            }
            busy.remove(id)
            await refresh()
        }
    }

    // MARK: Export

    func markdown(for meeting: Meeting) async -> String {
        let segments = await transcript(of: meeting.id)
        let summary = await summaries(of: meeting.id).first?.text
        let notes = try? await store.notes(for: meeting.id)
        return MarkdownExporter.markdown(meeting: meeting, segments: segments, summary: summary, notes: notes)
    }

    func exportMarkdown(_ meeting: Meeting) async {
        let text = await markdown(for: meeting)
        let panel = NSSavePanel()
        panel.nameFieldStringValue = Self.fileName(meeting.title) + ".md"
        panel.allowedContentTypes = [.plainText]
        NSApp.activate()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try Data(text.utf8).write(to: url, options: .atomic) } catch {
            notices.post("Could not save the export: \(error.localizedDescription)", kind: .action, meeting: meeting.id)
        }
    }

    func showAudio(_ meeting: Meeting) async {
        let folder = await store.folder(for: meeting.id)
        let audio = ["mix.m4a", "mix.caf", "mic.m4a", "system.m4a", "mic.caf", "system.caf"]
            .map { folder.appendingPathComponent($0) }
            .first { FileManager.default.fileExists(atPath: $0.path) }
        NSWorkspace.shared.activateFileViewerSelecting([audio ?? folder])
    }

    #if DEBUG
    @ObservationIgnored fileprivate var selfTestSource: ZeroCountingSource?
    @ObservationIgnored fileprivate var measureTap = false
    #endif

    // MARK: Helpers

    static func defaultTitle(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return "Meeting \(f.string(from: date))"
    }

    private static func fileName(_ title: String) -> String {
        let bad = CharacterSet(charactersIn: "/:\\?%*|\"<>")
        let cleaned = title.components(separatedBy: bad).joined(separator: "-")
        return cleaned.isEmpty ? "Meeting" : cleaned
    }
}

// MARK: - Self-test (debug builds only)

#if DEBUG
extension MeetingController {
    /// `--meeting-selftest <seconds> [--meeting-selftest-out=<json>] [--meeting-selftest-text]`: records a
    /// throwaway meeting, writes how many words the mixed transcript holds to the JSON and exits (2 when the
    /// capture could not start, 1 when the transcript is empty). The JSON holds counts; the text only with `includeText`. A debug
    /// build feature: release builds have no such entry point.
    func runSelfTest(seconds: Double, out: URL, includeText: Bool) async -> Never {
        measureTap = true
        let report = MeetingSelfTest(controller: self, seconds: seconds, out: out, includeText: includeText)
        exit(await report.run())
    }
}

/// Counts all-zero chunks of a source, to tell a dead system-audio tap (all zeros) from a quiet one.
final class ZeroCountingSource: AudioSource {
    private let inner: any AudioSource
    private let counts = Mutex((total: 0, zero: 0))

    init(_ inner: any AudioSource) { self.inner = inner }

    var zeroRatio: Double? {
        let c = counts.withLock { $0 }
        return c.total == 0 ? nil : Double(c.zero) / Double(c.total)
    }

    var total: Int { counts.withLock { $0.total } }

    func start(format: AudioFormatSpec) async throws -> AsyncStream<AudioChunk> {
        count(try await inner.start(format: format))
    }

    func route() async throws -> AsyncStream<AudioChunk> { count(try await inner.route()) }
    func detach() async { await inner.detach() }
    func stop() async { await inner.stop() }

    private func count(_ stream: AsyncStream<AudioChunk>) -> AsyncStream<AudioChunk> {
        AsyncStream { continuation in
            let task = Task {
                for await chunk in stream {
                    let zero = !chunk.samples.contains { $0 != 0 }
                    counts.withLock { $0.total += 1; if zero { $0.zero += 1 } }
                    continuation.yield(chunk)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// The meeting self-test: a real mixed meeting for N seconds against a temporary store, then a JSON report.
/// The store (audio and transcript) is deleted afterwards; the output folder is private (`0700`).
@MainActor
private struct MeetingSelfTest {
    let controller: MeetingController
    let seconds: Double
    let out: URL
    let includeText: Bool

    func run() async -> Int32 {
        try? PrivateFiles.createDirectory(out.deletingLastPathComponent())
        await controller.start()
        guard controller.phase == .recording else {
            write(MeetingSelfTestReport(seconds: seconds, failure: controller.notice ?? "The meeting did not start."))
            return 2
        }
        NSLog("[meeting-selftest] recording for \(seconds) s")
        try? await Task.sleep(for: .seconds(seconds))
        let tapStatus = controller.tapStatus.map { "\($0)" }
        let engine = controller.engineName ?? ""
        let fallback = controller.engineFallback
        let meeting = await controller.stop(runPipeline: false)
        var segments: [MeetingSegment] = []
        if let meeting {
            segments = await controller.transcript(of: meeting.id)
            try? FileManager.default.removeItem(at: await controller.folder(of: meeting.id))
        }
        let counter = controller.selfTestSource
        let report = MeetingSelfTestReport(
            seconds: seconds, engine: engine, engineFallback: fallback, tapStatus: tapStatus, segments: segments,
            tapZeroRatio: counter?.zeroRatio, tapBuffers: counter?.total ?? 0, includeText: includeText)
        write(report)
        return report.heardSomething ? 0 : 1
    }

    private func write(_ report: MeetingSelfTestReport) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(report) { try? PrivateFiles.write(data, to: out) }
        NSLog("[meeting-selftest] wrote \(out.path)")
    }
}
#endif
