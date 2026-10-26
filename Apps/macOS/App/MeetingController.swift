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
/// - `start` opens the mic first, then the system-audio tap (the tap excludes our own process, which only
///   exists for Core Audio once the mic has touched it).
/// - `stop` ends the capture and runs the after-stop chain (post-pass, m4a, on-device summary) in a task.
/// - The mic is muted when the user mutes by hand or when `AutoMutePolicy` says the call app closed its mic;
///   manual mute always wins (`AutoMutePolicy` is told, and the effective mute is the OR of the two).
/// - The meeting's mic is a second `AVAudioEngine` input beside push-to-talk dictation's own `MicSource`.
///   Two engines on the same input device are allowed by Core Audio; not driven on a device by the author.
/// - A meeting never touches the dictation session.
@MainActor @Observable
final class MeetingController {
    static let windowID = "meetings"

    private static let log = Logger(subsystem: "de.gruenwald.legato", category: "meetings")
    private static let claudeDisclosureKey = "meeting.claudeDisclosureAccepted"

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
    private(set) var manualMute = false
    private(set) var autoMute = false
    /// Meetings whose after-stop chain or an explicit action is running.
    private(set) var busy: Set<UUID> = []
    /// The latest thing that went wrong or was skipped, for the window.
    private(set) var notice: String?
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
    @ObservationIgnored private var autoMuteTask: Task<Void, Never>?
    @ObservationIgnored private var clockTask: Task<Void, Never>?
    @ObservationIgnored private var muteWriter: Task<Void, Never>?
    @ObservationIgnored private var muteCommands: AsyncStream<Bool>.Continuation?
    @ObservationIgnored private var policy = AutoMutePolicy(ownPID: ProcessInfo.processInfo.processIdentifier)
    @ObservationIgnored private var lastInputPIDs: Set<Int32> = []
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
        services = MeetingServices(models: models, store: store, settings: settings, keyStore: keys)
    }

    // MARK: Derived state

    var isRecording: Bool { phase == .recording || phase == .starting || phase == .stopping }
    var isMuted: Bool { manualMute || autoMute }

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
        notice = nil
        phase = .starting
        let engines = await services.engines()
        guard let systemEngine = engines.system else {
            phase = .idle
            notice = "Meetings need a second engine for system audio, which this Mac setup does not provide."
            return
        }
        engineName = engines.engineID == "apple-speech" ? "Apple Speech" : engines.engineID
        engineFallback = engines.fallbackReason

        let id = UUID()
        let begin = ProcessInfo.processInfo.systemUptime
        let meeting = Meeting(
            id: id, title: Self.defaultTitle(Date()), date: Date(), engineID: engines.engineID)
        let folder = await store.folder(for: id)
        do { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) } catch {
            phase = .idle
            notice = "Could not create the meeting folder: \(error.localizedDescription)"
            return
        }
        let mic = MicSource(voiceProcessing: settings.voiceProcessing)
        let system = SystemAudioSource()
        let counter = ZeroCountingSource(system)
        let tap: any AudioSource = measureTap ? counter : system
        selfTestSource = measureTap ? counter : nil
        let session = MeetingSession(
            meeting: meeting,
            inputs: [
                MeetingInput(stream: .mic, source: mic, engine: engines.mic),
                MeetingInput(stream: .system, source: tap, engine: systemEngine),
            ],
            store: store, sink: MeetingAudioWriter(folder: folder),
            convert: { $0 }, // the writer converts to its own 16 kHz mono
            clock: { ProcessInfo.processInfo.systemUptime - begin })
        do {
            try await session.start()
        } catch {
            Self.log.error("meeting start failed: \(String(describing: type(of: error)), privacy: .public)")
            phase = .idle
            notice = "Could not start the meeting: \(error.localizedDescription)"
            try? FileManager.default.removeItem(at: folder)
            return
        }
        beginObserving(session: session, system: system, startedAt: begin)
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
        manualMute = false
        autoMute = false
        phase = .idle
        await refresh()
        if runPipeline { process(meeting.id) }
        return meeting
    }

    func toggle() async {
        if phase == .recording { await stop() } else { await start() }
    }

    // MARK: Mute

    func toggleManualMute() {
        guard phase == .recording else { return }
        manualMute.toggle()
        reevaluateMute()
    }

    private func reevaluateMute() {
        let wantsAuto = settings.autoMute
            && policy.update(
                systemAudioActive: tapStatus != nil && !isTapFailed, inputPIDs: lastInputPIDs,
                manuallyMuted: manualMute)
        autoMute = wantsAuto
        muteCommands?.yield(manualMute || wantsAuto)
    }

    private var isTapFailed: Bool {
        if case .failed = tapStatus { return true }
        return false
    }

    // MARK: Observing a running meeting

    private func beginObserving(session: MeetingSession, system: SystemAudioSource, startedAt: TimeInterval) {
        self.session = session
        manualMute = false
        autoMute = false
        policy = AutoMutePolicy(ownPID: ProcessInfo.processInfo.processIdentifier)
        lastInputPIDs = []

        snapshotTask = Task { [weak self, snapshots = session.snapshots] in
            for await snapshot in snapshots { self?.live = snapshot }
        }
        tapTask = Task { [weak self, statuses = system.statuses] in
            for await status in statuses {
                self?.tapStatus = status
                self?.reevaluateMute()
            }
        }
        autoMuteTask = Task { [weak self] in
            for await pids in MicInUseMonitor().inputPIDChanges() {
                guard let self else { return }
                lastInputPIDs = pids
                reevaluateMute()
            }
        }
        clockTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.elapsed = ProcessInfo.processInfo.systemUptime - startedAt
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
        _ = try? await MeetingRecovery.run(store: store)
        await refresh()
        for meeting in meetings where meeting.state == .processing || meeting.state == .interrupted {
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
        let folder = await store.folder(for: meeting.id)
        try? FileManager.default.trashItem(at: folder, resultingItemURL: nil)
        await refresh()
    }

    func rename(_ meeting: Meeting, to title: String) async {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, var current = try? await store.meeting(id: meeting.id) else { return }
        current.title = trimmed
        try? await store.update(current)
        await refresh()
    }

    // MARK: Actions on a meeting

    /// The after-stop chain (or its remainder) for a meeting.
    func process(_ id: UUID) {
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
        get { defaults.bool(forKey: Self.claudeDisclosureKey) }
        set { defaults.set(newValue, forKey: Self.claudeDisclosureKey) }
    }

    var hasClaudeKey: Bool { ((try? keyStore.apiKey()) ?? nil)?.isEmpty == false }

    /// Stores the key in the Keychain. The key itself is never logged or kept in an observable property.
    func saveClaudeKey(_ key: String) -> String? {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            if trimmed.isEmpty { try keyStore.deleteKey() } else { try keyStore.save(apiKey: trimmed) }
            return nil
        } catch {
            return "The Keychain refused the key (\((error as NSError).code))."
        }
    }

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
        return MarkdownExporter.markdown(meeting: meeting, segments: segments, summary: summary)
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

    // MARK: Self-test

    /// `--meeting-selftest <seconds> [--meeting-selftest-out=<json>]`: records a throwaway meeting, writes what
    /// both streams heard to the JSON and exits (2 when the capture could not start, 1 when "them" is empty).
    func runSelfTest(seconds: Double, out: URL) async -> Never {
        measureTap = true
        let report = MeetingSelfTest(controller: self, seconds: seconds, out: out)
        exit(await report.run())
    }

    @ObservationIgnored fileprivate var selfTestSource: ZeroCountingSource?
    @ObservationIgnored fileprivate var measureTap = false

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

// MARK: - Self-test

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
@MainActor
private struct MeetingSelfTest {
    struct Report: Codable {
        var seconds: Double
        var engine: String
        var engineFallback: String?
        var tapStatus: String?
        var meText: String
        var themText: String
        var meSegments: Int
        var themSegments: Int
        var themTapZeroRatio: Double?
        var themTapBuffers: Int
        var note: String?
    }

    let controller: MeetingController
    let seconds: Double
    let out: URL

    func run() async -> Int32 {
        try? FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
        await controller.start()
        guard controller.phase == .recording else {
            write(Report(
                seconds: seconds, engine: "", meText: "", themText: "", meSegments: 0, themSegments: 0,
                themTapZeroRatio: nil, themTapBuffers: 0, note: controller.notice ?? "The meeting did not start."))
            return 2
        }
        NSLog("[meeting-selftest] recording for \(seconds) s")
        try? await Task.sleep(for: .seconds(seconds))
        let tapStatus = controller.tapStatus.map { "\($0)" }
        let engine = controller.engineName ?? ""
        let fallback = controller.engineFallback
        let meeting = await controller.stop(runPipeline: false)
        var segments: [MeetingSegment] = []
        if let meeting { segments = await controller.transcript(of: meeting.id) }
        let me = segments.filter { $0.stream == .mic && !$0.echo }
        let them = segments.filter { $0.stream == .system }
        let counter = controller.selfTestSource
        let report = Report(
            seconds: seconds, engine: engine, engineFallback: fallback, tapStatus: tapStatus,
            meText: me.map(\.text).joined(separator: " "), themText: them.map(\.text).joined(separator: " "),
            meSegments: me.count, themSegments: them.count,
            themTapZeroRatio: counter?.zeroRatio, themTapBuffers: counter?.total ?? 0,
            note: them.isEmpty
                ? "them is empty: nothing played, or System Audio Recording is not granted to Legato."
                : nil)
        write(report)
        return them.isEmpty ? 1 : 0
    }

    private func write(_ report: Report) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(report) { try? data.write(to: out, options: .atomic) }
        NSLog("[meeting-selftest] wrote \(out.path)")
    }
}
