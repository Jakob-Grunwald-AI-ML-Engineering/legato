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

/// Records meetings: the mic ("me") and the system audio ("them") as two streams of one `MeetingSession`.
///
/// - `start` opens the mic first (with a fallback to no voice processing when it does not work), then the system-audio tap (the tap excludes our own process, which only
///   exists for Core Audio once the mic has touched it).
/// - `stop` ends the capture and runs the after-stop chain (post-pass, m4a, on-device summary) in a task.
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
    /// The latest thing that went wrong or was skipped, for the window.
    private(set) var notice: String?
    /// A Claude key is stored. Read from the Keychain at launch and when the key changes, not per view update.
    private(set) var hasClaudeKey = false
    /// Bumped when a meeting finished or changed on disk, so open detail views reload.
    private(set) var revision = 0
    /// Set when a start or stop should bring the Meetings window up.
    private(set) var windowRequests = 0

    @ObservationIgnored let services: MeetingServices
    @ObservationIgnored let settings: MeetingSettings
    @ObservationIgnored private let store: MeetingStore
    @ObservationIgnored private let keyStore: KeychainKeyStore
    @ObservationIgnored private let defaults: UserDefaults

    @ObservationIgnored private var session: MeetingSession?
    @ObservationIgnored private var snapshotTask: Task<Void, Never>?
    @ObservationIgnored private var tapTask: Task<Void, Never>?
    @ObservationIgnored private var micNoticeTask: Task<Void, Never>?
    @ObservationIgnored private var startTask: Task<Void, Never>?
    @ObservationIgnored private var autoMuteTask: Task<Void, Never>?
    @ObservationIgnored private var clockTask: Task<Void, Never>?
    @ObservationIgnored private var muteWriter: Task<Void, Never>?
    @ObservationIgnored private var muteCommands: AsyncStream<Bool>.Continuation?
    @ObservationIgnored private var policy = AutoMutePolicy(ownPID: ProcessInfo.processInfo.processIdentifier)
    @ObservationIgnored private var lastProcesses: [AutoMuteProcess] = []
    @ObservationIgnored private var recovered = false

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
        keyStore = keys
        hasClaudeKey = Self.keyExists(keys)
        services = MeetingServices(models: models, store: store, settings: settings, keyStore: keys)
    }

    // MARK: Derived state

    var isRecording: Bool { phase == .recording || phase == .starting || phase == .stopping }
    var isMuted: Bool { mute.effective }
    /// "Me" is muted because the call app closed its mic, and the user has not said otherwise.
    var autoMute: Bool { mute.autoWants && mute.manualOverride == nil }

    var systemAudioWarning: String? {
        switch tapStatus {
        case .systemAudioSilent:
            "Them is silent although something is playing. Turn Legato on in System Settings > Privacy & Security > System Audio Recording Only."
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
        case .recording: isMuted ? "Recording · muted" : "Recording"
        case .stopping: "Saving meeting…"
        }
    }

    // MARK: Start and stop

    func start() async {
        guard phase == .idle else { return }
        guard startTask == nil else {
            notice = "Still cancelling the last start. Try again in a moment."
            return
        }
        notice = nil
        phase = .starting
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
        phase = .idle
        notice = "Meeting start cancelled."
    }

    private func performStart() async {
        let engines = await services.engines()
        guard !Task.isCancelled else { return }
        guard let systemEngine = engines.system else {
            phase = .idle
            notice = "Meetings need a second engine for system audio, which this Mac setup does not provide."
            return
        }
        engineName = engines.engineID == "apple-speech" ? "Apple Speech" : engines.engineID
        engineFallback = engines.fallbackReason

        let id = UUID()
        let meeting = Meeting(
            id: id, title: Self.defaultTitle(Date()), date: Date(), engineID: engines.engineID)
        let folder: URL
        do { folder = try await store.createFolder(for: id) } catch {
            guard !Task.isCancelled else { return }
            phase = .idle
            notice = "Could not create the meeting folder: \(error.localizedDescription)"
            return
        }
        guard !Task.isCancelled else {
            try? FileManager.default.removeItem(at: folder)
            return
        }
        let mic = VoiceProcessingFallbackMic(voiceProcessing: settings.voiceProcessing)
        let system = SystemAudioSource()
        #if DEBUG
        let counter = ZeroCountingSource(system)
        let tap: any AudioSource = measureTap ? counter : system
        selfTestSource = measureTap ? counter : nil
        #else
        let tap: any AudioSource = system
        #endif
        let session = MeetingSession(
            meeting: meeting,
            inputs: [
                MeetingInput(stream: .mic, source: mic, engine: engines.mic, locale: engines.locale),
                MeetingInput(stream: .system, source: tap, engine: systemEngine, locale: engines.locale),
            ],
            store: store, sink: MeetingAudioWriter(folder: folder),
            convert: { $0 }, // the writer converts to its own 16 kHz mono
            clock: { ProcessInfo.processInfo.systemUptime })
        do {
            try await session.start()
        } catch {
            try? FileManager.default.removeItem(at: folder)
            // A cancelled start already told the user and freed the window.
            guard !(error is CancellationError), !Task.isCancelled else { return }
            Self.log.error("meeting start failed: \(String(describing: type(of: error)), privacy: .public)")
            phase = .idle
            notice = "Could not start the meeting: \(error.localizedDescription)"
            return
        }
        guard !Task.isCancelled else {
            _ = await session.stop()
            try? FileManager.default.removeItem(at: folder)
            return
        }
        beginObserving(session: session, system: system, mic: mic)
        phase = .recording
        windowRequests += 1
    }

    /// Ends the capture. The after-stop chain runs in a task unless `runPipeline` is false (the self-test).
    @discardableResult
    func stop(runPipeline: Bool = true) async -> Meeting? {
        guard phase == .recording, let session else { return nil }
        phase = .stopping
        stopObserving()
        let meeting = await session.stop()
        self.session = nil
        live = nil
        tapStatus = nil
        mute = MeetingMuteState()
        phase = .idle
        await refresh()
        if runPipeline { process(meeting.id) }
        return meeting
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

    private func beginObserving(session: MeetingSession, system: SystemAudioSource, mic: VoiceProcessingFallbackMic) {
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
            for await text in notices { self?.notice = text }
        }
        autoMuteTask = Task { [weak self] in
            for await processes in MicInUseMonitor().processChanges() {
                guard let self else { return }
                lastProcesses = processes
                reevaluateMute()
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

    func delete(_ meeting: Meeting) async {
        guard meeting.state != .recording, !busy.contains(meeting.id) else { return }
        let folder = await store.folder(for: meeting.id)
        try? FileManager.default.trashItem(at: folder, resultingItemURL: nil)
        await refresh()
    }

    func rename(_ meeting: Meeting, to title: String) async {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        _ = try? await store.update(id: meeting.id) { $0.title = trimmed }
        await refresh()
    }

    // MARK: Actions on a meeting

    /// The after-stop chain (or its remainder) for a meeting.
    func process(_ id: UUID) {
        guard !liveMeetingIDs.contains(id) else { return }
        run(id, label: "Processing") { services in
            try await services.pipeline().run(meetingID: id)
        }
    }

    /// "Improve transcript": the post-pass again, then the summary again.
    func improve(_ id: UUID) {
        run(id, label: "Improving the transcript") { services in
            try await services.pipeline().improveTranscript(meetingID: id)
        }
    }

    private func run(
        _ id: UUID, label: String,
        _ work: @escaping @MainActor (MeetingServices) async throws -> MeetingPipeline.Outcome
    ) {
        guard !busy.contains(id) else { return }
        busy.insert(id)
        Task { [weak self] in
            guard let self else { return }
            do {
                let outcome = try await work(services)
                if !outcome.notes.isEmpty { notice = outcome.notes.joined(separator: " ") }
            } catch is CancellationError {
                // The meeting stays `processing` and resumes at the next launch.
            } catch {
                Self.log.error("\(label, privacy: .public) failed: \(String(describing: type(of: error)), privacy: .public)")
                notice = "\(label) failed: \(error.localizedDescription)"
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

    func exportMarkdown(_ meeting: Meeting) async {
        let text = await markdown(for: meeting)
        let panel = NSSavePanel()
        panel.nameFieldStringValue = Self.fileName(meeting.title) + ".md"
        panel.allowedContentTypes = [.plainText]
        NSApp.activate()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try Data(text.utf8).write(to: url, options: .atomic) } catch {
            notice = "Could not save the export: \(error.localizedDescription)"
        }
    }

    func showAudio(_ meeting: Meeting) async {
        let folder = await store.folder(for: meeting.id)
        let audio = ["mic.m4a", "system.m4a", "mic.caf", "system.caf"]
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
    /// throwaway meeting, writes how much both streams heard to the JSON and exits (2 when the capture could
    /// not start, 1 when "them" is empty). The JSON holds counts; the text only with `includeText`. A debug
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

/// The meeting self-test: a real two-stream meeting for N seconds against a temporary store, then a JSON report.
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
            themTapZeroRatio: counter?.zeroRatio, themTapBuffers: counter?.total ?? 0, includeText: includeText)
        write(report)
        return report.themHeardSomething ? 0 : 1
    }

    private func write(_ report: MeetingSelfTestReport) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(report) { try? PrivateFiles.write(data, to: out) }
        NSLog("[meeting-selftest] wrote \(out.path)")
    }
}
#endif
