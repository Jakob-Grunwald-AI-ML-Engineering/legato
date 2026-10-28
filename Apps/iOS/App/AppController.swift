#if ANE_CLEANUP_SPIKE
import ANECleanupCore
#endif
import AVFAudio
import Foundation
import LegatoAppServices
import LegatoAppleSpeech
import LegatoAudio
import LegatoCore
import LegatoEngines
import LegatoKeyboardCore
import LegatoPostProcessing
import Observation
import os
import UIKit

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
    /// The hop screen is up: the keyboard sent the user here to dictate.
    private(set) var showsKeyboardHop = false
    /// The current run's text, committed plus tentative, for the hop screen.
    private(set) var liveText = ""
    /// A keyboard run is in progress (the hop screen shows Stop).
    private(set) var keyboardRunActive = false
    /// The microphone is armed (a lease is held) and the hop screen says to go back; nil when it is not.
    private(set) var micReadyUntil: Date?
    /// The keyboard's arm failed (readiness, a refused activation): what the hop screen tells the user.
    private(set) var armFailure: String?

    /// Apple Speech, for onboarding's asset download (dictation uses `engineBox`, which is Apple Speech by default).
    @ObservationIgnored let appleSpeech: AppleSpeechEngine
    /// The personal vocabulary: hints the engines and the cleanup step, and learns from dictations.
    @ObservationIgnored let vocabulary: VocabularyService
    /// The model catalog, the engine and the cleanup registries.
    @ObservationIgnored let models: ModelServices
    /// The live engine every new session gets: resolved from the pick at launch and after every change of
    /// the pick or the engine settings (`refreshEngine`).
    @ObservationIgnored private let engineBox: EngineBox
    /// Which engine new dictations use, and why Apple Speech when a pick could not be used.
    private(set) var engineStatus = EngineStatus()
    /// What the last cleanup (or refine) did.
    let cleanupReports = CleanupReports()
    /// Meetings: recording, the after-stop chain and the library. While one records, dictation is blocked.
    let meetings: MeetingController
    /// The one history store; views go through the methods below, never construct their own.
    @ObservationIgnored private let history: any HistoryStore
    @ObservationIgnored let pasteboard = PasteboardClient()
    @ObservationIgnored private let readiness = SystemReadiness()
    @ObservationIgnored private let startEnvironment: SystemStartEnvironment
    @ObservationIgnored private let coordinator: DictationCoordinator
    @ObservationIgnored private let activityClient: ActivityKitClient
    /// The finished dictation the Live Activity's Insert and Copy buttons act on, until one resolves it,
    /// a new run starts or `DictationResult.lifetime` ends.
    @ObservationIgnored private var pendingResult: DictationResult?
    @ObservationIgnored private var resultExpiry: Task<Void, Never>?
    /// The link to the keyboard extension; nil without the App Group.
    @ObservationIgnored private let keyboardLink: KeyboardLinkHost?
    /// Counts finished runs, so `toggle()` can tell an abort that raced with its own start.
    @ObservationIgnored private var idleCount = 0
    /// The options of a press whose start was handed to the foreground (`.needsForeground`). The press
    /// that repeats it after the hop runs with these, not with a fresh decision: the app is in front by
    /// then, so the keyboard no longer looks visible and the run would silently lose its target.
    @ObservationIgnored private var hopOptions: StartOptions?
    @ObservationIgnored private let modelAdmission = ModelAdmission()
    @ObservationIgnored private var modelRevision = 0
    @ObservationIgnored private var engineRevision = 0
    @ObservationIgnored private var resolvingEngine = false
    @ObservationIgnored private var resourcePreparation: Task<Void, Never>?
    private enum PreparationError: Error { case needsForeground }
    #if LEGATO_INTERNAL
    /// One instance for the process: it remembers whether a session is being held between runs.
    @ObservationIgnored private let sessionControl: KeepActiveSessionControl
    #endif

    #if ANE_CLEANUP_SPIKE
    @ObservationIgnored private let spike: SpikeComposition
    @ObservationIgnored private var spikeMemoryObserver: NSObjectProtocol?
    #endif

    private init() {
        #if ANE_CLEANUP_SPIKE
        ParityBootstrap.apply(defaults: AppGroup.defaults)
        #endif
        Settings.migrateKeepAliveChoices() // before anything reads the setting
        // The one writer of history.jsonl. Without the App Group container (misconfigured signing) fall
        // back to the app's own Application Support, so dictation still works, just not shared.
        let directory = AppGroup.containerURL
            ?? URL.applicationSupportDirectory.appending(path: "Legato", directoryHint: .isDirectory)
        if AppGroup.containerURL == nil { Self.log.error("App Group container unavailable; history is app-local") }
        // The vocabulary comes before ModelServices: the engines it builds ask it for hints.
        // The languages are read on every use, so a change of the dictation languages applies at once.
        let languageSettings = EngineSettings(defaults: AppGroup.defaults)
        let vocabulary = VocabularyService(
            fileURL: directory.appending(path: "vocabulary.json"),
            languages: { VocabularyService.configuredLanguages(languageSettings) },
            pairsFileURL: directory.appending(path: "wordpairs-dictated.json"))
        self.vocabulary = vocabulary
        let history: any HistoryStore = LearningHistoryStore(
            JSONLHistoryStore(fileURL: directory.appending(path: "history.jsonl")), vocabulary: vocabulary)
        vocabulary.backfillPairsIfNeeded(history: history) // once; a background task behind the learning queue
        let models = ModelServices(root: ModelServices.phoneModelsRoot, defaults: AppGroup.defaults, vocabulary: vocabulary)
        self.models = models
        appleSpeech = AppleSpeechEngine(vocabulary: vocabulary)
        let engineBox = EngineBox(AppleSpeechEngine(vocabulary: vocabulary))
        self.engineBox = engineBox
        let reports = cleanupReports
        let engineSettings = models.engineSettings
        #if ANE_CLEANUP_SPIKE
        let spike = SpikeComposition(defaults: AppGroup.defaults, vocabulary: vocabulary,
            preferredLocale: { ModelServices.singleLocale(engineSettings) },
            report: { report in await reports.record(report) })
        self.spike = spike
        let cleanup = spike.processor
        #else
        let cleanup = CleanupProcessor(
            registry: models.cleanup, settings: Settings.cleanupStore,
            preferredLocale: { ModelServices.singleLocale(engineSettings) },
            vocabulary: vocabulary,
            acquireRun: { try await models.acquireDictationCleanup(options: Settings.cleanupStore.options, inBackground: true) },
            report: { report in await reports.record(report) })
        #endif
        self.history = history
        let meetingRoot = directory.appending(path: "Meetings", directoryHint: .isDirectory)
        #if DEBUG
        meetings = MeetingController(
            models: models, root: meetingRoot, defaults: AppGroup.defaults,
            audio: E2E.fakeEngine != nil ? E2E.meetingAudio : .live)
        meetings.engineOverride = E2E.fakeEngine
        #else
        meetings = MeetingController(models: models, root: meetingRoot, defaults: AppGroup.defaults)
        #endif
        #if LEGATO_INTERNAL
        let sessionControl = KeepActiveSessionControl.app()
        self.sessionControl = sessionControl
        let startEnvironment = SystemStartEnvironment(isSessionHeld: { sessionControl.isHeld })
        #else
        let startEnvironment = SystemStartEnvironment()
        #endif
        self.startEnvironment = startEnvironment
        let keyboardLink = KeyboardLinkHost()
        self.keyboardLink = keyboardLink
        let activityClient = ActivityKitClient()
        self.activityClient = activityClient
        coordinator = DictationCoordinator(
            activity: activityClient,
            clipboard: pasteboard,
            readiness: readiness,
            startEnvironment: startEnvironment,
            history: history,
            makeSession: { policy, linger in
                #if DEBUG
                if let fake = E2E.makeFakeSession(history: history, postProcessor: cleanup, policy: policy, linger: linger) {
                    return fake
                }
                #endif
                // A fresh session and mic per dictation; the engine is shared (it is re-prepared per run).
                #if LEGATO_INTERNAL
                let source = MicSource(onAttempt: AudioDiagnostics.micAttempt, onFirstBuffer: AudioDiagnostics.micFirstBuffer)
                #else
                let source = MicSource()
                let sessionControl = AudioSessionController()
                #endif
                return DictationSession(
                    engine: engineBox.engine,
                    source: source,
                    sessionControl: sessionControl,
                    history: history,
                    postProcessor: cleanup,
                    policy: policy,
                    linger: linger)
            })
        coordinator.onIdle = { [weak self] in self?.runDidEnd() }
        coordinator.onResult = { [weak self] result in self?.resultReady(result) }
        coordinator.onStartFallback = { from, to, error in
            let label = SystemStartEnvironment.refusalLabel(error)
            Self.log.info("start fallback \(from.rawValue, privacy: .public) -> \(to.rawValue, privacy: .public): \(label, privacy: .public)")
            #if LEGATO_INTERNAL
            AudioDiagnostics.startFallback(from: from.rawValue, to: to.rawValue, error: error, label: label)
            #endif
            #if DEBUG
            E2E.log("start.fallback from=\(from.rawValue) to=\(to.rawValue) error=\(label)")
            #endif
        }
        if let keyboardLink {
            coordinator.sink = keyboardLink
            keyboardLink.onTranscript = { [weak self] committed, volatile in self?.liveText = committed + volatile }
            keyboardLink.onRunActivity = { [weak self] active in
                self?.keyboardRunActive = active
                if active { self?.clearResult() } // a new run's activity replaces the result's
            }
            keyboardLink.onLease = { [weak self] until in
                self?.micReadyUntil = until
                #if ANE_CLEANUP_SPIKE
                self?.spike.record("microphone.lease", ["held": String(until != nil)])
                #endif
            }
            #if ANE_CLEANUP_SPIKE
            keyboardLink.onRunStarted = { [weak self] runID in self?.spike.runStarted(runID) }
            keyboardLink.onDelivery = { [weak self] runID, applied in
                self?.spike.record("keyboard.finalApplied", ["runID": runID, "confirmed": String(applied)])
            }
            #endif
            keyboardLink.link.onRequest = { [weak self] request in await self?.perform(request.command) ?? false }
            keyboardLink.link.onRefine = { [weak self] text in await self?.refine(text) }
            keyboardLink.deliveryForRun = { Settings.hostDelivery }
            // The keyboard's field was cleared mid-run (a chat app sent it): later cleanup covers only what follows.
            keyboardLink.link.onSent = { [weak self] runID, boundary, shownRevision in
                self?.coordinator.liveTextSent(runID: runID, upTo: boundary, shownRevision: shownRevision)
            }
            // The keyboard's tapped alternatives teach the vocabulary: on its note and when listening starts.
            keyboardLink.onChoices = { [vocabulary] records in
                for record in records {
                    vocabulary.recordChoice(
                        original: record.original, chosen: record.chosen, fromVocabulary: record.fromVocabulary)
                }
            }
            keyboardLink.startListening()
        }
        meetings.isInBackground = { [weak self] in self?.startEnvironment.current().inBackground ?? false }
        meetings.dictationActive = { [weak self] in
            guard let self else { return false }
            #if ANE_CLEANUP_SPIKE
            return !coordinator.isIdle || isDictating || keyboardRunActive || spike.admission.isPreparing || resolvingEngine
            #else
            return !coordinator.isIdle || isDictating || keyboardRunActive || modelAdmission.isPreparing || resolvingEngine
            #endif
        }
        meetings.releaseKeptMicrophone = { [weak self] in await self?.endKeepAlive() }
        meetings.onActiveChanged = { [weak self] active in self?.keyboardLink?.link.meetingChanged(active: active) }
        #if ANE_CLEANUP_SPIKE
        spikeMemoryObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.readiness.selectedResourcesReady = false
                await self.spike.reset { await self.coordinator.invalidateKeptSession() }
            }
        }
        #endif
        installInterruptionObservers()
        #if LEGATO_INTERNAL
        AudioDiagnostics.install()
        #endif
        #if DEBUG
        E2E.applyLaunchSettings()
        #endif
        Task { await refreshEngine(releasingKeptMicrophone: false) }
        Task { await meetings.recoverAtLaunch() }
    }

    // MARK: Models

    /// Resolves the live engine from the pick and the engine settings, for the sessions built from now on.
    /// `releasingKeptMicrophone`: a session kept between runs (keep-ready) holds the old engine, so it is
    /// released and the next start builds one with the new engine. During a run, the run's session is
    /// released when the run ends instead of being kept.
    func refreshEngine(releasingKeptMicrophone: Bool = true) async {
        modelRevision += 1
        engineRevision += 1
        let revision = engineRevision
        resolvingEngine = true
        readiness.selectedResourcesReady = false
        modelAdmission.cancel()
        #if ANE_CLEANUP_SPIKE
        spike.admission.cancel()
        #endif
        resourcePreparation?.cancel()
        if releasingKeptMicrophone { await coordinator.invalidateKeptSession() }
        let resolution = await models.engines.liveEngine()
        guard revision == engineRevision else { return }
        engineBox.engine = resolution.engine
        readiness.modelEngineReady = resolution.modelID != nil
        engineStatus = EngineStatus(
            modelID: resolution.modelID,
            name: resolution.modelID.flatMap { id in models.streamingModels.first { $0.id == id }?.displayName } ?? "Apple Speech",
            fallback: resolution.fallback.map(Self.describe))
        #if DEBUG
        E2E.log("engine.resolved id=\(resolution.engine.id) fallback=\(resolution.fallback.map(Self.describe) ?? "none")")
        #endif
        resolvingEngine = false
        if !startEnvironment.current().inBackground { await warmSelectedResources() }
        guard revision == engineRevision else { return }
        await refreshReadiness()
    }

    /// Settings change resource ownership, independently of the microphone's keep-ready duration.
    func cleanupSettingsChanged() {
        modelRevision += 1
        readiness.selectedResourcesReady = false
        modelAdmission.cancel()
        #if ANE_CLEANUP_SPIKE
        spike.admission.cancel()
        #endif
        scheduleResourcePreparation()
    }

    /// Meeting preferences change retention without superseding dictation admission.
    func meetingSettingsChanged() {
        Task { [weak self] in
            guard let self else { return }
            await models.reconcileSelectedModels(options: Settings.cleanupStore.options, inBackground: startEnvironment.current().inBackground)
            if !(startEnvironment.current().inBackground) { meetings.resumeProcessing() }
        }
    }

    private func scheduleResourcePreparation() {
        resourcePreparation?.cancel()
        resourcePreparation = Task { [weak self] in await self?.warmSelectedResources() }
    }

    private func warmSelectedResources() async {
        #if !ANE_CLEANUP_SPIKE
        guard !resolvingEngine, !modelAdmission.isResetting, !startEnvironment.current().inBackground else { return }
        do { try await prepareSelectedResources(); meetings.resumeProcessing() }
        catch is CancellationError { }
        catch { armFailure = "Could not prepare selected models: \(error.localizedDescription)" }
        #endif
    }

    private func prepareSelectedResources() async throws {
        #if DEBUG
        if E2E.fakeEngine != nil {
            readiness.selectedResourcesReady = true
            return
        }
        #endif
        let revision = modelRevision
        let options = Settings.cleanupStore.options
        let inBackground = startEnvironment.current().inBackground
        do {
            try await models.prepareSelectedModels(options: options, inBackground: inBackground)
        } catch SelectedModelWarmup.PreparationError.needsForeground {
            throw PreparationError.needsForeground
        } catch SelectedModelWarmup.PreparationError.superseded {
            throw CancellationError()
        }
        try Task.checkCancellation()
        guard revision == modelRevision, !resolvingEngine, !modelAdmission.isResetting else { throw CancellationError() }
        readiness.selectedResourcesReady = true
    }

    /// Revoke held readiness before relinquishing model ownership; active runs keep their own resources.
    private func releaseModelsForMemoryPressure() async {
        modelRevision += 1
        readiness.selectedResourcesReady = false
        resourcePreparation?.cancel()
        await modelAdmission.reset {
            await self.coordinator.invalidateKeptSession()
            await self.models.releaseSelectedModels()
        }
    }

    private static func describe(_ fallback: EngineFallback) -> String {
        switch fallback {
        case .assetsNotInstalled: "the picked model is not installed"
        case .unknownModel(let id): "the picked model \(id) is not in this build's catalog"
        }
    }

    /// The keyboard's Refine key: a stronger rewrite (message style) of `text`, or nil when there is none.
    /// Runs in the background too, as the background cleanup setting says (the MLX model on the CPU by default).
    func refine(_ text: String) async -> String? {
        #if ANE_CLEANUP_SPIKE
        return await spike.refine(text, locale: ModelServices.singleLocale(models.engineSettings) ?? Locale.current)
        #else
        let lease: SelectedModelWarmup.Lease
        do { lease = try await models.acquireRefine(options: Settings.cleanupStore.options, inBackground: startEnvironment.current().inBackground) }
        catch { return nil }
        let reports = cleanupReports
        let locale = ModelServices.singleLocale(models.engineSettings) ?? Locale.current
        let out = await CleanupProcessor.run(
            text, locale: locale, style: .message, refine: true,
            timeout: .seconds(max(Settings.cleanupTimeoutSeconds * 2, 8)), settings: Settings.cleanupStore,
            registry: models.cleanup,
            report: { report in await reports.record(report) }, vocabulary: vocabulary)
        await lease.release()
        let refined = out.trimmingCharacters(in: .whitespacesAndNewlines)
        #if DEBUG
        E2E.log("refine changed=\(refined != text ? 1 : 0)")
        #endif
        return refined.isEmpty || refined == text ? nil : refined
        #endif
    }

    // MARK: Dictation

    /// The single entry point: Action Button, Control Center, Live Activity stop and the in-app button.
    ///
    /// With the Legato keyboard on screen (it publishes a fresh presence) the text streams into its field;
    /// otherwise it goes to the clipboard. Either way the Live Activity is required (iOS stops a recording
    /// intent without one) and the microphone stays ready for the keep-alive setting.
    ///
    /// `afterForegroundHop`: this press repeats one that returned `.needsForeground(reason)` and the
    /// system has since brought the app to the foreground, so the start is a foreground start.
    func toggle(afterForegroundHop reason: ForegroundReason? = nil) async -> DictationCoordinator.Outcome {
        let options: StartOptions
        if reason != nil, let remembered = hopOptions {
            options = remembered
        } else {
            options = Self.pressOptions()
        }
        hopOptions = nil
        return await run(options, hopReason: reason, source: "toggle") ?? .busy
    }

    /// What a press starts with. The text is neither copied nor typed when the run ends: it waits in the
    /// Live Activity for its Insert and Copy buttons (`insertResult`, `copyResult`).
    static func pressOptions() -> StartOptions {
        StartOptions(activity: .required, keepAlive: Settings.keepAliveLinger, target: .result)
    }

    // MARK: Result buttons

    private func resultReady(_ result: DictationResult) {
        pendingResult = result
        resultExpiry?.cancel()
        resultExpiry = Task { [weak self] in
            try? await Task.sleep(for: .seconds(DictationResult.lifetime))
            guard !Task.isCancelled else { return }
            await self?.expireResult(result)
        }
    }

    private func clearResult() {
        pendingResult = nil
        resultExpiry?.cancel()
        resultExpiry = nil
    }

    private func expireResult(_ result: DictationResult) async {
        guard pendingResult == result else { return }
        clearResult()
        await activityClient.dismiss()
    }

    /// The Live Activity's Insert button: the Legato keyboard on screen types the text. With no keyboard
    /// acting the activity says so and keeps its buttons.
    func insertResult() async {
        guard let result = pendingResult, result.isActionable(now: Date()) else { return }
        let inserted = await keyboardLink?.insert(result.text) ?? false
        await resolveResult(result, inserted ? .inserted : .keyboardNotActive)
    }

    /// The Live Activity's Copy button: writes the clipboard from the background (the write is checked
    /// by its change count; a dropped one leaves the activity in "tap to copy").
    func copyResult() async {
        guard let result = pendingResult, result.isActionable(now: Date()) else { return }
        let changed = pasteboard.forceWrite(result.text, source: "activity-copy")
        #if DEBUG
        WakeProbeLog.log("copy", "changed=\(changed ? 1 : 0) chars=\(result.text.count)")
        #endif
        await resolveResult(result, changed ? .copied : .copyFailed)
    }

    private func resolveResult(_ result: DictationResult, _ outcome: ResultOutcome) async {
        if outcome.endsActivity { clearResult() }
        let content = DictationActivityContent(
            startedAt: result.at, tail: LiveTranscript.tail(of: result.text), phase: outcome.phase)
        await activityClient.resolveResult(content, ends: outcome.endsActivity)
    }

    /// The keyboard asked for this (a request over the link, or `legato://keyboard`). Returns whether it
    /// did what was asked; a start that did not begin a run (refused, not ready) returns false, so the
    /// keyboard is told to open the app.
    @discardableResult
    func perform(_ command: RequestCommand) async -> Bool {
        #if DEBUG
        E2E.log("keyboard.command \(command.rawValue)")
        #endif
        switch command {
        case .start:
            // A start never toggles: a second one while running must not stop the run.
            let options = StartOptions(activity: .bestEffort, keepAlive: Settings.keepAliveLinger, target: .keyboard)
            guard let outcome = await run(options, startOnly: true, source: "keyboard") else { return true }
            if case .started = outcome { return true }
            return false
        case .arm:
            // The keyboard's first tap opened the app: ready the microphone and nothing else. No run, no
            // history entry, no Live Activity, no clipboard; the next tap, back in the host app, starts
            // the dictation on this lease.
            armFailure = nil
            if let notice = MeetingArbitration.dictationRefusal(meetingActive: meetings.isActive) {
                armFailure = notice
                #if DEBUG
                E2E.log("meeting.refused source=keyboard-arm notice=\(E2E.quote(notice))")
                #endif
                return false
            }
            #if !ANE_CLEANUP_SPIKE
            let outcome: DictationCoordinator.ArmOutcome
            do {
                outcome = try await modelAdmission.admit(
                    isIdle: { self.coordinator.isIdle },
                    canStart: { !self.meetings.isActive && !self.resolvingEngine },
                    prepare: { try await self.prepareSelectedResources() },
                    operation: { await self.coordinator.arm(keepAlive: Settings.keepAliveLinger) })
            } catch PreparationError.needsForeground {
                armFailure = "Open Legato to prepare the selected models."
                return false
            } catch ModelAdmission.AdmissionError.busy {
                return !coordinator.isIdle
            } catch is CancellationError {
                return false
            } catch DictationError.assetsNotInstalled {
                armFailure = "Legato needs the speech model first. Open Legato's home screen to set it up."
                await refreshReadiness()
                return false
            } catch {
                armFailure = "Could not prepare selected models: \(error.localizedDescription)"
                return false
            }
            #else
            let outcome: DictationCoordinator.ArmOutcome
            do {
                outcome = try await spike.admission.admit(isIdle: { self.coordinator.isIdle }, canStart: { !self.meetings.isActive }, prepare: {
                    try await self.spike.prepare(inBackground: self.startEnvironment.current().inBackground)
                    self.readiness.selectedResourcesReady = true
                }) { await self.coordinator.arm(keepAlive: Settings.keepAliveLinger) }
            } catch is CancellationError {
                await coordinator.endKeepAlive()
                armFailure = "Dictation preparation was cancelled. Return to the keyboard and tap the microphone to try again."
                return false
            } catch ParityPreparationError.needsForeground {
                armFailure = "Open the app to prepare dictation, then return to the keyboard."
                return false
            } catch ParityPreparationError.busy {
                if let notice = MeetingArbitration.dictationRefusal(meetingActive: meetings.isActive) {
                    armFailure = notice
                    return false
                }
                if spike.admission.isResetting {
                    armFailure = "Dictation is releasing its model. Return to the keyboard and try the microphone again."
                    return false
                }
                return true
            }
            catch {
                armFailure = "The cleanup model could not be readied. Check the staged Qwen3 model and try again."
                spike.record("model.prepare.failed", ["errorType": String(describing: type(of: error))])
                return false
            }
            #endif
            #if DEBUG
            E2E.log("arm outcome=\(Self.describe(outcome))")
            #endif
            switch outcome {
            case .armed, .busy: return true // busy: a run holds the mic already
            case .needsOnboarding:
                armFailure = "Legato needs a permission or the speech model first. Open Legato's home screen to set it up."
                await refreshReadiness()
            case .needsForeground, .failed:
                armFailure = "The microphone could not be readied. Try again."
            }
            return false
        case .stop:
            await stopIfRunning()
            return true
        case .endKeepAlive:
            await endKeepAlive()
            return true
        }
    }

    /// Releases the microphone kept ready between dictations.
    func endKeepAlive() async {
        modelAdmission.cancel()
        #if ANE_CLEANUP_SPIKE
        spike.admission.cancel()
        #endif
        await coordinator.endKeepAlive()
    }

    /// The audio policy changed: a held microphone (lease, or a session kept by the internal switch) is
    /// released so the next start activates under the new policy.
    func audioPolicySettingChanged() async {
        await coordinator.audioPolicyChanged()
        releaseHeldSession()
    }

    /// The keep-ready setting changed: a held microphone follows it (released for Off, re-armed otherwise).
    func keepAliveSettingChanged(_ linger: Linger) async {
        await coordinator.updateKeepAlive(linger)
    }

    func dismissKeyboardHop() {
        showsKeyboardHop = false
    }

    /// `startOnly`: never stops a run in progress; nil when one was in progress (nothing started).
    private func run(
        _ options: StartOptions, hopReason reason: ForegroundReason? = nil, startOnly: Bool = false, source: String
    ) async -> DictationCoordinator.Outcome? {
        // A stop never waits for model preparation, including a second toggle during a cold start.
        if !startOnly, modelAdmission.isPreparing || !coordinator.isIdle {
            return await stopIfRunning() ?? .busy
        }
        if startOnly, !coordinator.isIdle { return nil }
        // A meeting owns the microphone: no dictation from the keyboard, the Action Button or the app.
        if let notice = MeetingArbitration.dictationRefusal(meetingActive: meetings.isActive) {
            armFailure = notice
            #if DEBUG
            E2E.log("meeting.refused source=\(source) notice=\(E2E.quote(notice))")
            #endif
            return .failed(notice)
        }
        let finishedBefore = idleCount
        #if LEGATO_INTERNAL
        AudioDiagnostics.log("toggle.begin", ["isDictating": isDictating])
        #endif
        #if DEBUG
        E2E.log("route target=\(Self.describe(options.target)) activity=\(options.activity == .required ? "required" : "bestEffort") keepAliveSeconds=\(E2E.seconds(of: options.keepAlive))")
        #endif
        startEnvironment.assumeForeground = reason != nil
        defer { startEnvironment.assumeForeground = false }
        #if !ANE_CLEANUP_SPIKE
        let outcome: DictationCoordinator.Outcome
        do {
            if resolvingEngine, startEnvironment.current().inBackground {
                throw PreparationError.needsForeground
            }
            outcome = try await modelAdmission.admit(
                isIdle: { self.coordinator.isIdle },
                canStart: { !self.meetings.isActive && !self.resolvingEngine },
                prepare: { try await self.prepareSelectedResources() },
                operation: { await self.coordinator.startIfIdle(options) ?? .busy })
        } catch PreparationError.needsForeground {
            outcome = .needsForeground(.modelPreparationRequired)
        } catch ModelAdmission.AdmissionError.busy {
            outcome = .busy
        } catch is CancellationError {
            outcome = .busy
        } catch DictationError.assetsNotInstalled {
            outcome = .needsOnboarding(.assetsMissing)
        } catch {
            outcome = .failed("Could not prepare selected models: \(error.localizedDescription)")
        }
        #else
        let outcome: DictationCoordinator.Outcome
        if spike.admission.isPreparing {
            if startOnly { return nil }
            _ = await stopIfRunning()
            return .stopped(nil)
        } else if isDictating || keyboardRunActive {
            // A Stop/toggle is never gated on cleanup model availability.
            guard !startOnly else { return nil }
            outcome = await coordinator.toggle(options)
        } else {
            do {
                outcome = try await spike.admission.admit(isIdle: { self.coordinator.isIdle }, canStart: { !self.meetings.isActive }, prepare: {
                    try await self.spike.prepare(inBackground: self.startEnvironment.current().inBackground)
                    self.readiness.selectedResourcesReady = true
                }) { await self.coordinator.startIfIdle(options) ?? .busy }
            } catch ParityPreparationError.needsForeground {
                // The existing intent continues in the foreground; the keyboard receives its normal hop response.
                outcome = .needsForeground(.modelPreparationRequired)
                spike.record("start.modelNeedsForeground")
            } catch is CancellationError {
                _ = await coordinator.stopIfRunning()
                await coordinator.endKeepAlive()
                return .stopped(nil)
            } catch ParityPreparationError.busy {
                if let notice = MeetingArbitration.dictationRefusal(meetingActive: meetings.isActive) {
                    armFailure = notice
                    return .failed(notice)
                }
                return .busy
            }
            catch {
                spike.record("model.prepare.failed", ["errorType": String(describing: type(of: error))])
                return .failed("The cleanup model could not be prepared.")
            }
        }
        #endif
        if case .needsForeground = outcome { hopOptions = options } // the press that repeats this one keeps them
        await didFinish(outcome, hopReason: reason, finishedBefore: finishedBefore)
        return outcome
    }

    /// Ends a running dictation (or cancels a start in progress) and does nothing otherwise; never
    /// starts one. For system events only: a late event must not begin a new run. Nil when there was
    /// nothing to stop.
    ///
    /// `releasingLease`: the mic lease the run would keep for the keep-alive window ends with it (a
    /// system event means that lease is dead).
    @discardableResult
    func stopIfRunning(releasingLease: Bool = false) async -> DictationCoordinator.Outcome? {
        let finishedBefore = idleCount
        #if !ANE_CLEANUP_SPIKE
        guard let outcome = await modelAdmission.stop(operation: {
            await self.coordinator.stopIfRunning(releasingLease: releasingLease)
        }) else { return nil }
        #else
        let stopped = await spike.admission.stop {
            await self.coordinator.stopIfRunning(releasingLease: releasingLease)
        }
        guard let outcome = stopped else { return nil }
        #endif
        await didFinish(outcome, finishedBefore: finishedBefore)
        return outcome
    }

    private func didFinish(
        _ outcome: DictationCoordinator.Outcome, hopReason: ForegroundReason? = nil, finishedBefore: Int
    ) async {
        #if LEGATO_INTERNAL
        AudioDiagnostics.log("toggle.end", ["outcome": Self.outcomeKind(outcome)])
        #endif
        #if ANE_CLEANUP_SPIKE
        spike.record("dictation.outcome", ["outcome": Self.outcomeKind(outcome)])
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
    private static func describe(_ target: DictationTarget) -> String {
        switch target {
        case .app: "app"
        case .result: "result"
        case .keyboard: "keyboard"
        }
    }

    private static func describe(_ outcome: DictationCoordinator.ArmOutcome) -> String {
        switch outcome {
        case .armed: "armed"
        case .busy: "busy"
        case .needsOnboarding(let issue): "needsOnboarding(\(issue))"
        case .needsForeground(let reason): "needsForeground(\(reason.rawValue))"
        case .failed(let error): "failed(\(E2E.quote(error)))"
        }
    }

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

    /// The keyboard opened the app. Only a URL that our keyboard's own fresh request backs acts (and shows the
    /// hop screen); any other `legato://keyboard` URL just opens the app: it can come from anywhere, and
    /// acting on it would start the microphone. The command runs once per id, whichever copy arrives first.
    private func handleKeyboard(_ command: RequestCommand, requestID: String) async {
        guard let keyboardLink else { return }
        // The keyboard writes its request when the Link is tapped; the app can be up before the store shows it.
        var admission = keyboardLink.link.admitURL(requestID: requestID, command: command)
        for _ in 0..<4 where admission == .rejected {
            try? await Task.sleep(for: .milliseconds(150))
            admission = keyboardLink.link.admitURL(requestID: requestID, command: command)
        }
        #if DEBUG
        E2E.log("keyboard.url admission=\(admission)")
        #endif
        guard admission != .rejected else { return }
        let hops = command == .start || command == .arm
        if hops { showsKeyboardHop = true }
        #if DEBUG
        if hops { E2E.log("hop shown command=\(command.rawValue)") }
        #endif
        guard admission == .act else {
            #if DEBUG
            E2E.log("keyboard.url duplicate req=\(requestID)")
            #endif
            return
        }
        await perform(command)
    }

    private func runDidEnd() {
        idleCount += 1
        isDictating = false
        #if ANE_CLEANUP_SPIKE
        spike.sampleMemory("run.ended")
        #endif
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
            // The system took the microphone or the route: a lease kept for the keyboard is dead too, idle
            // or not, and the run this stops must not keep one either.
            await endKeepAlive()
            #if DEBUG
            E2E.log("system-event reason=\(E2E.quote(reason))")
            #endif
            if await stopIfRunning(releasingLease: true) != nil {
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

        #if !ANE_CLEANUP_SPIKE
        center.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in await self?.releaseModelsForMemoryPressure() }
        }
        #endif

        center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let options = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            let shouldResume = AVAudioSession.InterruptionOptions(rawValue: options).contains(.shouldResume)
            Task { @MainActor in
                guard let self else { return }
                // A meeting mutes and resumes by itself; dictation cannot be running next to it.
                if self.meetings.isActive {
                    if raw == AVAudioSession.InterruptionType.began.rawValue { self.meetings.interruptionBegan() }
                    if raw == AVAudioSession.InterruptionType.ended.rawValue { self.meetings.interruptionEnded(shouldResume: shouldResume) }
                    return
                }
                guard raw == AVAudioSession.InterruptionType.began.rawValue else { return }
                self.stopForSystemEvent("interruption began", releasesHeldSession: true)
            }
        }

        center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] note in
            let reason = (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt)
                .flatMap(AVAudioSession.RouteChangeReason.init(rawValue:))
            let previous = (note.userInfo?[AVAudioSessionRouteChangePreviousRouteKey] as? AVAudioSessionRouteDescription)
                .map { Set($0.inputs.map(\.uid)) } ?? []
            let current = Set(AVAudioSession.sharedInstance().currentRoute.inputs.map(\.uid))
            let changedInput = reason == .newDeviceAvailable || reason == .oldDeviceUnavailable
            Task { @MainActor in
                guard let self, self.meetings.isActive else { return }
                if changedInput { self.meetings.routeChanged() }
            }
            guard InputRoute.shouldStop(
                reasonIsOldDeviceUnavailable: reason == .oldDeviceUnavailable,
                previousInputs: previous,
                currentInputs: current)
            else { return }
            Task { @MainActor in
                guard let self, !self.meetings.isActive else { return } // a meeting restarts its own engine
                self.stopForSystemEvent("input lost")
            }
        }

        center.addObserver(forName: .AVAudioEngineConfigurationChange, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if self.meetings.isActive { self.meetings.routeChanged() } else { self.stopForSystemEvent("engine configuration change") }
            }
        }

        center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if self.meetings.isActive {
                    self.meetings.interruptionBegan()
                    self.meetings.interruptionEnded(shouldResume: true)
                } else {
                    self.stopForSystemEvent("media services reset", releasesHeldSession: true)
                }
            }
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
        keyboardLink?.link.scrubText() // a deleted dictation must not linger in the App Group
        keyboardLink?.link.removePendingChoices() // nor the words the keyboard queued from it
        await refreshLastTranscript()
    }

    func copy(_ text: String) {
        pasteboard.forceWrite(text)
    }

    /// The app came to the foreground: a meeting that could not resume, or whose after-stop chain was cut
    /// short, continues.
    func appBecameActive() {
        keyboardLink?.drainChoices() // choices whose Darwin note arrived while the app was suspended
        self.meetings.appBecameActive()
        scheduleResourcePreparation()
    }

    func refreshReadiness() async {
        status = await readiness.snapshot()
    }

    func refreshLastTranscript() async {
        lastTranscript = (try? await history.recent(limit: 1))?.first?.text
    }

    /// `legato://copy-last`: the tapToCopy activity opened the app; copy the newest transcript.
    /// `legato://keyboard?cmd=…&req=…`: the keyboard sent the user here.
    func handle(_ url: URL) async {
        #if DEBUG
        if await handleE2E(url) { return }
        #endif
        if let request = KeyboardURL.parse(url) {
            await handleKeyboard(request.command, requestID: request.requestID)
            return
        }
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
