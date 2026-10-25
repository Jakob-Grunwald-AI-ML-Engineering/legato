import AVFAudio
import Foundation
import LegatoAppleSpeech
import LegatoAudio
import LegatoCore
import Observation
import os

/// The app's single composition root: a thin adapter that wires the system ports into LegatoCore's
/// `DictationCoordinator`. All dictation logic lives there; this type adds only app state for the UI,
/// and the one history store.
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
    @ObservationIgnored private let startEnvironment: SystemStartEnvironment
    @ObservationIgnored private let coordinator: DictationCoordinator
    /// Counts finished runs, so `toggle()` can tell an abort that raced with its own start.
    @ObservationIgnored private var idleCount = 0
    #if LEGATO_INTERNAL
    /// One instance for the process: it remembers whether a session is being held between runs.
    @ObservationIgnored private let sessionControl: AppSessionControl
    #endif

    private init() {
        // The one writer of history.jsonl. Without the App Group container (misconfigured signing) fall
        // back to the app's own Application Support, so dictation still works, just not shared.
        let directory = AppGroup.containerURL
            ?? URL.applicationSupportDirectory.appending(path: "Legato", directoryHint: .isDirectory)
        if AppGroup.containerURL == nil { Self.log.error("App Group container unavailable; history is app-local") }
        let history = JSONLHistoryStore(fileURL: directory.appending(path: "history.jsonl"))
        let engine = self.engine
        self.history = history
        #if LEGATO_INTERNAL
        let sessionControl = AppSessionControl()
        self.sessionControl = sessionControl
        let startEnvironment = SystemStartEnvironment(isSessionHeld: { sessionControl.isHeld })
        #else
        let startEnvironment = SystemStartEnvironment()
        #endif
        self.startEnvironment = startEnvironment
        coordinator = DictationCoordinator(
            activity: ActivityKitClient(),
            clipboard: pasteboard,
            readiness: readiness,
            startEnvironment: startEnvironment,
            history: history,
            makeSession: {
                #if DEBUG
                if let fake = E2E.makeFakeSession(history: history, policy: Settings.audioPolicy) { return fake }
                #endif
                // A fresh session and mic per dictation; the engine is shared (it is re-prepared per run).
                #if LEGATO_INTERNAL
                let source = MicSource(onAttempt: AudioDiagnostics.micAttempt, onFirstBuffer: AudioDiagnostics.micFirstBuffer)
                #else
                let source = MicSource()
                let sessionControl = AudioSessionController()
                #endif
                return DictationSession(
                    engine: engine,
                    source: source,
                    sessionControl: sessionControl,
                    history: history,
                    policy: Settings.audioPolicy,
                    linger: .zero)
            })
        coordinator.onIdle = { [weak self] in self?.runDidEnd() }
        installInterruptionObservers()
        #if LEGATO_INTERNAL
        AudioDiagnostics.install()
        #endif
        #if DEBUG
        E2E.applyLaunchSettings()
        #endif
    }

    // MARK: Dictation

    /// The single entry point: Action Button, Control Center, Live Activity stop and the in-app button.
    ///
    /// `afterForegroundHop`: this press repeats one that returned `.needsForeground(reason)` and the
    /// system has since brought the app to the foreground, so the start is a foreground start.
    func toggle(afterForegroundHop reason: ForegroundReason? = nil) async -> DictationCoordinator.Outcome {
        let finishedBefore = idleCount
        #if LEGATO_INTERNAL
        AudioDiagnostics.log("toggle.begin", ["isDictating": isDictating])
        #endif
        startEnvironment.assumeForeground = reason != nil
        defer { startEnvironment.assumeForeground = false }
        let outcome = await coordinator.toggle()
        await didFinish(outcome, hopReason: reason, finishedBefore: finishedBefore)
        return outcome
    }

    /// Ends a running dictation (or cancels a start in progress) and does nothing otherwise; never
    /// starts one. For system events only: a late event must not begin a new run. Nil when there was
    /// nothing to stop.
    @discardableResult
    func stopIfRunning() async -> DictationCoordinator.Outcome? {
        let finishedBefore = idleCount
        guard let outcome = await coordinator.stopIfRunning() else { return nil }
        await didFinish(outcome, finishedBefore: finishedBefore)
        return outcome
    }

    private func didFinish(
        _ outcome: DictationCoordinator.Outcome, hopReason: ForegroundReason? = nil, finishedBefore: Int
    ) async {
        #if LEGATO_INTERNAL
        AudioDiagnostics.log("toggle.end", ["outcome": Self.outcomeKind(outcome)])
        #endif
        if case .started = outcome, idleCount == finishedBefore { isDictating = true }
        if case .needsOnboarding = outcome { await refreshReadiness() }
        #if DEBUG || LEGATO_INTERNAL
        logStartRoute(outcome, hopReason: hopReason)
        #endif
        #if DEBUG
        E2E.log("outcome \(Self.describe(outcome))")
        #endif
    }

    #if LEGATO_INTERNAL
    private static func outcomeKind(_ outcome: DictationCoordinator.Outcome) -> String {
        switch outcome {
        case .started: "started"
        case .stopped(let text): text == nil ? "stopped(nil)" : "stopped"
        case .needsOnboarding(let issue): "needsOnboarding(\(issue))"
        case .needsForeground(let reason): "needsForeground(\(reason.rawValue))"
        case .failed(let error): "failed(\(error))"
        case .busy: "busy"
        }
    }
    #endif

    #if DEBUG
    private static func describe(_ outcome: DictationCoordinator.Outcome) -> String {
        switch outcome {
        case .started: "kind=started"
        case .stopped(let text): "kind=stopped text=\(text.map(E2E.quote) ?? "nil")"
        case .needsOnboarding(let issue): "kind=needsOnboarding issue=\(issue)"
        case .needsForeground(let reason): "kind=needsForeground reason=\(reason.rawValue)"
        case .failed(let error): "kind=failed error=\(E2E.quote(error))"
        case .busy: "kind=busy"
        }
    }
    #endif

    #if DEBUG || LEGATO_INTERNAL
    /// `start.route`: how a start was routed (plus whether other audio played, as evidence). `foregroundHop`
    /// (with the reason) when the start was handed to the foreground or ran after the hop, `background` / `foreground` when it ran where
    /// the press arrived. Logged for the decision (`needsForeground`) and for the start that ran.
    /// Diagnostics only: internal and Debug builds.
    private func logStartRoute(_ outcome: DictationCoordinator.Outcome, hopReason: ForegroundReason?) {
        let route: String, reason: ForegroundReason?
        switch outcome {
        case .needsForeground(let why): (route, reason) = ("foregroundHop", why)
        case .started, .failed:
            if let hopReason { (route, reason) = ("foregroundHop", hopReason) }
            else { (route, reason) = (startEnvironment.lastContext.inBackground ? "background" : "foreground", nil) }
        default: return
        }
        let result: String
        switch outcome {
        case .started: result = "started"
        case .needsForeground: result = "needsForeground"
        default: result = "failed"
        }
        #if LEGATO_INTERNAL
        AudioDiagnostics.startRoute(
            route, reason: reason?.rawValue, outcome: result, otherAudio: startEnvironment.lastContext.otherAudioPlaying)
        #endif
        #if DEBUG
        E2E.log("start.route route=\(route) reason=\(reason?.rawValue ?? "none") outcome=\(result) otherAudio=\(startEnvironment.lastContext.otherAudioPlaying)")
        #endif
    }
    #endif

    private func runDidEnd() {
        idleCount += 1
        isDictating = false
        Task { await refreshLastTranscript() }
    }

    // MARK: Interruptions

    /// Stops a running dictation gracefully (committed text reaches clipboard and history) because the
    /// system took the microphone away. Goes through `stopIfRunning`, never `toggle`: our own
    /// deactivation at the end of a stop raises a route change with no inputs, and that late event must
    /// not start a new dictation. If the session is already dead, the coordinator's stop path falls into
    /// its abort path, which salvages the same text.
    ///
    /// `releasesHeldSession`: also deactivate an audio session that the "keep session active" debug
    /// switch is holding between runs (interruption, media reset).
    private func stopForSystemEvent(_ reason: String, releasesHeldSession: Bool = false) {
        #if LEGATO_INTERNAL
        if releasesHeldSession || isDictating { sessionControl.release(reason: reason) }
        #endif
        Task {
            #if DEBUG
            E2E.log("system-event reason=\(E2E.quote(reason))")
            #endif
            if await stopIfRunning() != nil {
                Self.log.info("stopped dictation: \(reason, privacy: .public)")
                #if DEBUG
                E2E.log("system-stop reason=\(E2E.quote(reason))")
                #endif
            }
        }
    }

    /// Observers are installed once, from `init` of the singleton. Handlers run on the main queue; only
    /// Sendable values (ints, strings) leave the notification before hopping to the MainActor.
    private func installInterruptionObservers() {
        let center = NotificationCenter.default

        center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            guard raw == AVAudioSession.InterruptionType.began.rawValue else { return }
            Task { @MainActor in self?.stopForSystemEvent("interruption began", releasesHeldSession: true) }
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
            Task { @MainActor in self?.stopForSystemEvent("media services reset", releasesHeldSession: true) }
        }
    }

    /// The "keep session active" debug switch went off: end a session that was being held.
    func releaseHeldSession() {
        #if LEGATO_INTERNAL
        sessionControl.releaseIfHeld()
        #endif
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
        #if DEBUG
        if await handleE2E(url) { return }
        #endif
        guard url == DictationAttributes.copyLastURL else { return }
        guard let text = (try? await history.recent(limit: 1))?.first?.text else { return }
        pasteboard.forceWrite(text, source: "copy-last")
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
