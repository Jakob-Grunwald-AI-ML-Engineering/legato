import AppKit
import ApplicationServices
import Foundation
import LegatoAppServices
import LegatoAppleSpeech
import LegatoAudio
import LegatoCore
import LegatoEngines
import LegatoMac
import LegatoModels
import LegatoPostProcessing
import Observation
import os

/// The composition root: wires the hotkey, the dictation session, the field writer, the HUD and
/// the paste/copy fallback together. All work happens on the main actor.
///
/// Hotkey events go through `HotkeyGesture`; its actions (and engine aborts) are queued and run one
/// at a time, so a start, a stop and the finish after it can never overlap.
///
/// The engine is resolved from the model pick (`refreshEngine`, after a pick, a delete or an engine
/// setting change) and cached; the session is rebuilt with it before the next run starts.
@MainActor @Observable
final class MacAppController {
    static let shared = MacAppController()
    static let onboardingWindowID = "onboarding"

    private static let log = Logger(subsystem: "de.gruenwald.legato", category: "mac")

    enum Phase: Equatable { case idle, preparing, listening, finishing }
    enum SettingsTab: Hashable { case general, speech, cleanup, meetings }
    /// Which hotkey the recorder is capturing.
    enum HotkeyTarget: Hashable { case dictation, mute }

    private(set) var phase = Phase.idle
    /// The newest history entries (20), newest first.
    private(set) var recent: [DictationEntry] = []
    /// Bumped to ask the UI to show the onboarding window.
    private(set) var onboardingRequests = 0
    private(set) var isRecordingHotkey = false
    private(set) var recordingTarget = HotkeyTarget.dictation
    private(set) var recordingPreview: String?
    /// A hotkey press found something unfinished in setup while the user was in another app:
    /// the menu-bar icon shows a warning until the onboarding window is opened.
    private(set) var setupAttention = false
    /// Which engine new dictations use.
    private(set) var engineStatus = EngineStatus()
    /// The streaming models that are installed, for the menu's engine switch.
    private(set) var installedStreamingModels: Set<String> = []
    /// The last delivered dictation, while it can still be swapped for another version.
    private(set) var lastDictation: DictationEntry?
    /// A refine of the last dictation is running.
    private(set) var isRefining = false
    /// The pane the Settings window shows (the menu opens it on a pane).
    var settingsTab = SettingsTab.general

    @ObservationIgnored let settings: MacSettings
    @ObservationIgnored let permissions: Permissions
    @ObservationIgnored let loginItem = LoginItem()
    /// The model catalog, the engine and the cleanup registries.
    @ObservationIgnored let models: ModelServices
    /// Meeting notes: recording, mute, the library and the after-stop chain.
    @ObservationIgnored let meetings: MeetingController
    /// Matches the meeting mute hotkey; rebuilt when the hotkey changes.
    @ObservationIgnored private var muteDetector: HotkeyPressDetector?
    #if DEBUG
    /// Kept alive for the `--meeting-selftest` run.
    @ObservationIgnored private var selfTestController: MeetingController?
    #endif
    /// What the last cleanup (or refine) did.
    let cleanupReports: CleanupReports
    /// The live engine (resolved from the pick); `session` is rebuilt with it before the next run.
    @ObservationIgnored private var engine: any DictationEngine
    @ObservationIgnored private var sessionIsStale = false
    @ObservationIgnored private let cleanup: CleanupProcessor
    /// The session's post-processor: `cleanup`, kept out of a run the cleanup agent works on.
    @ObservationIgnored private let agentGate: AgentGatedPostProcessor
    @ObservationIgnored private let history: any HistoryStore
    /// The personal vocabulary: hints the engines and the cleanup step, and learns from dictations.
    @ObservationIgnored let vocabulary: VocabularyService
    @ObservationIgnored private var session: DictationSession
    @ObservationIgnored private var editPump: Task<Void, Never>?
    /// The writer of the last delivered dictation: version swaps go through it.
    @ObservationIgnored private var lastWriter: FieldWriter?
    @ObservationIgnored private let hud: HUDPanelController
    @ObservationIgnored private let paster = PasteService()
    @ObservationIgnored private let tap = HotkeyTap()
    @ObservationIgnored private var gesture: HotkeyGesture
    @ObservationIgnored private var recorder = HotkeyRecorderLogic()
    @ObservationIgnored private var commands: AsyncStream<Command>.Continuation?
    @ObservationIgnored private var activeRun: Run?
    /// Edits the pump has handed to the writer so far; compared with `session.editCount` to know it caught up.
    @ObservationIgnored private var appliedEdits = 0
    /// Fires `gesture.tick` when a press has been held alone for the arm delay.
    @ObservationIgnored private var armTask: Task<Void, Never>?
    @ObservationIgnored private var triggerPressedAt: TimeInterval?
    @ObservationIgnored private var bootstrapped = false
    @ObservationIgnored private let modelAdmission = ModelAdmission()
    @ObservationIgnored private var modelRevision = 0
    @ObservationIgnored private var engineRevision = 0
    @ObservationIgnored private var resolvingEngine = false
    @ObservationIgnored private var resourcePreparation: Task<Void, Never>?
    @ObservationIgnored private var memoryPressure: (any DispatchSourceMemoryPressure)?
    private(set) var isPreparingModels = false

    private enum Command: Sendable {
        case start, stop, cancel
        case aborted(UUID)
    }

    /// One dictation from key press to delivery.
    private final class Run {
        let id = UUID()
        let writer: FieldWriter
        /// The edit queue's wiring for this run; nil when there is no field it can read.
        let fieldEdit: FieldEditRun?
        let targetPID: pid_t?
        let startedAt = Date()
        /// The field was (or could not be ruled out as) a secure one: never typed or pasted into.
        let secureField: Bool
        /// How a cleaned text reaches the field: the setting when the run started, nil with cleanup off.
        let delivery: CleanupDelivery?
        /// The run's text as the edit pump saw it (raw committed and the tentative tail), for the HUD.
        var transcript = LiveTranscript()
        /// Everything the engine committed, as the edit pump saw it.
        var committed: String { transcript.committed }

        init(
            writer: FieldWriter, fieldEdit: FieldEditRun?, targetPID: pid_t?, secureField: Bool,
            delivery: CleanupDelivery?
        ) {
            self.writer = writer
            self.fieldEdit = fieldEdit
            self.targetPID = targetPID
            self.secureField = secureField
            self.delivery = delivery
        }
    }

    private init() {
        let support = URL.applicationSupportDirectory.appending(path: "Legato", directoryHint: .isDirectory)
        // The vocabulary comes before ModelServices: the engines it builds ask it for hints.
        // The languages are read on every use, so a change of the dictation languages applies at once.
        let languageSettings = EngineSettings(defaults: .standard)
        let vocabulary = VocabularyService(
            fileURL: support.appending(path: "vocabulary.json"),
            languages: { VocabularyService.configuredLanguages(languageSettings) })
        self.vocabulary = vocabulary
        let history: any HistoryStore = LearningHistoryStore(
            JSONLHistoryStore(fileURL: support.appending(path: "history.jsonl")), vocabulary: vocabulary)
        self.history = history
        let settings = MacSettings()
        self.settings = settings
        // Apple Speech's asset download lives in Permissions; dictation uses `engine`.
        permissions = Permissions(engine: AppleSpeechEngine(vocabulary: vocabulary))
        gesture = HotkeyGesture(mode: settings.gestureMode)
        let models = ModelServices(root: FluidAudioCatalog.defaultRoot(), defaults: .standard, vocabulary: vocabulary)
        self.models = models
        meetings = MeetingController(models: models)
        let reports = CleanupReports()
        cleanupReports = reports
        let hud = HUDPanelController()
        self.hud = hud
        let engineSettings = models.engineSettings
        let cleanup = CleanupProcessor(
            registry: models.cleanup, settings: settings.cleanupStore,
            preferredLocale: { ModelServices.singleLocale(engineSettings) },
            willRun: { await hud.setPhase(.cleaningUp) },
            vocabulary: vocabulary,
            acquireRunWithOptions: { options in try await models.acquireDictationCleanup(options: options, inBackground: true) },
            report: { report in await reports.record(report) })
        self.cleanup = cleanup
        // The session's one cleanup at stop (a run with no field to edit) is the rolling session's rewrite.
        let store = settings.cleanupStore
        let gate = AgentGatedPostProcessor(cleanup, rewrite: { text, _ in
            await hud.setPhase(.cleaningUp)
            return await models.rollingRewrite(text, options: store.options, vocabulary: vocabulary)
        })
        agentGate = gate
        let engine = AppleSpeechEngine(vocabulary: vocabulary)
        self.engine = engine
        session = Self.makeSession(engine: engine, history: history, postProcessor: gate)
    }

    private static func makeSession(
        engine: any DictationEngine, history: any HistoryStore, postProcessor: any TranscriptPostProcessor
    ) -> DictationSession {
        DictationSession(
            engine: engine,
            source: MicSource(),
            sessionControl: AudioSessionController(),
            history: history,
            postProcessor: postProcessor,
            linger: .zero)
    }

    /// Hooks the controller to `session`: its aborts and its edit stream.
    private func attachSession() {
        // The engine stream failed under a run: the session has already torn itself down.
        session.onRunAborted = { [weak self] _ in
            guard let self, let run = activeRun else { return }
            commands?.yield(.aborted(run.id))
        }
        editPump?.cancel()
        appliedEdits = 0
        editPump = Task { [weak self, edits = session.edits] in
            for await edit in edits { self?.apply(edit) }
        }
    }

    /// Builds a session with the current engine when the engine changed since. Only between runs.
    private func rebuildSessionIfStale() {
        guard sessionIsStale, activeRun == nil else { return }
        sessionIsStale = false
        session = Self.makeSession(engine: engine, history: history, postProcessor: agentGate)
        attachSession()
    }

    // MARK: Derived state for the UI

    var isDictating: Bool { phase != .idle || isPreparingModels }

    var permissionsDone: Bool {
        permissions.micGranted && permissions.accessibility && permissions.hotkeyTapActive
    }

    /// Something the dictation flow needs is missing.
    var needsSetup: Bool {
        !permissionsDone || settings.hotkey == nil || !permissions.modelInstalled
    }

    var statusText: String {
        if isPreparingModels { return "Preparing models…" }
        switch phase {
        case .preparing: return "Starting…"
        case .listening: return "Listening…"
        case .finishing: return "Finishing…"
        case .idle:
            guard let hotkey = settings.hotkey else { return "Choose a hotkey" }
            if needsSetup { return "Setup incomplete" }
            return "Ready · \(hotkey.displayName)"
        }
    }

    var statusSymbol: String {
        switch phase {
        case .idle: needsSetup ? "exclamationmark.triangle" : "mic"
        default: "waveform"
        }
    }

    // MARK: Launch

    /// Starts the hotkey, the edit pump and the permission poll. Called once at launch.
    func bootstrap() {
        guard !bootstrapped else { return }
        bootstrapped = true

        let (stream, continuation) = AsyncStream.makeStream(of: Command.self)
        commands = continuation
        Task { [weak self] in
            for await command in stream {
                guard let self else { return }
                await self.perform(command)
            }
        }
        attachSession()
        installModelLifecycleObservers()
        Task { [weak self, samples = tap.samples] in
            for await sample in samples { self?.handle(sample) }
        }
        Task { [weak self] in
            while !Task.isCancelled {
                self?.pollSystem()
                try? await Task.sleep(for: .seconds(1))
            }
        }
        #if DEBUG
        if let selfTest = Self.meetingSelfTestArguments() {
            runMeetingSelfTest(selfTest)
            return
        }
        #endif
        Task { [weak self] in
            // First, before a meeting can start: a recording meeting found later could be a live one.
            await self?.meetings.recoverAtLaunch()
            await self?.refreshRecent()
            await self?.refreshEngine() // also checks Apple Speech's assets when it is the live engine
            self?.pollSystem()
            if self?.needsSetup == true { self?.requestOnboarding() }
        }
    }

    func requestOnboarding() {
        setupAttention = false
        onboardingRequests += 1
    }

    /// Something is missing, discovered from a hotkey press: do not pull the user out of the app
    /// they are in. Show a toast and flag the menu-bar item instead.
    private func flagSetup() {
        setupAttention = true
        hud.show(toast: "Open Legato to finish setup")
    }

    /// The hotkey spec's caution, if any, for the recorder UI.
    var hotkeyWarning: HotkeySpec.Warning? { settings.hotkey?.warning }

    /// Permissions can change at any time: keep the event tap alive and in step with them.
    private func pollSystem() {
        permissions.refresh()
        if tap.isActive, !tap.isEnabled {
            tap.stop() // revoked behind our back; try again below
            resetGesture()
        }
        // Only try once a grant exists: creating the tap without one makes macOS show a prompt.
        if !tap.isActive, permissions.accessibility || CGPreflightListenEventAccess() {
            resetGesture() // key events while there was no tap are gone
            tap.start()
        }
        if permissions.hotkeyTapActive != tap.isActive { permissions.hotkeyTapActive = tap.isActive }
        if setupAttention, !needsSetup { setupAttention = false }
        releaseStuckTrigger()
    }

    // MARK: Models

    /// Resolves the live engine from the pick and the engine settings, for the runs from now on. A run in
    /// progress keeps its engine; the session is rebuilt before the next one.
    func refreshEngine() async {
        modelRevision += 1
        engineRevision += 1
        let revision = engineRevision
        resolvingEngine = true
        modelAdmission.cancel()
        resourcePreparation?.cancel()
        let resolution = await models.engines.liveEngine()
        guard revision == engineRevision else { return }
        engine = resolution.engine
        sessionIsStale = true
        rebuildSessionIfStale()
        permissions.appleSpeechLive = resolution.modelID == nil
        engineStatus = EngineStatus(
            modelID: resolution.modelID,
            name: resolution.modelID.map { models.engineName(for: $0) } ?? "Apple Speech",
            fallback: resolution.fallback?.explanation)
        resolvingEngine = false
        await warmSelectedResources()
        guard revision == engineRevision else { return }
        await refreshInstalledModels()
        if resolution.modelID == nil { await permissions.refreshModel() }
    }

    func cleanupSettingsChanged() {
        modelRevision += 1
        modelAdmission.cancel()
        scheduleResourcePreparation()
    }

    /// Meeting preferences change retention without superseding dictation admission.
    func meetingSettingsChanged() {
        Task { [weak self] in
            guard let self else { return }
            await models.reconcileSelectedModels(options: settings.cleanupStore.options, inBackground: false)
            meetings.resumeProcessing()
        }
    }

    private func scheduleResourcePreparation() {
        resourcePreparation?.cancel()
        resourcePreparation = Task { [weak self] in await self?.warmSelectedResources() }
    }

    private func prepareSelectedResources() async throws {
        let revision = modelRevision
        do {
            try await models.prepareSelectedModels(options: settings.cleanupStore.options, inBackground: false)
        } catch SelectedModelWarmup.PreparationError.superseded {
            throw CancellationError()
        }
        try Task.checkCancellation()
        guard revision == modelRevision, !resolvingEngine, !modelAdmission.isResetting else { throw CancellationError() }
    }

    private func warmSelectedResources() async {
        guard !resolvingEngine, !modelAdmission.isResetting else { return }
        do { try await prepareSelectedResources(); meetings.resumeProcessing() }
        catch is CancellationError { }
        catch { Self.log.error("selected model preparation failed: \(Self.describe(error), privacy: .public)") }
    }

    private func installModelLifecycleObservers() {
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.scheduleResourcePreparation() }
        }
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler { [weak self] in
            Task { @MainActor in await self?.releaseModelsForMemoryPressure() }
        }
        memoryPressure = source
        source.resume()
    }

    private func releaseModelsForMemoryPressure() async {
        modelRevision += 1
        resourcePreparation?.cancel()
        await modelAdmission.reset {
            // The active session keeps its own engine; the next run receives a fresh session.
            self.sessionIsStale = true
            await self.models.releaseSelectedModels()
        }
    }

    func refreshInstalledModels() async {
        var installed: Set<String> = []
        for descriptor in models.streamingModels {
            if case .installed = await models.manager.state(of: descriptor.id) { installed.insert(descriptor.id) }
        }
        if installed != installedStreamingModels { installedStreamingModels = installed }
    }

    /// The menu's engine switch: nil is Apple Speech. An installed model is picked straight away; anything
    /// else is for the Speech engine pane, which shows the download.
    func switchEngine(to id: String?) {
        guard let id else {
            models.clearPick(.liveDictation)
            Task { await refreshEngine() }
            return
        }
        models.pick(id, role: .liveDictation) { [weak self] error in
            if let error { self?.hud.show(toast: "Could not switch: \(String(describing: error))") }
            Task { await self?.refreshEngine() }
        }
    }

    /// The menu's engine switch for a family: its chosen tier, picked straight away when installed.
    func switchEngine(to family: ModelFamily) {
        models.pick(family: family) { [weak self] error in
            if let error { self?.hud.show(toast: "Could not switch: \(String(describing: error))") }
            Task { await self?.refreshEngine() }
        }
    }

    // MARK: Versions

    /// The last dictation's raw text in place of its cleaned text: swapped in the field when it still ends
    /// with what was delivered, else copied.
    func revertLastToRaw() {
        guard phase == .idle, let entry = lastDictation, let raw = entry.rawText else { return }
        swapLast(to: raw, label: "raw text")
    }

    /// Refines the last dictation in the selected mode (Voice uses Message), swapped in like `revertLastToRaw`.
    func refineLast() async {
        guard phase == .idle, !isRefining, let entry = lastDictation else { return }
        isRefining = true
        defer { isRefining = false }
        let options = settings.cleanupStore.options
        let lease: SelectedModelWarmup.Lease
        do { lease = try await models.acquireRefine(options: options, inBackground: false) }
        catch { hud.show(toast: "Refine unavailable."); return }
        hud.show(toast: "Refining…", for: 30)
        let reports = cleanupReports
        let store = settings.cleanupStore
        let locale = ModelServices.singleLocale(models.engineSettings) ?? Locale(identifier: entry.localeIdentifier)
        let out = await CleanupProcessor.run(
            entry.text, locale: locale, style: options.style.refineStyle, refine: true,
            timeout: .seconds(max(options.timeoutSeconds * 2, 8)), settings: store, registry: models.cleanup,
            report: { report in await reports.record(report) }, vocabulary: vocabulary,
            resolution: await models.cleanup.resolve(preference: options.backend.preference), options: options)
        await lease.release()
        let refined = out.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !refined.isEmpty, refined != entry.text else {
            hud.show(toast: "Refine changed nothing.")
            return
        }
        // A new dictation started or arrived meanwhile: its field is not ours to touch.
        guard phase == .idle, lastDictation?.id == entry.id else { return }
        swapLast(to: refined, label: "refined text")
    }

    private func swapLast(to text: String, label: String) {
        switch lastWriter?.swapWritten(for: text) ?? .nothingWritten {
        case .swapped:
            hud.show(toast: "Swapped in the \(label).")
        case .nothingWritten, .leftInPlace, .held:
            paster.copy(text)
            hud.show(toast: "Copied the \(label) — paste with ⌘V.")
        }
    }

    // MARK: History

    func refreshRecent() async {
        recent = (try? await history.recent(limit: 20)) ?? []
    }

    func copy(_ entry: DictationEntry) {
        paster.copy(entry.text)
    }

    func delete(_ entry: DictationEntry) {
        Task {
            try? await history.delete(id: entry.id)
            await refreshRecent()
        }
    }

    // MARK: Hotkey recording

    func beginRecording(_ target: HotkeyTarget = .dictation) {
        guard tap.isActive else {
            hud.show(toast: "Grant Accessibility access first.")
            return
        }
        resetGesture()
        recorder = HotkeyRecorderLogic()
        recordingPreview = nil
        recordingTarget = target
        isRecordingHotkey = true
    }

    func cancelRecording() {
        isRecordingHotkey = false
        recordingPreview = nil
    }

    // MARK: Key events

    private func handle(_ sample: TapSample) {
        guard let event = sample.event else {
            resetGesture() // the tap was disabled for a while: held keys can no longer be trusted
            return
        }
        if isRecordingHotkey {
            switch recorder.feed(event) {
            case .none: break
            case .preview(let text): recordingPreview = text
            case .captured(let spec):
                capture(spec)
                cancelRecording()
            case .cancelled: cancelRecording()
            }
            return
        }
        feedMuteHotkey(event)
        guard let hotkey = settings.hotkey, let trigger = hotkey.triggerEvent(for: event) else { return }
        // A timer that fired late must not reorder things: bring the gesture up to this event's time first.
        dispatch(gesture.tick(at: sample.time))
        if trigger == .pressed, phase == .idle, gesture.mode != settings.gestureMode {
            gesture = HotkeyGesture(mode: settings.gestureMode)
        }
        if trigger == .pressed, case .modifier = hotkey, gesture.isTriggerDown {
            // A lone modifier cannot go down twice: its release was lost. Close that press first.
            dispatch(gesture.released(at: sample.time))
        }
        switch trigger {
        case .pressed:
            triggerPressedAt = sample.time
            dispatch(gesture.pressed(at: sample.time))
        case .released:
            triggerPressedAt = nil
            dispatch(gesture.released(at: sample.time))
        case .otherKeyDown:
            dispatch(gesture.otherKeyDown())
        }
        scheduleArm()
    }

    /// A recorded hotkey goes to the target being recorded, unless the other target already uses it.
    private func capture(_ spec: HotkeySpec) {
        switch recordingTarget {
        case .dictation:
            if let mute = settings.muteHotkey, spec.conflicts(with: mute) {
                hud.show(toast: "\(spec.displayName) is already the mute hotkey.")
            } else {
                settings.hotkey = spec
            }
        case .mute:
            if let dictation = settings.hotkey, spec.conflicts(with: dictation) {
                hud.show(toast: "\(spec.displayName) is already the dictation hotkey.")
            } else {
                settings.muteHotkey = spec
            }
        }
    }

    /// The second hotkey: toggles the mic mute of the running meeting. The dictation gesture is untouched.
    private func feedMuteHotkey(_ event: KeyEvent) {
        guard let spec = settings.muteHotkey else {
            muteDetector = nil
            return
        }
        if muteDetector?.spec != spec { muteDetector = HotkeyPressDetector(spec: spec) }
        guard muteDetector?.feed(event) == true, meetings.phase == .recording else { return }
        meetings.toggleManualMute()
        hud.show(toast: meetings.isMuted ? "Muted in the meeting." : "Unmuted.")
    }

    private func dispatch(_ action: HotkeyGesture.Action?) {
        switch action {
        case .start: commands?.yield(.start)
        case .stop:
            modelAdmission.cancel() // the command pump may be waiting for resource preparation
            commands?.yield(.stop)
        case .cancel:
            modelAdmission.cancel()
            commands?.yield(.cancel)
        case nil: break
        }
    }

    /// Wakes up when the pressed trigger has been held alone long enough to start a run.
    private func scheduleArm() {
        armTask?.cancel()
        armTask = nil
        guard let deadline = gesture.armDeadline else { return }
        armTask = Task { [weak self] in
            let wait = deadline - ProcessInfo.processInfo.systemUptime
            if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
            guard !Task.isCancelled, let self else { return }
            self.dispatch(self.gesture.tick(at: max(ProcessInfo.processInfo.systemUptime, deadline)))
        }
    }

    /// Key events were lost (tap restarted or re-enabled): forget any press or latch in progress.
    private func resetGesture() {
        armTask?.cancel()
        armTask = nil
        triggerPressedAt = nil
        gesture.reset()
        muteDetector?.reset()
    }

    /// Safety net for a lost release of a lone-modifier trigger: if the keyboard says the modifier
    /// has been up for a while but the gesture still thinks it is held, close the press.
    private func releaseStuckTrigger() {
        guard case .modifier(let key)? = settings.hotkey, gesture.isTriggerDown,
              let pressedAt = triggerPressedAt, ProcessInfo.processInfo.systemUptime - pressedAt > 1.5
        else { return }
        let raw = CGEventSource.flagsState(.combinedSessionState).rawValue
        let flags = ModifierFlags(rawValue: UInt(truncatingIfNeeded: raw) & 0xFFFF_0000)
        guard !flags.contains(key.flag) else { return }
        triggerPressedAt = nil
        dispatch(gesture.released(at: ProcessInfo.processInfo.systemUptime))
        scheduleArm()
    }

    // MARK: Commands

    private func perform(_ command: Command) async {
        switch command {
        case .start: await startRun()
        case .stop: await finishRun(discard: false)
        case .cancel: await finishRun(discard: true)
        case .aborted(let id): await abortRun(id: id)
        }
    }

    private func startRun() async {
        guard activeRun == nil else {
            // A start while a run is already going means the gesture lost track of it (events were
            // lost): treat the press as the stop tap.
            gesture.runEnded()
            if phase == .listening { await finishRun(discard: false) }
            return
        }
        guard permissions.micGranted else {
            gesture.runEnded()
            flagSetup()
            return
        }
        isPreparingModels = true
        defer { isPreparingModels = false }
        do {
            try await modelAdmission.admit(
                isIdle: { self.activeRun == nil && self.phase == .idle },
                canStart: { !self.resolvingEngine },
                prepare: { try await self.prepareSelectedResources() },
                operation: { await self.startPreparedRun() })
        } catch is CancellationError {
            gesture.runEnded()
        } catch ModelAdmission.AdmissionError.busy {
            gesture.runEnded()
        } catch DictationError.assetsNotInstalled {
            gesture.runEnded()
            flagSetup()
        } catch {
            gesture.runEnded()
            hud.show(toast: "Could not prepare selected models: \(error.localizedDescription)")
        }
    }

    /// Called only after resource admission rechecks the selection state.
    private func startPreparedRun() async {
        rebuildSessionIfStale()

        let target: AXTextTarget?
        var secureField = false
        switch AXTextTarget.captureFocused() {
        case .target(let focused): target = focused
        case .none: target = nil
        case .secure:
            target = nil
            secureField = true
        }
        let delivery = settings.cleanupEnabled ? settings.cleanupDelivery : nil
        let fieldEdit = makeFieldEditRun(target: target, delivery: delivery)
        let writer = FieldWriter(target: target, mode: settings.insertionMode, channel: fieldEdit?.channel)
        fieldEdit?.attach(writer: writer)
        let run = Run(
            writer: writer,
            fieldEdit: fieldEdit,
            targetPID: NSWorkspace.shared.frontmostApplication?.processIdentifier,
            secureField: secureField,
            delivery: delivery)
        activeRun = run
        phase = .preparing
        hud.beginRun()
        agentGate.agentRuns = fieldEdit?.agentRuns ?? false
        do {
            // The agent knows the field before the run's first text lands; it never holds the microphone back.
            fieldEdit?.start()
            try await session.start()
        } catch {
            agentGate.agentRuns = false
            fieldEdit?.cancel()
            activeRun = nil
            phase = .idle
            gesture.runEnded()
            if case DictationError.assetsNotInstalled = error {
                hud.endRun()
                Task { await refreshEngine() } // a picked model may have gone: fall back, check Apple's assets
                flagSetup()
            } else if case DictationError.cancelled = error {
                hud.endRun()
            } else {
                Self.log.error("start failed: \(Self.describe(error), privacy: .public)")
                hud.endRun(toast: "Could not start: \(error.localizedDescription)")
            }
            return
        }
        phase = .listening
        hud.setPhase(.listening)
    }

    /// The run's edit queue for the focused field. With cleanup on it also gets the cleanup agent on the warm
    /// rolling session (Live: sentence by sentence; Replace: the whole text at stop), so the session runs no cleanup
    /// of its own. The agent is made in the background (its session may still be warming; the microphone never
    /// waits for it): when there turns out to be no rolling session the stop rewrites the text on it once it is
    /// there, or the text stays as heard. Nil when there is no field to write into or it cannot be read: the run
    /// writes directly and the session's rewrite at stop cleans it.
    private func makeFieldEditRun(target: AXTextTarget?, delivery: CleanupDelivery?) -> FieldEditRun? {
        guard let target else { return nil }
        let owner = UUID().uuidString
        var runAgent: FieldRunAgent?
        var agentWait: TimeInterval = 2
        let nudge = RunNudge()
        // Insert-on-stop types nothing while listening: there is nothing for the agent to edit, so the session's
        // rewrite at stop cleans the text before it goes in.
        if delivery != nil, settings.cleanupEnabled, settings.insertionMode != .insertOnStop {
            let options = settings.cleanupStore.options
            agentWait = 2 // as on iOS: the stop must not wait long for an agent that is still warming (#80)
            let locale = ModelServices.singleLocale(models.engineSettings) ?? Locale.current
            let models = models, vocabulary = vocabulary
            runAgent = FieldRunAgent(deferred: {
                guard let rolling = await models.rollingDictationSession(options: options) else { return nil }
                let agent = CleanupAgent(
                    session: rolling, options: .init(options, owner: owner, locale: locale), vocabulary: vocabulary,
                    wake: { await nudge.wake() })
                return FieldRunAgent(
                    agent, tentative: { await agent.setTentative(length: $0) }, replan: { await agent.replan() },
                    finish: { await agent.finish() })
            })
        }
        let run = FieldEditRun(target: target, owner: owner, agent: runAgent, activity: target.activitySource(), agentWait: agentWait)
        nudge.run = run
        return run
    }

    /// Ends the run. `discard` is the chord cancel: nothing is delivered and nothing is saved.
    private func finishRun(discard: Bool) async {
        guard let run = activeRun, phase == .listening || phase == .preparing else { return }
        phase = .finishing
        hud.setPhase(.finishing)

        var entry: DictationEntry?
        var failure: (any Error)?
        do {
            entry = try await session.stop()
        } catch {
            failure = error
        }

        if discard {
            run.fieldEdit?.cancel() // the agent stops before the writer takes its text back
            if let entry { try? await history.delete(id: entry.id) }
            // Cancelled with no text kept: take back what was typed, if it is provably still ours.
            let toast = run.writer.revert() == .leftInPlace
                ? "Cancelled. Text already typed was left in place."
                : nil
            conclude(run, toast: toast)
            return
        }
        // `session.stop()` has yielded every edit; let the pump hand them to the writer. They carry the
        // engine's (raw) text, not the cleaned one.
        await drainEdits(of: run, expecting: entry.map { $0.rawText ?? $0.text })

        if let failure {
            Self.log.error("stop failed: \(Self.describe(failure), privacy: .public)")
            await deliver(run, finalText: nil, salvage: true, notice: "Dictation stopped early.")
        } else if let entry, let raw = entry.rawText {
            await deliver(run, finalText: entry.text, cleanedFrom: raw, entry: entry)
        } else {
            await deliver(run, finalText: entry?.text ?? "", salvage: false, notice: nil, entry: entry)
        }
    }

    /// The engine ended the run by itself (`onRunAborted`; the session is already torn down): deliver
    /// what was heard. A stop or cancel that was queued first has already ended the run, so this is a no-op then.
    private func abortRun(id: UUID) async {
        guard let run = activeRun, run.id == id, phase == .listening else { return }
        phase = .finishing
        hud.setPhase(.finishing)
        gesture.runEnded()
        if let error = session.lastError { Self.log.error("run aborted: \(Self.describe(error), privacy: .public)") }
        await drainEdits(of: run, expecting: nil)
        await deliver(run, finalText: nil, salvage: true, notice: "Dictation stopped early.")
    }

    /// Finishes the writer and routes whatever the field is missing.
    /// `salvage`: the session did not save an entry (it aborted), so its `partialEntry()` goes to history.
    /// `cleanedFrom`: cleanup changed the text; `finalText` is the cleaned text and this the raw one that
    /// streamed into the field, delivered per the run's cleanup delivery.
    private func deliver(
        _ run: Run, finalText: String?, cleanedFrom raw: String? = nil, salvage: Bool = false, notice: String? = nil,
        entry: DictationEntry? = nil
    ) async {
        var action: FinishAction
        var delivery: CleanupDelivery?
        var entry = entry
        // The cleaned text of an agent run, for its history entry.
        var agentText: String?
        if let fieldEdit = run.fieldEdit, fieldEdit.agentRuns {
            // The cleanup agent cleaned this run: its final pass, then what the field holds is the result. An
            // edit that did not land keeps its cleaned text for the clipboard.
            delivery = run.delivery ?? .live
            let outcome = await fieldEdit.finish()
            if outcome.agentAbsent, let raw = entry?.text {
                // No agent (no rolling session, or still warming): the whole text rewritten on the rolling session,
                // written as patches.
                var cleaned: String?
                let options = settings.cleanupStore.options, models = models, vocabulary = vocabulary
                action = await fieldEdit.deliverWithoutAgent(raw: raw, clean: {
                    cleaned = await models.rollingRewrite($0, options: options, vocabulary: vocabulary)
                    return cleaned
                })
                // Whatever way the cleaned text reached the user (patches, clipboard, paste), history holds it.
                if action != .done, let text = cleaned?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                    agentText = text
                }
            } else {
                action = run.writer.finish(finalText: nil)
            }
            if action == .done {
                agentText = run.writer.shownText
                if !outcome.unapplied.isEmpty {
                    let text = fieldEdit.clipboardText(unapplied: outcome.unapplied)
                    action = .copy(text)
                    agentText = text
                }
            }
        } else if let raw, let cleaned = finalText {
            let chosen = run.delivery ?? settings.cleanupDelivery
            delivery = chosen
            if let fieldEdit = run.fieldEdit {
                // A final swap held back by typing waits for a pause (a little) before it gives up.
                action = await run.writer.finish(
                    rawText: raw, cleanedText: cleaned, retryingFor: FieldEditRun.finalHoldBudget,
                    wait: { await fieldEdit.wait($0) })
            } else {
                action = run.writer.finish(rawText: raw, cleanedText: cleaned)
            }
        } else {
            action = run.writer.finish(finalText: finalText)
        }
        var toast = notice
        func note(_ message: String) { toast = notice.map { "\($0) \(message)" } ?? message }
        switch action {
        case .done:
            break
        case .copy(let rest):
            paster.copy(rest)
            switch delivery {
            case nil: note("Copied the rest — paste with ⌘V.")
            case .replace, .live: note("The field changed: cleaned text copied — paste with ⌘V.")
            }
        case .paste(let full):
            let outcome = await paster.paste(
                full,
                restoreClipboard: settings.restoreClipboard,
                targetPID: run.targetPID,
                secureField: run.secureField)
            if case .copied(let reason) = outcome { note(reason.toast) }
        }
        if salvage, let entry = session.partialEntry() {
            try? await history.append(entry) // the session never saved this run; losing the copy is worse
        }
        if let saved = entry, let agentText {
            // The session saved the engine's text; the history holds what the field got, with the raw text kept.
            entry = await AgentRunHistory.replace(saved, cleaned: agentText, in: history)
        }
        if let entry {
            lastDictation = entry
            lastWriter = run.writer
        }
        conclude(run, toast: toast)
    }

    /// Errors are logged by type and code only: their descriptions could echo dictated text.
    private static func describe(_ error: any Error) -> String {
        let ns = error as NSError
        return "\(type(of: error)) \(ns.domain) \(ns.code)"
    }

    private func conclude(_ run: Run, toast: String?) {
        run.fieldEdit?.cancel()
        agentGate.agentRuns = false
        activeRun = nil
        phase = .idle
        hud.endRun(toast: toast)
        Task { await refreshRecent() }
    }

    /// Waits (briefly) until the pump has applied the run's last edits to the writer: its last commit
    /// when the final text is known, else every edit the session has published.
    private func drainEdits(of run: Run, expecting text: String?) async {
        var tries = 0
        while tries < 50 {
            let caughtUp = text.map { run.committed.trimmingCharacters(in: .whitespacesAndNewlines) == $0 }
                ?? (appliedEdits >= session.editCount)
            if caughtUp { return }
            try? await Task.sleep(for: .milliseconds(10))
            tries += 1
        }
    }

    // MARK: Edits

    private func apply(_ edit: TranscriptEdit) {
        appliedEdits += 1
        guard let run = activeRun else { return }
        run.writer.apply(edit)
        run.fieldEdit?.textChanged()
        run.transcript.apply(edit)
        switch edit {
        case .commit:
            hud.model.committed = run.transcript.committed
        case .replaceVolatile(let text):
            hud.model.volatile = text
        }
    }

    #if DEBUG
    // MARK: Meeting self-test

    private struct SelfTestArguments {
        var seconds: Double
        var out: URL
        var includeText: Bool
    }

    /// `--meeting-selftest <seconds> [--meeting-selftest-out=<json path>] [--meeting-selftest-text]`.
    private static func meetingSelfTestArguments() -> SelfTestArguments? {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: "--meeting-selftest") else { return nil }
        let seconds = args.dropFirst(index + 1).first.flatMap(Double.init) ?? 15
        let out = args.first { $0.hasPrefix("--meeting-selftest-out=") }
            .map { URL(fileURLWithPath: String($0.dropFirst("--meeting-selftest-out=".count))) }
            ?? URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "legato-meeting-selftest/selftest.json")
        return SelfTestArguments(seconds: seconds, out: out, includeText: args.contains("--meeting-selftest-text"))
    }

    /// A throwaway meeting against its own store next to the JSON, so the user's meetings stay untouched.
    private func runMeetingSelfTest(_ arguments: SelfTestArguments) {
        let root = arguments.out.deletingLastPathComponent().appending(path: "store", directoryHint: .isDirectory)
        let tester = MeetingController(models: models, root: root)
        selfTestController = tester
        Task { await tester.runSelfTest(seconds: arguments.seconds, out: arguments.out, includeText: arguments.includeText) }
    }
    #endif
}

/// Lets the cleanup agent's pause wake reach the run's edit queue wiring (the agent is made before the run is).
private final class RunNudge: @unchecked Sendable {
    @MainActor weak var run: FieldEditRun?
    func wake() async { await MainActor.run { run?.nudge() } }
}
