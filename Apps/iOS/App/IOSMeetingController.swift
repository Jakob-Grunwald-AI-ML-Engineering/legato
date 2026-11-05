import ActivityKit
import AVFAudio
import Foundation
import LegatoAppServices
import LegatoAudio
import LegatoClaude
import LegatoCore
import LegatoMeetings
import LegatoSoniox
import Observation
import UIKit

/// iPhone presentation and audio-session admission. MeetingServices owns durable recording and processing.
@MainActor @Observable
final class IOSMeetingController {
    enum Phase { case idle, starting, recording, stopping }
    let services: MeetingServices
    let fixtureMode: Bool
    private(set) var phase = Phase.idle
    private(set) var meetings: [Meeting] = []
    private(set) var live: MeetingSnapshot?
    private(set) var elapsed: TimeInterval = 0
    private(set) var ready = false
    var notice: String?
    var query = ""
    private(set) var searchHits: Set<UUID>?
    private(set) var revision = 0
    var selectedID: UUID?
    var openRequests = 0
    private let keyboard: KeyboardSession
    private let composer: ComposerSession
    private let publishReservation: (Bool) -> Void
    @ObservationIgnored private var input: AutomaticInputSource?
    @ObservationIgnored private var lastInputDiagnostics: AutomaticInputDiagnostics?
    @ObservationIgnored private var snapshots: Task<Void, Never>?
    @ObservationIgnored private var ticker: Task<Void, Never>?
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var startTask: Task<Void, Never>?
    @ObservationIgnored private var stopRequested = false
    @ObservationIgnored private var interruptedStart = false
    @ObservationIgnored private var audioWasActivated = false
    @ObservationIgnored private var activityID: String?
    @ObservationIgnored private var interruptionObserver: NSObjectProtocol?
    @ObservationIgnored private var backgroundTasks: [UUID: UIBackgroundTaskIdentifier] = [:]

    init(root: URL, vocabularyURL: URL?, keyboard: KeyboardSession, composer: ComposerSession,
         publishReservation: @escaping (Bool) -> Void) {
        self.keyboard = keyboard; self.composer = composer; self.publishReservation = publishReservation
        #if LEGATO_INTERNAL
        let fixture = IOSMeetingFixture.current
        fixtureMode = fixture != nil
        if let fixture {
            services = fixture.services
        } else {
            services = Self.production(root: root, vocabularyURL: vocabularyURL)
        }
        #else
        fixtureMode = false
        services = Self.production(root: root, vocabularyURL: vocabularyURL)
        #endif
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  raw == AVAudioSession.InterruptionType.began.rawValue else { return }
            Task { @MainActor in
                guard let self, self.isActive else { return }
                self.interruptedStart = true
                await self.stop(interrupted: true)
            }
        }
        Task {
            // Dismiss stale activities from a process that died. Their Stop intent cannot restart capture.
            for stale in Activity<MeetingAttributes>.activities { await stale.end(nil, dismissalPolicy: .immediate) }
            await services.recover()
            await refresh()
            ready = true
        }
    }

    private static func production(root: URL, vocabularyURL: URL?) -> MeetingServices {
        MeetingServices(store: MeetingStore(root: root), settings: MeetingSettings(defaults: AppGroup.defaults),
            sonioxKey: { (try? KeychainKeyStore(service: "de.gruenwald.legato.soniox").apiKey()) ?? "" },
            claudeKeys: KeychainKeyStore(), vocabularyURL: vocabularyURL)
    }
    var isActive: Bool { phase != .idle || services.isRecording }
    var shown: [Meeting] { meetings.filter { searchHits?.contains($0.id) ?? true } }
    var liveText: String { live?.volatile[.mixed] ?? "" }
    var warning: String? {
        if let error = live?.audioError { return "Microphone stopped: \(error)" }
        if let error = live?.saveError { return "Could not save: \(error)" }
        if live?.engineErrors.isEmpty == false { return "Transcription is offline. Audio is still being saved." }
        return nil
    }

    func start() {
        guard !VoiceEnrollmentController.shared.isBusy else {
            notice = "Finish or cancel voice profile setup first."; return
        }
        guard ready, phase == .idle, UIApplication.shared.applicationState == .active else { return }
        guard !composer.isListening, composer.status != "starting", keyboard.route == .idle else {
            notice = "Stop dictation before starting a meeting. Your draft will be kept."; return
        }
        phase = .starting; notice = nil; stopRequested = false; interruptedStart = false
        // Reserve synchronously before any await: keyboard requests cannot slip into the handoff.
        composer.microphoneReserved = true
        publishReservation(true)
        startTask = Task {
            await keyboard.suspendForMeeting()
            do {
                try Task.checkCancellation()
                guard !stopRequested else { throw CancellationError() }
                // ActivityKit must precede AVAudioSession activation. Its availability is optional.
                if ActivityAuthorizationInfo().areActivitiesEnabled {
                    activityID = (try? Activity.request(attributes: MeetingAttributes(startedAt: Date()),
                        content: ActivityContent(state: .init(phase: .starting, tail: ""), staleDate: nil)))?.id
                }
                var mic: any AudioSource = AutomaticInputSource()
                var needsAudio = true
                #if LEGATO_INTERNAL
                if let fixture = IOSMeetingFixture.current { mic = fixture.microphone(); needsAudio = fixture.realMicrophone }
                #endif
                if needsAudio {
                    guard await AVAudioApplication.requestRecordPermission() else {
                        throw NSError(domain: "Meeting", code: 1, userInfo: [NSLocalizedDescriptionKey: "Allow microphone access in iOS Settings to record a meeting."])
                    }
                    try await foregroundAfterPermission()
                    let audio = AVAudioSession.sharedInstance()
                    try audio.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothHFP])
                    try audio.setActive(true)
                    audioWasActivated = true
                }
                guard !stopRequested else { throw CancellationError() }
                input = mic as? AutomaticInputSource
                lastInputDiagnostics = nil
                let session = try await services.startMeeting(mic: mic)
                selectedID = session.meetingID
                if stopRequested {
                    phase = .recording
                    await stop(interrupted: interruptedStart)
                    return
                }
                phase = .recording
                elapsed = 0; live = nil
                snapshots = Task {
                    for await snapshot in session.snapshots {
                        live = snapshot
                        await updateActivity(.recording)
                        if snapshot.audioError != nil { await stop(interrupted: true); break }
                    }
                }
                ticker = Task {
                    while !Task.isCancelled {
                        elapsed = session.elapsed
                        try? await Task.sleep(for: .seconds(1))
                    }
                }
                await updateActivity(.recording)
                await refresh()
            } catch {
                await finishCapture(interrupted: interruptedStart)
                if !(error is CancellationError) { notice = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription }
            }
            startTask = nil
        }
    }

    /// The system permission alert can return before UIKit has finished reactivating the app.
    /// Wait only for that transition; backgrounding and explicit Stop always cancel admission.
    private func foregroundAfterPermission() async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while UIApplication.shared.applicationState == .inactive, ContinuousClock.now < deadline {
            try Task.checkCancellation()
            guard !stopRequested else { throw CancellationError() }
            try await Task.sleep(for: .milliseconds(50))
        }
        guard !stopRequested, UIApplication.shared.applicationState != .background else { throw CancellationError() }
        guard UIApplication.shared.applicationState == .active else {
            throw NSError(domain: "Meeting", code: 2, userInfo: [NSLocalizedDescriptionKey: "Return to Legato and tap Record again. Recording has not started."])
        }
    }

    /// Stops only. A stop during permission/start wins once that operation returns.
    func stop(interrupted: Bool = false) async {
        guard phase != .idle else { return }
        stopRequested = true
        interruptedStart = interruptedStart || interrupted
        if phase == .starting { return }
        guard phase == .recording else { return }
        phase = .stopping
        let backgroundID = beginBackgroundTime()
        snapshots?.cancel(); snapshots = nil
        ticker?.cancel(); ticker = nil
        await updateActivity(interrupted ? .interrupted : .stopping)
        lastInputDiagnostics = input?.diagnostics
        let meeting = await services.stopMeeting()
        if interrupted, let id = meeting?.id {
            _ = try? await services.store.update(id: id) { $0.state = .interrupted }
            notice = "Meeting interrupted. Recording has stopped; the audio and transcript captured so far are saved. Start a new meeting when ready."
        }
        await finishCapture(interrupted: interrupted)
        await refresh()
        if let id = meeting?.id { await services.waitForProcessing(id); await refresh() }
        endBackgroundTime(backgroundID)
    }

    private func finishCapture(interrupted: Bool) async {
        if let activityID {
            await Self.endActivity(id: activityID, content: ActivityContent(state: .init(phase: interrupted ? .interrupted : .stopping, tail: interrupted ? "Recording stopped. Open Legato to continue." : "Meeting saved"), staleDate: nil),
                dismissalPolicy: interrupted ? .after(Date().addingTimeInterval(300)) : .immediate)
        }
        activityID = nil
        if audioWasActivated { try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation) }
        audioWasActivated = false
        input = nil
        live = nil; phase = .idle
        keyboard.finishMeeting()
        publishReservation(false)
    }
    private func updateActivity(_ phase: MeetingAttributes.ContentState.Phase) async {
        guard let activityID else { return }
        await Self.updateActivity(id: activityID, content: ActivityContent(state: .init(phase: phase, tail: String((liveText.isEmpty ? live?.segments.last?.text ?? "" : liveText).suffix(240))), staleDate: nil))
    }
    private nonisolated static func updateActivity(id: String, content: ActivityContent<MeetingAttributes.ContentState>) async {
        guard let activity = Activity<MeetingAttributes>.activities.first(where: { $0.id == id }) else { return }
        await activity.update(content)
    }
    private nonisolated static func endActivity(id: String, content: ActivityContent<MeetingAttributes.ContentState>, dismissalPolicy: ActivityUIDismissalPolicy) async {
        guard let activity = Activity<MeetingAttributes>.activities.first(where: { $0.id == id }) else { return }
        await activity.end(content, dismissalPolicy: dismissalPolicy)
    }
    private func beginBackgroundTime() -> UUID {
        let id = UUID()
        let task = UIApplication.shared.beginBackgroundTask(withName: "Save meeting") { [weak self] in
            Task { @MainActor in
                self?.notice = "Processing will continue when Legato is opened again. Recorded files are kept."
                self?.endBackgroundTime(id)
            }
        }
        backgroundTasks[id] = task
        return id
    }
    private func endBackgroundTime(_ id: UUID) {
        if let task = backgroundTasks.removeValue(forKey: id), task != .invalid { UIApplication.shared.endBackgroundTask(task) }
    }
    func refresh() async {
        do { meetings = try await services.meetings(); revision += 1; search() }
        catch { notice = "Could not load meetings: \(error.localizedDescription)" }
    }
    func search() {
        searchTask?.cancel()
        let words = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty else { searchHits = nil; return }
        let candidates = meetings
        searchTask = Task {
            var hits = Set<UUID>()
            for meeting in candidates {
                guard !Task.isCancelled else { return }
                if await services.store.matches(words, meeting: meeting) { hits.insert(meeting.id) }
            }
            guard !Task.isCancelled else { return }
            searchHits = hits
        }
    }
    func summarize(_ id: UUID) async {
        do { _ = try await services.summarize(meetingID: id) }
        catch { notice = "Summary could not finish: \(error.localizedDescription)" }
        await refresh()
    }

    #if LEGATO_INTERNAL
    func diagnostics() async -> [String: Any] {
        var value: [String: Any] = ["phase": String(describing: phase), "appState": UIApplication.shared.applicationState.rawValue,
            "fixture": fixtureMode, "elapsed": elapsed, "activeMeetingID": (services.activeMeetingID?.uuidString as Any?) ?? NSNull(),
            "microphoneReserved": composer.microphoneReserved, "keyboardSuspended": keyboard.meetingSuspended,
            "activityState": activityID.flatMap { id in Activity<MeetingAttributes>.activities.first(where: { $0.id == id }).map { String(describing: $0.activityState) } } ?? "none"]
        if let diagnostics = input?.diagnostics ?? lastInputDiagnostics,
           let data = try? JSONEncoder().encode(diagnostics) {
            value["microphone"] = try? JSONSerialization.jsonObject(with: data)
        }
        let saved = (try? await services.meetings()) ?? []
        value["meetings"] = await saved.asyncDiagnosticRecords(store: services.store)
        return value
    }
    #endif

    func open() { openRequests += 1; selectedID = services.activeMeetingID ?? selectedID }
}

#if LEGATO_INTERNAL
private extension Array where Element == Meeting {
    func asyncDiagnosticRecords(store: MeetingStore) async -> [[String: Any]] {
        var records: [[String: Any]] = []
        for meeting in self {
            let folder = await store.folder(for: meeting.id)
            var record: [String: Any] = ["id": meeting.id.uuidString, "title": meeting.title, "state": meeting.state.rawValue,
                "duration": meeting.duration, "folder": folder.path, "steps": meeting.completedSteps.map(\.rawValue)]
            if let url = MeetingPlayer.audioURL(in: folder), let file = try? AVAudioFile(forReading: url) {
                record["audioDuration"] = Double(file.length) / file.processingFormat.sampleRate
                record["audioFrames"] = file.length
                record["audioFile"] = url.lastPathComponent
            }
            record["segments"] = ((try? await store.segments(for: meeting.id)) ?? []).count
            records.append(record)
        }
        return records
    }
}
#endif
