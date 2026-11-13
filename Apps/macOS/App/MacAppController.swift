import AppKit
import LegatoAppServices
import LegatoAgent
import LegatoCore
import LegatoMac
import LegatoVocabulary
import LegatoAudio
import LegatoKeyboardCore
import Observation

@MainActor @Observable final class MacAppController {
    static let shared = MacAppController()
    static let onboardingWindowID = "onboarding"
    let settings = MacSettings()
    let permissions = Permissions()
    let hud = HUDPanelController()
    let paster = PasteService()
    let vocabulary: VocabularyService
    let history: any HistoryStore
    var recent: [DictationEntry] = []
    let meetings: MeetingController
    private var meetingIsland: MeetingIslandController?
    private var callDetection: CallDetectionController?
    let dictation: MacDictationSession
    let fieldEditor: MacFieldEditor
    @ObservationIgnored private let fallbackOwner = MacFallbackOwner()
    private var dictationPill: DictationPillController?
    private var magicTask: Task<Void, Never>?
    var notice: String { dictation.notice ?? (dictation.speechMode == .instruction ? "Magic" : dictation.phase.rawValue.capitalized) }
    var isDictating: Bool { dictation.isActive }
    enum HotkeyTarget { case magic, dictation }
    private(set) var recordingTarget: HotkeyTarget?
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
    private let magicGesture = GestureDriver()
    private let dictationGesture = GestureDriver()
    private var eventTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
    private var bootstrapped = false
    @ObservationIgnored private var focusObserver: NSObjectProtocol?
    @ObservationIgnored private var terminateObserver: NSObjectProtocol?
    @ObservationIgnored private var mouseMonitor: Any?
    /// Real (untagged) key presses seen by the tap; typing into a paste-only app stops when this moves.
    let keyPresses = KeyPressCounter()

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
        history = LearningHistoryStore(JSONLHistoryStore(fileURL: root.appending(path: "history.jsonl")), vocabulary: vocabulary)
        let vocabularyURL = root.appending(path: "vocabulary.json")
        meetings = MeetingController(root: Self.meetingsRoot(in: root), vocabularyURL: vocabularyURL)
        let pipeline: DictationPipeline
        let instruction: InstructionSession
        #if LEGATO_INTERNAL
        let offlineFixture = UserDefaults.standard.bool(forKey: "LegatoOfflineFixture")
        if offlineFixture {
            pipeline = DictationPipeline(recentTakes: RecentTakesStore(fileURL: root.appending(path: "recent-takes.json")),
                history: history, cleaner: DebugStreamingCleaner(chunkMilliseconds: 0),
                sendMode: { DictationSendSetting.mode() }, supportsLive: true, groupsLiveHistory: true)
            instruction = InstructionSession(runner: MacOfflineInstructionRunner(), history: history)
        } else {
            pipeline = DictationPipeline(vocabularyURL: vocabularyURL, recentTakesURL: root.appending(path: "recent-takes.json"), history: history, supportsLive: true, groupsLiveHistory: true)
            instruction = InstructionSession(vocabularyURL: vocabularyURL, history: history)
        }
        #else
        pipeline = DictationPipeline(vocabularyURL: vocabularyURL, recentTakesURL: root.appending(path: "recent-takes.json"), history: history, supportsLive: true, groupsLiveHistory: true)
        instruction = InstructionSession(vocabularyURL: vocabularyURL, history: history)
        #endif
        dictation = MacDictationSession(pipeline: pipeline, instruction: instruction, microphone: AutomaticInputSource(preference: { MicrophonePreference.dictation() }), vocabularyURL: vocabularyURL)
        fieldEditor = MacFieldEditor(capture: { () -> FocusedField in
            #if DEBUG
            // Acceptance of the unreadable-field path in an app whose fields are readable.
            if UserDefaults.standard.bool(forKey: "LegatoDebugUnreadableField") { return .none }
            #endif
            switch AXTextTarget.captureFocused() {
            case .target(let target): return .target(target)
            case .none: return .none
            case .password: return .password
            }
        })
        fieldEditor.panelMode = { PanelDictationSetting.mode() }
        fieldEditor.insert = { [weak paster, settings, keyPresses, fallbackOwner] text in
            guard let paster else { return .retained(message: "Dictation is kept in the panel.") }
            let generation = fallbackOwner.generation, pid = fallbackOwner.pid, keys = fallbackOwner.keys
            let witness = fallbackOwner.witness
            // Same session, no click or real key since it started, the field (when readable) still focused.
            let owned = { @MainActor () -> Bool in
                guard fallbackOwner.generation == generation, fallbackOwner.allowed, keyPresses.count == keys,
                      let witness else { return false }
                return witness.stillFocused()
            }
            guard owned() else {
                return .retained(message: "The field or app changed. Dictation is kept in the panel.")
            }
            switch await paster.type(text, targetPID: pid, passwordField: witness?.isPassword == true, restoreClipboard: settings.restoreClipboard,
                                     paced: settings.typewriter && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
                                     realKeyDowns: { keyPresses.count }, stillOwned: owned) {
            case .typed: return .typed
            case .interrupted(let remainder): return .interrupted(remainder: remainder, message: "Typing stopped. The rest is kept in the panel.")
            case .unavailable(let reason):
                return .retained(message: reason == .appChanged ? "The field or app changed. Dictation is kept in the panel." : "Insertion is unavailable. Dictation is kept in the panel.")
            }
        }
        // Every change is typed a grapheme at a time; Reduce Motion (or the Typewriter setting off) sends it whole.
        fieldEditor.typewriter = { [settings] in settings.typewriter && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
        #if DEBUG || LEGATO_INTERNAL
        let journalFile = EditJournalFile()
        fieldEditor.journal = { journalFile.write($0) }
        #endif
        instruction.field = fieldEditor
        fieldEditor.report = { [weak dictation] in dictation?.report($0) }
        fieldEditor.recover = { [weak paster] in paster?.copy($0) }
        dictation.onBegin = { [weak self] in
            guard let self else { return }
            fallbackOwner.generation += 1
            fallbackOwner.pid = NSWorkspace.shared.frontmostApplication?.processIdentifier
            fallbackOwner.keys = keyPresses.count; fallbackOwner.allowed = true
            fallbackOwner.witness = AXTextTarget.capturePasteWitness()
            fieldEditor.begin()
        }
        dictation.onPrepare = { await AXTextTarget.prepareFocused() }
        dictation.onEnd = { [weak fieldEditor] in await fieldEditor?.finish() }
        dictation.onMagicBegin = { [weak fieldEditor] in fieldEditor?.beginInstruction() }
        dictation.deliver = { [weak fieldEditor] in fieldEditor?.deliver($0) }
        dictation.deliverStream = { [weak fieldEditor] poll in await fieldEditor?.stream(poll) ?? false }
        dictation.retractStream = { [weak fieldEditor] in fieldEditor?.retractStreamed() }
        pipeline.onLiveChange = { [weak fieldEditor] in fieldEditor?.enqueueLive($0) }
        pipeline.keepsTakes = { [weak fieldEditor] in fieldEditor?.passwordField != true }
        pipeline.contextBefore = { [weak fieldEditor] in fieldEditor?.contextBeforeCursor() ?? "" }
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
            Task { @MainActor in
                guard let self else { return }
                // A Chromium app builds its tree in about a second: ask for it now, before a dictation needs it.
                if let pid { AXTextTarget.requestTree(pid: pid) }
                self.fieldEditor.focusChanged()
                // An app switch voids a witness that cannot show its field still has focus.
                if let witness = self.fallbackOwner.witness, witness.verifiesFocus, witness.stillFocused() {} else { self.fallbackOwner.allowed = false }
            }
        }
        terminateObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { note in
            guard let pid = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier else { return }
            Task { @MainActor in AXTextTarget.forget(pid: pid) }
        }
        if let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier { AXTextTarget.requestTree(pid: pid) }
        // Only after launch: a global monitor added before `NSApp` exists cuts the process off from every mouse event.
        assert(NSApp != nil, "Install event monitors after applicationDidFinishLaunching")
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in self?.fieldEditor.relinquish(); self?.fallbackOwner.allowed = false }
        }
        permissions.hotkeyTapActive = hotkeysEnabled && tap.start()
        // The pill's quick controls act on Legato (Magic as the hotkey; Undo and Redo through the field's queue). The pill
        // never becomes key or main, so the field keeps focus, and its clicks are not counted as the user's input.
        dictationPill = DictationPillController(
            session: dictation, panel: fieldEditor.panel, history: fieldEditor.history,
            actions: DictationPillActions(
                magic: { [weak self] in self?.toggleMagic() },
                undo: { [weak fieldEditor] in Task { await fieldEditor?.undoLast() } },
                redo: { [weak fieldEditor] in Task { await fieldEditor?.redoLast() } },
                copyRecovery: { [weak fieldEditor] in fieldEditor?.copyRecovery() },
                dismissRecovery: { [weak fieldEditor] in fieldEditor?.dismissRecovery() }))
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
    func toggleMagic() {
        if dictation.speechMode == .instruction { stopMagic() } else { startMagic() }
    }
    private func startMagic() {
        guard !refusedByMeeting() else { magicGesture.runEnded(); return }
        guard microphoneReady() else { magicGesture.runEnded(); return }
        magicTask = Task { if !(await dictation.startMagic()) { magicGesture.runEnded() } }
    }
    private func stopMagic() {
        let starting = magicTask
        Task { await starting?.value; await dictation.endMagic(); magicGesture.runEnded() }
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
    func beginRecording(_ target: HotkeyTarget = .magic) {
        guard tap.isActive else { permissions.requestAccessibility(); return }
        magicGesture.reset(); dictationGesture.reset()
        recorder = HotkeyRecorderLogic(); recordingTarget = target; recordingPreview = nil
    }
    func cancelRecording() { recordingTarget = nil; recordingPreview = nil }
    private func handle(_ sample: TapSample) {
        guard let event = sample.event else { magicGesture.reset(); dictationGesture.reset(); return }
        if event.kind == .keyDown {
            let shortcut = settings.hotkey?.triggerEvent(for: event) == .pressed || settings.dictationHotkey?.triggerEvent(for: event) == .pressed
            // Legato's own shortcuts are not the user's typing: a key-based shortcut must not void a typed insert.
            if !shortcut { keyPresses.count &+= 1 }
            if !shortcut, recordingTarget == nil {
                fieldEditor.relinquish(); fallbackOwner.allowed = false
                if dictation.instruction.strip.phase == .result || dictation.instruction.strip.phase == .undone { instructionAction(.accept) }
            }
        }
        if let target = recordingTarget {
            switch recorder.feed(event) {
            case .none: break
            case .preview(let text): recordingPreview = text
            case .captured(let spec):
                let other = target == .magic ? settings.dictationHotkey : settings.hotkey
                if let other, spec.conflicts(with: other) {
                    recordingPreview = "Already used by the \(target == .magic ? "dictation" : "Magic") shortcut."
                    recorder = HotkeyRecorderLogic()
                    return
                }
                if target == .magic { settings.hotkey = spec } else { settings.dictationHotkey = spec }
                cancelRecording()
            case .cancelled: cancelRecording()
            }
            return
        }
        if let trigger = settings.hotkey?.triggerEvent(for: event) {
            magicGesture.feed(trigger, at: sample.time, mode: settings.gestureMode) { [weak self] in self?.dispatch($0) }
        }
        if let trigger = settings.dictationHotkey?.triggerEvent(for: event) {
            dictationGesture.feed(trigger, at: sample.time, mode: settings.gestureMode) { [weak self] in self?.dispatchDictation($0) }
        }
    }
    private func dispatchDictation(_ action: HotkeyGesture.Action?) {
        // A held trigger (push-to-talk) never auto-sends: its release is the send.
        defer { dictation.setHeld(dictationGesture.gesture.isHolding && action != .cancel) }
        switch action {
        case .start: startDictation()
        case .stop: stopDictation()
        case .cancel: cancelDictation()
        case nil: break
        }
    }
    /// The dictation hotkey (or the debug bridge) starts a session when idle and stops a running one.
    func toggleDictation() {
        switch dictation.phase {
        case .idle: startDictation()
        case .starting, .listening: stopDictation()
        case .finishing: break
        }
    }
    private func startDictation() {
        guard !dictation.isActive else { return }
        guard !refusedByMeeting() else { dictationGesture.runEnded(); return }
        guard microphoneReady() else { dictationGesture.runEnded(); return }
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
        case .start: startMagic()
        case .stop: stopMagic()
        case .cancel: magicTask?.cancel(); dictation.instruction.reset(); cancelDictation(); magicGesture.runEnded()
        case nil: break
        }
    }
    func refreshRecent() async { recent = (try? await history.recent(limit: 20)) ?? [] }
    func copy(_ entry: DictationEntry) { paster.copy(entry.text) }
    func delete(_ entry: DictationEntry) { Task { try? await history.delete(id: entry.id); await refreshRecent() } }
}

/// Counts real key presses, readable from the dictation writer's closures.
@MainActor final class KeyPressCounter { var count = 0 }

/// One hotkey's `HotkeyGesture` plus the timer that starts a held press.
@MainActor private final class GestureDriver {
    private(set) var gesture = HotkeyGesture()
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
    func reset() { armTask?.cancel(); armTask = nil; gesture.reset() }
    func runEnded() { gesture.runEnded() }
}

/// Only the app/field captured before speech may receive a panel-mode take's typed insert.
@MainActor private final class MacFallbackOwner {
    var pid: pid_t?
    var witness: AXTextTarget.PasteWitness?
    var keys = 0
    var allowed = false
    var generation = 0
}
