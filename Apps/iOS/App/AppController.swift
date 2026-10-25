import AVFAudio
import Foundation
import LegatoAppleSpeech
import LegatoAudio
import LegatoCore
import Observation
import os
import UIKit

/// The app's single composition root: a thin adapter that wires the system ports into LegatoCore's
/// `DictationCoordinator`. All dictation logic lives there; this type adds only app state for the UI,
/// the one history store, and the optional quit-after-stop workaround.
@MainActor @Observable
final class AppController {
    static let shared = AppController()

    private static let log = Logger(subsystem: "de.gruenwald.legato", category: "app")

    /// True from a successful start until the run is over (stopped, aborted or failed).
    private(set) var isDictating = false
    /// The newest history entry's text, for the home screen.
    private(set) var lastTranscript: String?
    private(set) var status = ReadinessStatus()

    @ObservationIgnored let engine = AppleSpeechEngine()
    /// The one history store; views go through the methods below, never construct their own.
    @ObservationIgnored private let history: JSONLHistoryStore
    @ObservationIgnored let pasteboard = PasteboardClient()
    @ObservationIgnored private let readiness = SystemReadiness()
    @ObservationIgnored private let coordinator: DictationCoordinator
    /// Counts finished runs, so `toggle()` can tell an abort that raced with its own start.
    @ObservationIgnored private var idleCount = 0

    private init() {
        // The one writer of history.jsonl. Without the App Group container (misconfigured signing) fall
        // back to the app's own Application Support, so dictation still works, just not shared.
        let directory = AppGroup.containerURL
            ?? URL.applicationSupportDirectory.appending(path: "Legato", directoryHint: .isDirectory)
        if AppGroup.containerURL == nil { Self.log.error("App Group container unavailable; history is app-local") }
        let history = JSONLHistoryStore(fileURL: directory.appending(path: "history.jsonl"))
        let engine = self.engine
        self.history = history
        coordinator = DictationCoordinator(
            activity: ActivityKitClient(),
            clipboard: pasteboard,
            readiness: readiness,
            history: history,
            makeSession: {
                // A fresh session and mic per dictation; the engine is shared (it is re-prepared per run).
                DictationSession(
                    engine: engine,
                    source: MicSource(),
                    sessionControl: AudioSessionController(),
                    history: history,
                    policy: Settings.audioPolicy,
                    linger: .zero)
            })
        coordinator.onIdle = { [weak self] in self?.runDidEnd() }
        installInterruptionObservers()
    }

    // MARK: Dictation

    /// The single entry point: Action Button, Control Center, Live Activity stop and the in-app button.
    func toggle() async -> DictationCoordinator.Outcome {
        let finishedBefore = idleCount
        let outcome = await coordinator.toggle()
        if case .started = outcome, idleCount == finishedBefore { isDictating = true }
        if case .needsOnboarding = outcome { await refreshReadiness() }
        return outcome
    }

    private func runDidEnd() {
        idleCount += 1
        isDictating = false
        Task { await refreshLastTranscript() }
        #if LEGATO_INTERNAL
        quitIfBackgrounded()
        #endif
    }

    #if LEGATO_INTERNAL
    /// The `restartAfterBackgroundStop` workaround (see `Settings`): after a run that ended in the
    /// background, quit so the next intent press is a fresh launch. Absent from App Store builds.
    private func quitIfBackgrounded() {
        guard Settings.restartAfterBackgroundStop, UIApplication.shared.applicationState == .background else { return }
        Task {
            try? await Task.sleep(for: .milliseconds(600))
            // The user may have opened the app in the meantime, or started again.
            if UIApplication.shared.applicationState == .background, !isDictating { exit(0) }
        }
    }
    #endif

    // MARK: Interruptions

    /// Stops a running dictation gracefully (committed text reaches clipboard and history) because the
    /// system took the microphone away. A no-op when idle. If the session is already dead, the
    /// coordinator's stop path falls into its abort path, which salvages the same text.
    private func stopForSystemEvent(_ reason: String) {
        guard isDictating else { return }
        Self.log.info("stopping dictation: \(reason, privacy: .public)")
        Task { _ = await toggle() }
    }

    /// Observers are installed once, from `init` of the singleton. Handlers run on the main queue; only
    /// Sendable values (ints, strings) leave the notification before hopping to the MainActor.
    private func installInterruptionObservers() {
        let center = NotificationCenter.default

        center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            guard raw == AVAudioSession.InterruptionType.began.rawValue else { return }
            Task { @MainActor in self?.stopForSystemEvent("interruption began") }
        }

        center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] note in
            let reason = (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt)
                .flatMap(AVAudioSession.RouteChangeReason.init(rawValue:))
            let previous = (note.userInfo?[AVAudioSessionRouteChangePreviousRouteKey] as? AVAudioSessionRouteDescription)
                .map { Set($0.inputs.map(\.uid)) } ?? []
            let current = Set(AVAudioSession.sharedInstance().currentRoute.inputs.map(\.uid))
            guard InputRoute.shouldStop(
                reasonIsOldDeviceUnavailable: reason == .oldDeviceUnavailable,
                previousInputs: previous,
                currentInputs: current)
            else { return }
            Task { @MainActor in self?.stopForSystemEvent("input lost") }
        }

        center.addObserver(forName: .AVAudioEngineConfigurationChange, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.stopForSystemEvent("engine configuration change") }
        }

        center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.stopForSystemEvent("media services reset") }
        }
    }

    // MARK: State for the UI

    func recentEntries(limit: Int = 100) async -> [DictationEntry] {
        (try? await history.recent(limit: limit)) ?? []
    }

    func deleteEntry(id: UUID) async {
        try? await history.delete(id: id)
        await refreshLastTranscript()
    }

    func copy(_ text: String) {
        pasteboard.forceWrite(text)
    }

    func refreshReadiness() async {
        status = await readiness.snapshot()
    }

    func refreshLastTranscript() async {
        lastTranscript = (try? await history.recent(limit: 1))?.first?.text
    }

    /// `legato://copy-last`: the tapToCopy activity opened the app; copy the newest transcript.
    func handle(_ url: URL) async {
        guard url == DictationAttributes.copyLastURL else { return }
        guard let text = (try? await history.recent(limit: 1))?.first?.text else { return }
        pasteboard.forceWrite(text)
        lastTranscript = text
    }
}

/// The "should this route change stop dictation?" decision, pure so it can be reasoned about.
/// Input is pinned to the built-in mic, so output-only changes (headphones out) never stop; only losing
/// the input does.
enum InputRoute {
    /// - Parameters:
    ///   - reasonIsOldDeviceUnavailable: the change reason is `.oldDeviceUnavailable`.
    ///   - previousInputs: port UIDs of the route's inputs before the change.
    ///   - currentInputs: port UIDs of the route's inputs now.
    /// - Returns: true when no input is available, or a device went away that had been an input.
    static func shouldStop(
        reasonIsOldDeviceUnavailable: Bool, previousInputs: Set<String>, currentInputs: Set<String>
    ) -> Bool {
        if currentInputs.isEmpty { return true }
        return reasonIsOldDeviceUnavailable && !previousInputs.isEmpty && !previousInputs.isSubset(of: currentInputs)
    }
}
