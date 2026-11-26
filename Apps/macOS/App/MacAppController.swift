import AppKit
import LegatoAppServices
import LegatoAgent
import LegatoCore
import LegatoMac
import LegatoVocabulary
import LegatoAudio
import LegatoKeyboardCore
import Observation
import OSLog

@MainActor @Observable final class MacAppController {
    static let shared = MacAppController()
    static let onboardingWindowID = "onboarding"
    let settings = MacSettings()
    let permissions = Permissions()
    let hud = HUDPanelController()
    let paster = PasteService()
    let vocabulary: VocabularyService
    let history: any HistoryStore
    let corrections: CorrectionStore
    var recent: [DictationEntry] = []
    let meetings: MeetingController
    private var meetingIsland: MeetingIslandController?
    private var callDetection: CallDetectionController?
    let dictation: MacDictationSession
    @ObservationIgnored private let destination = ComposerDestination()
    @ObservationIgnored private var secureDraftOrigin: AXTextTarget.PasteWitness?
    private var dictationPill: DictationPillController?
    private var magicTask: Task<Void, Never>?
    private var keyboardInstruction = false
    @ObservationIgnored private var magicGeneration = 0
    var notice: String { dictation.notice ?? (dictation.speechMode == .instruction ? "Magic" : dictation.phase.rawValue.capitalized) }
    var isDictating: Bool { dictation.isActive }
    enum HotkeyTarget: Equatable {
        case magic, dictation, composer(MacComposerShortcut)

        var title: String {
            switch self {
            case .magic: "Magic"
            case .dictation: "Dictation"
            case .composer(let action): action.actionTitle
            }
        }
        @MainActor var defaultBinding: HotkeySpec {
            switch self {
            case .magic: MacComposerShortcut.magic.defaultBinding
            case .dictation: MacSettings.defaultDictationHotkey
            case .composer(let action): action.defaultBinding
            }
        }
        static var all: [Self] { [.magic, .dictation] + MacComposerShortcut.chordActions.map { .composer($0) } }
    }
    private(set) var recordingTarget: HotkeyTarget? {
        didSet { tap.setRecording(recordingTarget != nil || recordedKey != nil) }
    }
    private var recordedKey: UInt16? {
        didSet { tap.setRecording(recordingTarget != nil || recordedKey != nil) }
    }
    var isRecordingHotkey: Bool { recordingTarget != nil }
    var recordingPreview: String?
    var onboardingRequests = 0
    var setupAttention: Bool { !permissions.accessibility || settings.dictationHotkey == nil || settings.hotkey == nil }
    #if DEBUG
    private let hotkeysEnabled = !UserDefaults.standard.bool(forKey: "LegatoDisableHotkeys")
    #else
    private let hotkeysEnabled = true
    #endif
    private let tap = HotkeyTap()
    private var recorder = HotkeyRecorderLogic()
    private let magicGesture = GestureDriver(gesture: .magic)
    private let dictationGesture = GestureDriver()
    @ObservationIgnored private var recordingMonitor: Any?
    @ObservationIgnored private var recordingResignObserver: NSObjectProtocol?
    private var eventTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
    private var bootstrapped = false
    @ObservationIgnored private var focusObserver: NSObjectProtocol?
    @ObservationIgnored private var terminateObserver: NSObjectProtocol?
    @ObservationIgnored private var mouseMonitor: Any?

    private init() {
        var root = URL.applicationSupportDirectory.appending(path: "Legato", directoryHint: .isDirectory)
        #if LEGATO_INTERNAL
        if let path = UserDefaults.standard.string(forKey: "LegatoDataRoot"), path.hasPrefix("/") {
            root = URL(fileURLWithPath: path, isDirectory: true)
        }
        #endif
        let engine = EngineSettings()
        vocabulary = VocabularyService(fileURL: root.appending(path: "vocabulary.json"),
            languages: { VocabularyService.configuredLanguages(engine) })
        corrections = CorrectionStore(root: root)
        let recentTakes = RecentTakesStore(fileURL: root.appending(path: "recent-takes.json"))
        history = LearningHistoryStore(JSONLHistoryStore(fileURL: root.appending(path: "history.jsonl")), vocabulary: vocabulary, recentTakes: recentTakes)
        let vocabularyURL = root.appending(path: "vocabulary.json")
        meetings = MeetingController(root: Self.meetingsRoot(in: root), vocabularyURL: vocabularyURL)
        let pipeline: DictationPipeline
        let instruction: InstructionSession
        #if LEGATO_INTERNAL
        let offlineFixture = UserDefaults.standard.bool(forKey: "LegatoOfflineFixture")
        if offlineFixture {
            pipeline = DictationPipeline(recentTakes: recentTakes,
                history: history, cleaner: DebugStreamingCleaner(chunkMilliseconds: 0),
                sendMode: { DictationSendSetting.mode() }, supportsLive: true, groupsLiveHistory: true)
            instruction = InstructionSession(runner: MacOfflineInstructionRunner(), history: history)
        } else {
            pipeline = DictationPipeline(vocabularyURL: vocabularyURL, recentTakes: recentTakes, history: history, supportsLive: true, groupsLiveHistory: true)
            instruction = InstructionSession(vocabularyURL: vocabularyURL, history: history)
        }
        #else
        pipeline = DictationPipeline(vocabularyURL: vocabularyURL, recentTakes: recentTakes, history: history, supportsLive: true, groupsLiveHistory: true)
        instruction = InstructionSession(vocabularyURL: vocabularyURL, history: history)
        #endif
        dictation = MacDictationSession(pipeline: pipeline, instruction: instruction,
            microphone: AutomaticInputSource(preference: { MicrophonePreference.dictation() }),
            vocabularyURL: vocabularyURL, composer: MacComposerDraft())
        dictation.onPrepare = { [weak self] in
            guard let self else { return }
            let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier
            let input = RealInput.shared.count
            let witness = AXTextTarget.capturePasteWitness()
            secureDraftOrigin = witness.isPassword ? witness : nil
            dictationPill?.captureAnchor(witness)
            if case .unreadable = witness {
                await AXTextTarget.prepareFocused()
                guard pid == NSWorkspace.shared.frontmostApplication?.processIdentifier,
                      input == RealInput.shared.count else { return }
                let prepared = AXTextTarget.capturePasteWitness()
                if prepared.isPassword { secureDraftOrigin = prepared }
                dictationPill?.captureAnchor(prepared)
            }
        }
        dictation.onResumeDraft = { [weak self] in
            guard let self, secureDraftOrigin == nil else { return }
            let witness = AXTextTarget.capturePasteWitness()
            if witness.isPassword { secureDraftOrigin = witness }
        }
        dictation.prepareDraftInsertion = { [weak self] in
            guard let self else { return .init { _ in false } }
            return destination.captureInsertion(secureOrigin: secureDraftOrigin, using: paster, settings: settings, store: corrections) { [weak self] in
                guard let draft = self?.dictation.composer else { return nil }
                return (draft.documentID, draft.original)
            }
        }
        pipeline.keepsTakes = { [weak self] in self?.secureDraftOrigin == nil }
    }
    private static func meetingsRoot(in root: URL) -> URL {
        #if LEGATO_INTERNAL
        if let path = UserDefaults.standard.string(forKey: "LegatoMeetingsRoot") {
            return URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
        }
        #endif
        return root.appending(path: "Meetings", directoryHint: .isDirectory)
    }
    func bootstrap() {
        guard !bootstrapped else { return }; bootstrapped = true
        focusObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let pid = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
            MainActor.assumeIsolated {
                guard let self, pid != self.destination.pid else { return }
                self.destination.invalidate()
            }
            // A Chromium app builds its tree in about a second: ask for it now, before a dictation needs it.
            if let pid { Task { @MainActor in AXTextTarget.requestTree(pid: pid) } }
        }
        terminateObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { note in
            guard let pid = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier else { return }
            Task { @MainActor in AXTextTarget.forget(pid: pid) }
        }
        if let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier { AXTextTarget.requestTree(pid: pid) }
        // Only after launch: a global monitor added before `NSApp` exists cuts the process off from every mouse event.
        assert(NSApp != nil, "Install event monitors after applicationDidFinishLaunching")
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            // The tap counts host clicks synchronously and excludes the activity's buttons.
            Task { @MainActor in
                guard let self, !self.tap.isEnabled else { return }
                self.destination.invalidate()
            }
        }
        // Capture inside the active Settings window and consume the event before AppKit
        // can run its menu equivalent (e.g. Command-W). The tap marks this same event so
        // the newly recorded binding cannot fire as soon as Settings finishes recording.
        recordingMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { [weak self] event in
            self?.recordLocalEvent(event) == true ? nil : event
        }
        recordingResignObserver = NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification,
            object: NSApp, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.cancelRecording(); self?.recordedKey = nil }
            }
        permissions.hotkeyTapActive = hotkeysEnabled && tap.start()
        dictationPill = DictationPillController(session: dictation, settings: settings, actions: DictationPillActions(
            magic: { [weak self] in self?.perform(.magic) },
            instruction: { [weak self] in self?.toggleMagic() },
            dictation: { [weak self] in self?.toggleDictation() },
            insert: { [weak self] in self?.perform(.insert) },
            discard: { [weak self] in self?.perform(.discard) }))
        observeComposerShortcuts()
        dictation.ensureWarm()
        meetingIsland = MeetingIslandController(controller: meetings)
        meetings.bootstrap()
        callDetection = CallDetectionController(
            meetings: meetings,
            busy: { [weak self] in
                guard let self else { return true }
                return dictation.isActive
            },
            startMeeting: { [weak self] automatically in self?.beginMeeting(automatically: automatically) })
        Task {
            await refreshRecent()
        }
        eventTask = Task { for await sample in tap.samples { handle(sample) } }
        pollTask = Task {
            while !Task.isCancelled {
                permissions.refresh()
                if settings.dictationHotkey != nil { dictation.ensureWarm() }
                if !tap.isEnabled {
                    tap.stop()
                    permissions.hotkeyTapActive = false
                    if CGPreflightListenEventAccess() { permissions.hotkeyTapActive = hotkeysEnabled && tap.start() }
                } else {
                    permissions.hotkeyTapActive = true
                }
                try? await Task.sleep(for: .seconds(2))
            }
        }
        #if LEGATO_INTERNAL
        DebugBridge.start()
        MeetingsPreview.runIfRequested(meetings)
        #endif
    }
    private func perform(_ action: MacComposerShortcut) {
        let finishingInstruction = magicTask
        let insertion = action == .insert ? dictation.insertDraft(after: finishingInstruction) : nil
        Task {
            switch action {
            case .magic:
                await finishingInstruction?.value
                await dictation.magicDraft()
            case .insert: await insertion?.value
            case .discard: await dictation.discardDraft()
            }
            if !dictation.isActive { dictationGesture.runEnded() }
        }
    }
    /// The tap needs a synchronous snapshot of activity ownership to decide whether an event reaches the host.
    private func observeComposerShortcuts() {
        let scope: ActivityShortcutScope? = withObservationTracking {
            guard hotkeysEnabled, dictation.isActivityInteractive else { return nil }
            var bindings: [MacComposerShortcut: HotkeySpec] = [:]
            for action in MacComposerShortcut.chordActions { bindings[action] = settings.binding(for: action) }
            return ActivityShortcutScope(composer: bindings, speech: [settings.hotkey, settings.dictationHotkey].compactMap { $0 })
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeComposerShortcuts() }
        }
        tap.setScope(scope)
    }

    func toggleMagic() {
        if dictation.speechMode == .instruction { stopMagic() } else { startMagic() }
    }
    private func startMagic(fromKeyboard: Bool = false) {
        guard MacComposerShortcut.magic.isAvailable(in: dictation), !refusedByMeeting(), microphoneReady() else { return }
        magicGeneration &+= 1
        let generation = magicGeneration, previous = magicTask
        keyboardInstruction = fromKeyboard
        magicTask = Task {
            await previous?.value
            let started = await dictation.startMagic()
            guard magicGeneration == generation else { return }
            magicTask = nil
            if !started {
                keyboardInstruction = false
                magicGesture.runEnded()
            }
        }
    }
    private func stopMagic(discard: Bool = false) {
        magicGeneration &+= 1
        let starting = magicTask, generation = magicGeneration
        magicTask = Task {
            await starting?.value
            await dictation.endMagic(discard: discard)
            guard magicGeneration == generation else { return }
            keyboardInstruction = false
            magicTask = nil
        }
    }
    func instructionAction(_ action: InstructionIntent.Action) {
        dictation.instruction.handle(.init(action: action, instructionID: dictation.instruction.strip.instructionID))
    }
    private func microphoneReady() -> Bool {
        if MacDictationSession.offlineFixture { return true }
        switch permissions.mic {
        case .granted: return true
        case .undetermined:
            Task { await permissions.requestMicrophone() }
            dictationPill?.show(notice: "Allow microphone access, then press the shortcut again.")
        case .denied:
            dictationPill?.show(notice: "Microphone access is off. Allow Legato in System Settings, Privacy & Security.")
        }
        return false
    }
    func binding(for target: HotkeyTarget) -> HotkeySpec? {
        switch target {
        case .dictation: settings.dictationHotkey
        case .magic: settings.hotkey
        case .composer(let action): settings.binding(for: action)
        }
    }
    private func setBinding(_ spec: HotkeySpec?, for target: HotkeyTarget) {
        switch target {
        case .dictation: settings.dictationHotkey = spec
        case .magic: settings.hotkey = spec
        case .composer(let action): settings.setBinding(spec, for: action)
        }
    }
    func clearBinding(for target: HotkeyTarget) {
        resetGestures()
        setBinding(nil, for: target)
        cancelRecording()
    }
    func restoreDefault(for target: HotkeyTarget) {
        resetGestures()
        if accept(target.defaultBinding, for: target), case .composer(let action) = target {
            settings.resetBinding(for: action)
        }
    }
    @discardableResult private func accept(_ spec: HotkeySpec, for target: HotkeyTarget) -> Bool {
        let error: String?
        if case .composer(let action) = target, !action.accepts(spec) {
            error = "Press an arrow key, a function key, or a key combination."
        } else if let used = HotkeyTarget.all.first(where: { $0 != target && binding(for: $0)?.conflicts(with: spec) == true }) {
            error = "Already used by the " + used.title + " shortcut."
        } else {
            error = nil
        }
        if let error {
            recordingTarget = target
            recordingPreview = error
            recorder = makeRecorder(for: target)
            return false
        }
        setBinding(spec, for: target)
        cancelRecording()
        return true
    }
    private func resetGestures() {
        if keyboardInstruction { stopMagic(discard: true) }
        magicGesture.reset()
        dictationGesture.reset()
    }
    func beginRecording(_ target: HotkeyTarget = .magic) {
        guard tap.isActive else { permissions.requestAccessibility(); return }
        resetGestures()
        recorder = makeRecorder(for: target); recordingTarget = target; recordingPreview = nil
    }
    private func makeRecorder(for target: HotkeyTarget) -> HotkeyRecorderLogic {
        if case .composer = target { return HotkeyRecorderLogic(allowsBareArrows: true) }
        return HotkeyRecorderLogic()
    }
    func cancelRecording() { recordingTarget = nil; recordingPreview = nil }
    private func recordLocalEvent(_ event: NSEvent) -> Bool {
        if event.keyCode == recordedKey {
            if event.type == .keyUp { recordedKey = nil }
            return true
        }
        guard let target = recordingTarget else { return false }
        let kind: KeyEvent.Kind = event.type == .keyDown ? .keyDown : event.type == .keyUp ? .keyUp : .flagsChanged
        let input = KeyEvent(kind: kind, keyCode: event.keyCode, flags: ModifierFlags(rawValue: event.modifierFlags.rawValue))
        switch recorder.feed(input) {
        case .none: break
        case .preview(let text): recordingPreview = text
        case .captured(let spec):
            if event.type == .keyDown { recordedKey = event.keyCode }
            accept(spec, for: target)
        case .cancelled: cancelRecording()
        }
        return true
    }
    private func handle(_ sample: TapSample) {
        guard let event = sample.event else {
            destination.invalidate()
            resetGestures()
            return
        }
        guard !sample.isRecordingBinding, recordingTarget == nil else { return }
        if let action = sample.composerAction {
            guard action.isAvailable(in: dictation, duringMagicHold: keyboardInstruction) else { return }
            magicGesture.spoil { self.dispatch($0) }
            perform(action)
            return
        }
        if event.kind == .keyDown {
            let shortcut = sample.isCaptured || settings.hotkey?.triggerEvent(for: event) == .pressed || settings.dictationHotkey?.triggerEvent(for: event) == .pressed
            if !shortcut {
                if dictation.instruction.strip.phase == .result || dictation.instruction.strip.phase == .undone { instructionAction(.accept) }
            }
        }
        if let trigger = settings.hotkey?.triggerEvent(for: event) {
            magicGesture.feed(trigger, at: sample.time, mode: .hold) { [weak self] in self?.dispatch($0) }
        }
        if let trigger = settings.dictationHotkey?.triggerEvent(for: event) {
            dictationGesture.feed(trigger, at: sample.time, mode: settings.gestureMode) { [weak self] in self?.dispatchDictation($0) }
        }
    }
    private func dispatchDictation(_ action: HotkeyGesture.Action?) {
        // A held trigger stops listening on release. Draft actions are separate.
        defer { dictation.setHeld(dictationGesture.gesture.isHolding && action != .cancel) }
        switch action {
        case .start: startDictation()
        case .stop: stopDictation()
        case .cancel: cancelDictation()
        case .tap, nil: break
        }
    }
    /// The dictation hotkey (or the debug bridge) starts a session when idle and stops a running one.
    func toggleDictation() {
        switch dictation.phase {
        case .idle: startDictation(fromControl: true)
        case .starting, .listening: stopDictation()
        case .finishing: break
        }
    }
    private func startDictation(fromControl: Bool = false) {
        guard !dictation.isActive else { return }
        guard !refusedByMeeting() else { dictationGesture.runEnded(); return }
        guard microphoneReady() else { dictationGesture.runEnded(); return }
        if fromControl { dictationGesture.latchExternalRun(mode: settings.gestureMode) }
        Task { if await !dictation.start() { dictationGesture.runEnded() } }
    }
    /// Starts a meeting, or stops the one that records. A meeting and a dictation never share the microphone.
    func toggleMeeting() {
        switch meetings.phase {
        case .recording: meetings.stop()
        case .idle: beginMeeting(automatically: false)
        case .starting, .stopping: break
        }
    }
    /// Starts a meeting if none runs. Call detection starts one `automatically`, which only says so in a notice and
    /// never opens the microphone permission dialog by itself.
    func beginMeeting(automatically: Bool) {
        guard meetings.phase == .idle else { return }
        switch permissions.mic {
        case .granted: meetings.start(dictationActive: dictation.isActive, automatically: automatically)
        case .undetermined:
            if !automatically { Task { await permissions.requestMicrophone() } }
            meetings.flash("Allow microphone access, then start the meeting again.")
        case .denied:
            meetings.flash("Microphone access is off. Allow Legato in System Settings, Privacy & Security.")
        }
    }
    /// While a meeting records, dictation and Magic say so and do not start.
    private func refusedByMeeting() -> Bool {
        guard let refusal = meetings.refusal else { return false }
        meetings.flash("\(refusal). Stop it to dictate or use Magic.")
        return true
    }
    private func stopDictation() { Task { await dictation.stop(); dictationGesture.runEnded() } }
    private func cancelDictation() { Task { await dictation.cancel(); dictationGesture.runEnded() } }
    private func dispatch(_ action: HotkeyGesture.Action?) {
        switch action {
        case .tap: perform(.magic)
        case .start: startMagic(fromKeyboard: true)
        case .stop: if keyboardInstruction { stopMagic() }
        case .cancel: if keyboardInstruction { stopMagic(discard: true) }
        case nil: break
        }
    }
    func undoDiscard() {
        guard dictation.canUndoDiscard else { return }
        dictation.undoDiscard()
    }

    func refreshRecent() async { recent = (try? await history.recent(limit: 20)) ?? [] }
    func copy(_ entry: DictationEntry) { paster.copy(entry.displayText) }
    func delete(_ entry: DictationEntry) { Task { try? await history.delete(id: entry.id); await refreshRecent() } }
}

/// Counts real key presses, readable from the dictation writer's closures.
/// One hotkey's `HotkeyGesture` plus the timer that starts a held press.
@MainActor private final class GestureDriver {
    private(set) var gesture: HotkeyGesture
    init(gesture: HotkeyGesture = HotkeyGesture()) { self.gesture = gesture }
    private var armTask: Task<Void, Never>?

    func feed(_ trigger: TriggerEvent, at time: TimeInterval, mode: HotkeyGesture.Mode,
              dispatch: @escaping @MainActor (HotkeyGesture.Action?) -> Void) {
        if gesture.mode != mode { gesture = HotkeyGesture(mode: mode) }
        dispatch(gesture.tick(at: time))
        switch trigger {
        case .pressed: dispatch(gesture.pressed(at: time))
        case .released: dispatch(gesture.released(at: time))
        case .otherKeyDown: dispatch(gesture.otherKeyDown())
        }
        armTask?.cancel(); armTask = nil
        guard let deadline = gesture.armDeadline else { return }
        armTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0, deadline - ProcessInfo.processInfo.systemUptime)))
            guard !Task.isCancelled, let self else { return }
            dispatch(gesture.tick(at: ProcessInfo.processInfo.systemUptime))
        }
    }
    func spoil(dispatch: (HotkeyGesture.Action?) -> Void) {
        armTask?.cancel()
        dispatch(gesture.otherKeyDown())
    }
    func reset() { armTask?.cancel(); armTask = nil; gesture.reset() }
    func latchExternalRun(mode: HotkeyGesture.Mode) {
        if gesture.mode != mode { gesture = HotkeyGesture(mode: mode) }
        gesture.latchExternalRun()
    }
    func runEnded() { gesture.runEnded() }
}

/// Revokes an accepted insertion when the user leaves its editor or begins another insertion.
@MainActor private final class ComposerDestination {
    private static let log = Logger(subsystem: "de.gruenwald.legato", category: "MacComposerDelivery")
    private(set) var pid: pid_t?
    private var generation = 0

    private var correctionPoll: Task<Void, Never>?
    func invalidate() {
        generation &+= 1
        correctionPoll?.cancel()
        correctionPoll = nil
    }

    func captureInsertion(secureOrigin: AXTextTarget.PasteWitness?, using paster: PasteService,
                          settings: MacSettings, store: CorrectionStore,
                          source: @escaping @MainActor () -> (UUID, String)?) -> MacDictationSession.DraftInsertion {
        invalidate()
        let generation = self.generation
        let input = RealInput.shared.count
        let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier
        self.pid = pid

        let witness = AXTextTarget.capturePasteWitness()
        let isPrivate = secureOrigin != nil || witness.isPassword
        guard let pid, let start = witness.insertionStart(), start.pid == pid,
              secureOrigin.map({ witness.isSamePasswordField(as: $0) }) ?? true else {
            return .init(isPrivate: isPrivate) { _ in false }
        }

        let ownsInput: @MainActor @Sendable () -> Bool = {
            self.generation == generation && input == RealInput.shared.count
                && NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
        }
        return .init(isPrivate: isPrivate) { text in
            guard ownsInput() else { return false }
            let confirmation = start.confirmation(for: text)
            if isPrivate && confirmation == nil { return false }
            let owned: @MainActor @Sendable () -> Bool = {
                guard ownsInput() else { return false }
                let focused = confirmation?.stillFocused() ?? start.stillFocused()
                return focused && ownsInput()
            }
            let started = ContinuousClock.now
            let posted = await paster.insert(text, targetPID: pid, passwordField: isPrivate,
                restoreClipboard: settings.restoreClipboard,
                paced: settings.typewriter && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
                canBegin: { ownsInput() && start.matchesInitialPosition() && ownsInput() }, stillOwned: owned)
            Self.log.debug("Draft events posted: \(posted), elapsed: \(String(describing: started.duration(to: .now)), privacy: .public)")
            if posted, let confirmation {
                let take = isPrivate ? nil : source()
                Task { @MainActor in
                    let verified = await confirmation.verify(whileOwned: owned)
                    Self.log.debug("Draft readback verified: \(verified)")
                    if verified, generation == self.generation, let take, case .element(let target) = witness,
                       let snapshot = target.correctionSnapshot() {
                        let capture = CorrectionCapture(store: store)
                        guard capture.arm(dictationID: take.0.uuidString, raw: take.1, inserted: text,
                                          snapshot: snapshot, platform: "macOS", locale: Locale.current.identifier, isIdle: true) else { return }
                        self.correctionPoll = Task { @MainActor in
                            while !Task.isCancelled && capture.isObserving {
                                try? await Task.sleep(for: .milliseconds(200))
                                guard !Task.isCancelled, let current = target.correctionSnapshot() else { return }
                                capture.observeSettled(current)
                            }
                        }
                    }
                }
            }
            return posted
        }
    }
}
