import AVFAudio
import Foundation
import LegatoAppServices
import LegatoAudio
import LegatoClaude
import LegatoCore
import LegatoMeetings
import Observation
import Synchronization
import UIKit
import os

/// The audio the meeting uses: the session and the microphone. Real on the phone, scripted in the end-to-end run.
struct MeetingAudioEnvironment: Sendable {
    var activate: @MainActor @Sendable (SessionConfig) throws -> Void
    /// Reactivates the session as it is, without touching its category (an interruption ended).
    var reactivate: @MainActor @Sendable () throws -> Void
    var deactivate: @MainActor @Sendable () -> Void
    /// A fresh microphone (a fresh `AVAudioEngine`); one per start attempt and per restart.
    var makeMic: @Sendable () -> any AudioSource

    static var live: MeetingAudioEnvironment {
        let session = AudioSessionController()
        return MeetingAudioEnvironment(
            activate: { try session.activate($0) },
            reactivate: { try session.reactivate() },
            deactivate: { session.deactivate() },
            makeMic: { MicSource() })
    }
}

/// An iOS background task that ends exactly once, from the pipeline finishing or from its expiry.
@MainActor
private final class BackgroundToken {
    private var identifier = UIBackgroundTaskIdentifier.invalid

    func begin(name: String, onExpiry: @escaping @MainActor () -> Void) {
        identifier = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            onExpiry()
            self?.end()
        }
    }

    func end() {
        guard identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(identifier)
        identifier = .invalid
    }
}

/// Records meetings on the phone: the microphone as one stream of a `MeetingSession`.
///
/// - A meeting starts only in the foreground (iOS refuses a recording session that starts in the background
///   next to other audio), ends the kept-ready microphone, and requests its Live Activity before the audio
///   session activates. Dictation is blocked while it records (`MeetingArbitration`).
/// - An interruption (a call) mutes the meeting: silence is written and the range is marked. When it ends
///   the meeting resumes; if resuming fails it resumes the next time the app is in the foreground.
/// - A route change (AirPods) restarts the engine.
/// - `stop` runs the after-stop chain inside an iOS background task; when the system is about to suspend the
///   app the chain is cancelled, the meeting stays `processing`, and the next foreground resumes it.
@MainActor @Observable
final class MeetingController {
    private static let log = Logger(subsystem: "de.gruenwald.legato", category: "meetings")

    enum Phase: Equatable { case idle, starting, recording, stopping }

    private(set) var phase = Phase.idle
    /// Newest first.
    private(set) var meetings: [Meeting] = []
    /// The live meeting as the session last published it.
    private(set) var live: MeetingSnapshot?
    private(set) var elapsed: TimeInterval = 0
    private(set) var engineName: String?
    private(set) var engineFallback: String?
    private(set) var manualMute = false
    /// A call or another app has the microphone, or the engine could not restart: the meeting is muted until it resumes.
    private(set) var interrupted = false
    private(set) var busy: Set<UUID> = []
    private(set) var notice: String?
    /// A Claude key is stored. Read from the Keychain at launch and when the key changes, not per view update.
    private(set) var hasClaudeKey = false
    /// Bumped when a meeting finished or changed on disk, so open detail views reload.
    private(set) var revision = 0

    @ObservationIgnored let services: MeetingServices
    @ObservationIgnored let settings: MeetingSettings
    @ObservationIgnored private let store: MeetingStore
    @ObservationIgnored private let keyStore: KeychainKeyStore
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let audio: MeetingAudioEnvironment
    @ObservationIgnored private let activity = MeetingActivityClient()

    /// Wired by `AppController` after its own init.
    @ObservationIgnored var isInBackground: @MainActor () -> Bool = { false }
    @ObservationIgnored var dictationActive: @MainActor () -> Bool = { false }
    /// Ends the microphone kept ready for dictation.
    @ObservationIgnored var releaseKeptMicrophone: @MainActor () async -> Void = {}
    /// A meeting began (true) or ended (false).
    @ObservationIgnored var onActiveChanged: @MainActor (Bool) -> Void = { _ in }
    #if DEBUG
    /// The end-to-end run's scripted engine, used instead of the live pick.
    @ObservationIgnored var engineOverride: (any DictationEngine)?
    #endif

    @ObservationIgnored private var session: MeetingSession?
    @ObservationIgnored private var mic: ResumableMicSource?
    @ObservationIgnored private var snapshotTask: Task<Void, Never>?
    @ObservationIgnored private var cleaningNoticeTask: Task<Void, Never>?
    @ObservationIgnored private var tokens: [UUID: BackgroundToken] = [:]
    @ObservationIgnored private var clockTask: Task<Void, Never>?
    @ObservationIgnored private var muteWriter: Task<Void, Never>?
    @ObservationIgnored private var muteCommands: AsyncStream<Bool>.Continuation?
    @ObservationIgnored private var interruptions = MeetingInterruptions()
    @ObservationIgnored private var resuming = false
    @ObservationIgnored private var startedAt = Date()
    @ObservationIgnored private var recovered = false

    init(models: ModelServices, root: URL, defaults: UserDefaults, audio: MeetingAudioEnvironment = .live) {
        let store = MeetingStore(root: root)
        let settings = MeetingSettings(defaults: defaults)
        let keys = KeychainKeyStore()
        self.store = store
        self.settings = settings
        self.defaults = defaults
        self.audio = audio
        keyStore = keys
        hasClaudeKey = Self.keyExists(keys)
        services = MeetingServices(models: models, store: store, settings: settings, keyStore: keys)
        services.onProcessed = { [weak self] id, outcome, error in
            guard let self else { return }
            if let outcome, !outcome.notes.isEmpty { notice = outcome.notes.joined(separator: " ") }
            if let error, !(error is CancellationError) {
                Self.log.error("Processing failed: \(String(describing: type(of: error)), privacy: .public)")
                notice = "Processing failed: \(error.localizedDescription)"
            }
            finishProcessing(id)
        }
    }

    private func setPhase(_ new: Phase) {
        phase = new
        services.setRecording(isActive)
    }

    // MARK: Derived state

    /// A meeting is starting, recording or stopping: dictation is blocked.
    var isActive: Bool { phase != .idle }
    var isRecording: Bool { phase == .recording }
    var isMuted: Bool { manualMute || interrupted }

    var statusText: String {
        switch phase {
        case .idle: "No meeting"
        case .starting: "Starting meeting…"
        case .recording:
            if interrupted { "Paused: the microphone is in use" } else { manualMute ? "Recording · muted" : "Recording" }
        case .stopping: "Saving meeting…"
        }
    }

    // MARK: Start and stop

    func start() async {
        guard phase == .idle else { return }
        notice = nil
        if let refusal = MeetingArbitration.meetingRefusal(
            inBackground: isInBackground(), dictationActive: dictationActive(), meetingActive: false)
        {
            notice = refusal.message
            #if DEBUG
            E2E.log("meeting.start.refused reason=\(refusal)")
            #endif
            return
        }
        setPhase(.starting)
        onActiveChanged(true)
        await releaseKeptMicrophone() // keep-ready ends when a meeting starts
        // The Live Activity first: it must exist before the audio session activates.
        startedAt = Date()
        do { try await activity.request(startedAt: startedAt) } catch {
            Self.log.error("meeting activity refused: \(String(describing: type(of: error)), privacy: .public)")
            notice = "Live Activities are off, so the recording has no Lock Screen indicator."
        }

        var engines = await services.engines(for: .iOS, locale: settings.language.map { Locale(identifier: $0) })
        #if DEBUG
        if let override = engineOverride { engines = engines.replacing(engine: override) }
        #endif
        let engineID = engines.engineID
        engineName = engineID == "apple-speech" ? "Apple Speech" : engineID
        engineFallback = engines.fallbackReason

        let meeting = services.newMeeting(title: Self.defaultTitle(Date()), engines: engines)
        let folder: URL
        do { folder = try await store.createFolder(for: meeting.id) } catch {
            await abortStart(notice: "Could not create the meeting folder: \(error.localizedDescription)", folder: nil)
            return
        }
        do { try audio.activate(.meeting) } catch {
            await abortStart(notice: "The microphone could not start: \(Self.describe(error))", folder: folder)
            return
        }

        // One retry after ~300 ms when the input reports 0 Hz right after activation, in the foreground.
        var failure: (any Error)?
        for attempt in 0..<2 {
            let writer = MeetingAudioWriter(folder: folder)
            let mic = ResumableMicSource(make: audio.makeMic)
            let made = services.makeSession(meeting: meeting, mic: mic, engines: engines, sink: writer)
            let session = made.session
            do {
                try await session.start()
                beginObserving(session: session, mic: mic)
                cleaningNoticeTask = Task { [weak self] in
                    for await text in made.notices { self?.notice = text }
                }
                setPhase(.recording)
                #if DEBUG
                E2E.log("meeting.started id=\(meeting.id.uuidString) engine=\(engineID)")
                #endif
                return
            } catch {
                failure = error
                guard attempt == 0, SystemStartEnvironment.isNoInput(error) else { break }
                try? await Task.sleep(for: DictationCoordinator.settleDelay)
            }
        }
        Self.log.error("meeting start failed: \(String(describing: type(of: failure)), privacy: .public)")
        await abortStart(notice: "Could not start the meeting: \(failure.map(Self.describe) ?? "unknown error")", folder: folder)
    }

    private func abortStart(notice: String, folder: URL?) async {
        self.notice = notice
        audio.deactivate()
        await activity.end(startedAt: startedAt)
        if let folder { try? FileManager.default.removeItem(at: folder) }
        setPhase(.idle)
        onActiveChanged(false)
        #if DEBUG
        E2E.log("meeting.start.failed notice=\(E2E.quote(notice))")
        #endif
    }

    /// Ends the capture and runs the after-stop chain in a background task.
    @discardableResult
    func stop(runPipeline: Bool = true) async -> Meeting? {
        guard phase == .recording, let session else { return nil }
        setPhase(.stopping)
        stopObserving()
        await activity.update(startedAt: startedAt, phase: .saving)
        let meeting = await session.stop()
        self.session = nil
        mic = nil
        live = nil
        manualMute = false
        interrupted = false
        interruptions = MeetingInterruptions()
        audio.deactivate()
        await activity.end(startedAt: startedAt)
        setPhase(.idle)
        onActiveChanged(false)
        #if DEBUG
        E2E.log("meeting.stopped id=\(meeting.id.uuidString) mutedRanges=\(meeting.mutedRanges.count)")
        #endif
        await refresh()
        if runPipeline { process(meeting.id) }
        return meeting
    }

    func toggle() async {
        if phase == .recording { await stop() } else { await start() }
    }

    // MARK: Mute

    func toggleManualMute() { setManualMute(!manualMute) }

    func setManualMute(_ muted: Bool) {
        guard phase == .recording, manualMute != muted else { return }
        manualMute = muted
        reevaluateMute()
        #if DEBUG
        E2E.log("meeting.mute value=\(muted ? 1 : 0)")
        #endif
    }

    private func reevaluateMute() {
        muteCommands?.yield(isMuted)
        let phase: MeetingActivityAttributes.ContentState.Phase = interrupted ? .interrupted : (manualMute ? .muted : .recording)
        let started = startedAt
        Task { await activity.update(startedAt: started, phase: phase) }
    }

    // MARK: Interruptions and routes

    /// A call, Siri or another app took the microphone: mute (silence and a marked range) until it is back.
    func interruptionBegan() {
        guard phase == .recording else { return }
        if interruptions.began(at: session?.elapsed ?? 0) {
            interrupted = true
            reevaluateMute()
        }
        #if DEBUG
        E2E.log("meeting.interruption began")
        #endif
    }

    func interruptionEnded(shouldResume: Bool) {
        guard phase == .recording else { return }
        if interruptions.ended(shouldResume: shouldResume) {
            Task { await resumeCapture() }
        }
        #if DEBUG
        E2E.log("meeting.interruption ended shouldResume=\(shouldResume ? 1 : 0)")
        #endif
    }

    /// AirPods connected or went away: the engine restarts on the new input.
    func routeChanged() {
        guard phase == .recording, !interrupted, !resuming else { return }
        Task { await resumeCapture(reactivating: false) }
    }

    /// The app is in the foreground: resume a meeting that could not resume in the background, and finish
    /// the after-stop chain of meetings the system suspended.
    func appBecameActive() {
        if phase == .recording, interruptions.shouldResumeWhenForegrounded {
            Task { await resumeCapture() }
        }
        resumeProcessing()
    }

    /// Restarts the microphone. The meeting may stop at any suspension point in here, so the phase is checked
    /// again after each one: a stopped meeting must not reactivate the audio session, and the restart itself
    /// stops an engine it created when the meeting stopped while it started.
    private func resumeCapture(reactivating: Bool = true) async {
        guard phase == .recording, let mic, !resuming else { return }
        resuming = true
        defer { resuming = false }
        var failure: (any Error)?
        for attempt in 0..<2 {
            do {
                if reactivating { try audio.reactivate() }
                try await mic.restart()
                failure = nil
                break
            } catch {
                failure = error
                guard phase == .recording, attempt == 0, SystemStartEnvironment.isNoInput(error), !isInBackground() else { break }
                try? await Task.sleep(for: DictationCoordinator.settleDelay) // 0 Hz right after activation
                guard phase == .recording else { return }
            }
        }
        guard phase == .recording else { return }
        guard failure == nil else {
            // Stay muted; the next time the app is in the foreground the meeting tries again.
            if interruptions.openSince == nil {
                _ = interruptions.began(at: session?.elapsed ?? 0)
                interrupted = true
                reevaluateMute()
            }
            interruptions.resumeFailed()
            notice = "The meeting is paused: the microphone could not restart. Open Legato to resume."
            #if DEBUG
            E2E.log("meeting.resume.failed")
            #endif
            return
        }
        if interruptions.resumed(at: session?.elapsed ?? 0) != nil {
            interrupted = false
            notice = nil
            reevaluateMute()
        }
        #if DEBUG
        E2E.log("meeting.mic.restart reactivated=\(reactivating ? 1 : 0)")
        #endif
    }

    // MARK: Observing a running meeting

    private func beginObserving(session: MeetingSession, mic: ResumableMicSource) {
        self.session = session
        self.mic = mic
        manualMute = false
        interrupted = false
        interruptions = MeetingInterruptions()
        snapshotTask = Task { [weak self, snapshots = session.snapshots] in
            for await snapshot in snapshots { self?.live = snapshot }
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
        clockTask?.cancel()
        muteCommands?.finish()
        clockTask = nil
        cleaningNoticeTask?.cancel()
        cleaningNoticeTask = nil
        muteCommands = nil
        snapshotTask = nil
        muteWriter = nil
        elapsed = 0
    }

    // MARK: Library

    func refresh() async {
        meetings = (try? await store.meetings()) ?? []
        revision += 1
    }

    /// At launch: marks meetings the app died in as interrupted and runs the after-stop chain of every
    /// meeting that waits for it.
    func recoverAtLaunch() async {
        guard !recovered else { return }
        recovered = true
        // A meeting that started while the app was launching is alive, not crashed.
        _ = try? await MeetingRecovery.run(store: store, excluding: liveMeetingIDs)
        await refresh()
        resumeProcessing()
    }

    /// The meeting a live session owns, if any: recovery and the after-stop chain leave it alone.
    private var liveMeetingIDs: Set<UUID> { session.map { [$0.meetingID] } ?? [] }

    /// Meetings whose after-stop chain was cut short (killed, or the background time ran out) continue now.
    func resumeProcessing() {
        let live = liveMeetingIDs
        for meeting in meetings where (meeting.state == .processing || meeting.state == .interrupted) && !busy.contains(meeting.id) && !live.contains(meeting.id) {
            process(meeting.id)
        }
    }

    func transcript(of id: UUID) async -> [MeetingSegment] {
        (try? await store.segments(for: id)) ?? []
    }

    func summaries(of id: UUID) async -> [MeetingStore.Summary] {
        (try? await store.summaries(for: id)) ?? []
    }

    func folder(of id: UUID) async -> URL { await store.folder(for: id) }

    func delete(_ meeting: Meeting) async {
        guard meeting.state != .recording, !busy.contains(meeting.id) else { return }
        try? FileManager.default.removeItem(at: await store.folder(for: meeting.id))
        await refresh()
    }

    func rename(_ meeting: Meeting, to title: String) async {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        _ = try? await store.update(id: meeting.id) { $0.title = trimmed }
        await refresh()
    }

    // MARK: Actions on a meeting

    /// The after-stop chain (or its remainder) for a meeting: the audio now, the rest when idle (on the phone:
    /// the app in the foreground with nothing recording), inside an iOS background task. When the system is
    /// about to suspend the app the running step is cancelled: the meeting stays `processing` and
    /// `resumeProcessing` continues it in the foreground.
    func process(_ id: UUID) {
        guard !liveMeetingIDs.contains(id), !busy.contains(id) else { return }
        busy.insert(id)
        let token = BackgroundToken()
        tokens[id] = token
        token.begin(name: "legato.meeting.pipeline") { [weak self] in
            guard let self else { return }
            Task { await self.services.scheduler.cancelRunning() }
        }
        Task { [weak self] in
            guard let self else { return }
            do {
                let outcome = try await services.processAfterStop(id)
                if !outcome.notes.isEmpty { notice = outcome.notes.joined(separator: " ") }
            } catch {
                if !(error is CancellationError) { notice = "Processing failed: \(error.localizedDescription)" }
                finishProcessing(id)
            }
        }
    }

    /// The heavy steps of `id` ended (or were cut short): free its busy mark and background time.
    private func finishProcessing(_ id: UUID) {
        busy.remove(id)
        tokens.removeValue(forKey: id)?.end()
        Task { [weak self] in
            guard let self else { return }
            await refresh()
            #if DEBUG
            let state = meetings.first { $0.id == id }?.state.rawValue ?? "missing"
            E2E.log("meeting.pipeline.done id=\(id.uuidString) state=\(state)")
            #endif
        }
    }

    /// "Improve transcript": the post-pass again, then the summary again.
    func improve(_ id: UUID) {
        run(id, label: "Improving the transcript") { services in
            try await services.pipeline().improveTranscript(meetingID: id)
        }
    }

    /// Runs `work` inside an iOS background task. When the system is about to suspend the app the work is
    /// cancelled: the meeting stays `processing` and `resumeProcessing` continues it in the foreground.
    private func run(
        _ id: UUID, label: String,
        _ work: @escaping @MainActor (MeetingServices) async throws -> MeetingPipeline.Outcome
    ) {
        guard !busy.contains(id) else { return }
        busy.insert(id)
        let task = Task { [weak self] in
            guard let self else { return }
            do {
                let outcome = try await work(services)
                if !outcome.notes.isEmpty { notice = outcome.notes.joined(separator: " ") }
            } catch is CancellationError {
                // Out of background time: the meeting stays `processing` and resumes in the foreground.
            } catch {
                Self.log.error("\(label, privacy: .public) failed: \(String(describing: type(of: error)), privacy: .public)")
                notice = "\(label) failed: \(error.localizedDescription)"
            }
            busy.remove(id)
            await refresh()
            #if DEBUG
            let state = meetings.first { $0.id == id }?.state.rawValue ?? "missing"
            E2E.log("meeting.pipeline.done id=\(id.uuidString) state=\(state)")
            #endif
        }
        let token = BackgroundToken()
        token.begin(name: "legato.meeting.pipeline") { task.cancel() }
        Task {
            await task.value
            token.end()
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
        Task { [weak self] in
            guard let self else { return }
            do {
                try await services.summarizeWithClaude(meetingID: id)
            } catch {
                notice = "Claude summary failed: \(error.localizedDescription)"
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

    /// The files the share sheet offers: the Markdown (written to a temporary file) and the recording (m4a,
    /// else the CAF) when it exists.
    func exportItems(for meeting: Meeting) async -> [URL] {
        let text = await markdown(for: meeting)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("export-\(meeting.id.uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent(Self.fileName(meeting.title) + ".md")
        do { try Data(text.utf8).write(to: file, options: .atomic) } catch {
            notice = "Could not prepare the export: \(error.localizedDescription)"
            return []
        }
        var items = [file]
        let folder = await store.folder(for: meeting.id)
        if let audio = ["mix.m4a", "mix.caf", "mic.m4a", "mic.caf"].map({ folder.appendingPathComponent($0) })
            .first(where: { FileManager.default.fileExists(atPath: $0.path) })
        {
            items.append(audio)
        }
        #if DEBUG
        E2E.log("meeting.export md=\(E2E.quote(file.path)) files=\(items.count)")
        #endif
        return items
    }

    // MARK: Helpers

    static func defaultTitle(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return "Meeting \(f.string(from: date))"
    }

    static func fileName(_ title: String) -> String {
        let bad = CharacterSet(charactersIn: "/:\\?%*|\"<>")
        let cleaned = title.components(separatedBy: bad).joined(separator: "-")
        return cleaned.isEmpty ? "Meeting" : cleaned
    }

    private static func describe(_ error: any Error) -> String {
        if SystemStartEnvironment.isRefusal(error) {
            return "iOS did not allow the recording (\(SystemStartEnvironment.refusalLabel(error))). Open Legato and try again."
        }
        return error.localizedDescription
    }
}
