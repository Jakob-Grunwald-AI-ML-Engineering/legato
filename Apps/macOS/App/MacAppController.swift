import AppKit
import LegatoAppServices
import LegatoAgent
import LegatoCore
import LegatoMac
import LegatoVocabulary
import LegatoAudio
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
    let composer: ComposerSession
    let notch = NotchPanelController()
    /// The dictation hotkey: types straight into the focused field. It never shares speech with `composer`.
    let dictation: MacDictationSession
    private let dictationWriter: FieldDictationWriter
    private var dictationPill: DictationPillController?
    private var writer: FieldWriter?
    private var composerTargetToken: String?
    private var targetPID: pid_t?
    private var secureField = false
    private var starting = false
    private(set) var inserting = false
    private var sessionTask: Task<Void, Never>?
    var notice: String { composer.error ?? composer.status.capitalized }
    var isDictating: Bool { starting || composer.isListening }
    enum HotkeyTarget { case panel, dictation }
    private(set) var recordingTarget: HotkeyTarget?
    var isRecordingHotkey: Bool { recordingTarget != nil }
    var recordingPreview: String?
    var onboardingRequests = 0
    var setupAttention: Bool { !permissions.accessibility || settings.hotkey == nil }
    #if DEBUG
    private let hotkeysEnabled = !UserDefaults.standard.bool(forKey: "LegatoDisableHotkeys")
    #else
    private let hotkeysEnabled = true
    #endif
    private let tap = HotkeyTap()
    private var recorder = HotkeyRecorderLogic()
    private let panelGesture = GestureDriver()
    private let dictationGesture = GestureDriver()
    private var eventTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
    private var bootstrapped = false

    private init() {
        let root = URL.applicationSupportDirectory.appending(path: "Legato", directoryHint: .isDirectory)
        let engine = EngineSettings()
        vocabulary = VocabularyService(fileURL: root.appending(path: "vocabulary.json"),
            languages: { VocabularyService.configuredLanguages(engine) })
        history = LearningHistoryStore(JSONLHistoryStore(fileURL: root.appending(path: "history.jsonl")), vocabulary: vocabulary)
        composer = ComposerSession(history: history)
        let vocabularyURL = root.appending(path: "vocabulary.json")
        dictation = MacDictationSession(pipeline: DictationPipeline(vocabularyURL: vocabularyURL),
                                        microphone: AutomaticInputSource(), vocabularyURL: vocabularyURL)
        dictationWriter = FieldDictationWriter(
            capture: {
                switch AXTextTarget.captureFocused() {
                case .target(let target): .target(target)
                case .none: .none
                case .secure: .secure
                }
            },
            fallback: { [weak paster = paster] text, secure, copyOnly in
                guard let paster else { return .copied(message: "") }
                let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier
                if copyOnly || pid == ProcessInfo.processInfo.processIdentifier {
                    paster.copy(text)
                    return .copied(message: secure ? PasteService.CopyReason.secureField.toast : "Copied to the clipboard. Paste with ⌘V.")
                }
                let restore = UserDefaults.standard.object(forKey: "restoreClipboard") as? Bool ?? true
                switch await paster.paste(text, restoreClipboard: restore, targetPID: pid, secureField: secure) {
                case .pasted: return .pasted
                case .copied(let reason): return .copied(message: reason.toast)
                }
            })
        dictation.onBegin = { [weak self] in self?.dictationWriter.begin() }
        dictation.deliver = { [weak self] text in
            guard let self else { return }
            if case .copied(let message) = await dictationWriter.write(text), !message.isEmpty { dictation.report(message) }
        }
        dictation.pipeline.contextBefore = { [weak self] in self?.dictationWriter.textBeforeCursor() ?? "" }
        composer.hostInsertionTarget = { [weak self] in self?.composerTargetToken }
        composer.hostInsertionUnavailableReason = { [weak self] in
            self?.secureField == true ? "The bound field is secure." : "No external text field is bound."
        }
        composer.hostInsertDraft = { [weak self] target in
            guard let self else { return .init(succeeded: false, message: "Composer closed. Draft kept.") }
            return await self.performComposerInsertion(expectedTarget: target, origin: .instruction)
        }
        composer.hostClearComposer = { [weak self] in await self?.clearComposer() }
    }
    func bootstrap() {
        guard !bootstrapped else { return }; bootstrapped = true
        permissions.hotkeyTapActive = hotkeysEnabled && tap.start()
        dictationPill = DictationPillController(session: dictation)
        dictation.ensureWarm()
        Task {
            await composer.backfillHistory(markerURL: URL.applicationSupportDirectory.appending(path: "Legato/history-backfill.v1.done"))
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
        #endif
    }
    func toggle() {
        if isDictating { stopComposer(); return }
        guard !starting else { return }
        guard !dictation.isActive else { dictationPill?.show(notice: "Stop dictation before opening the composer."); return }
        starting = true
        prepareComposerTarget()
        sessionTask = Task {
            await composer.start()
            starting = false
        }
    }
    private func prepareComposerTarget() {
        targetPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let target: AXTextTarget?
        secureField = false
        switch AXTextTarget.captureFocused() {
        case .target(let value): target = value
        case .none: target = nil
        case .secure: target = nil; secureField = true
        }
        composerTargetToken = target != nil && targetPID != ProcessInfo.processInfo.processIdentifier ? UUID().uuidString : nil
        writer = FieldWriter(target: target, mode: .insertOnStop)
        notch.show(controller: self, targetPID: targetPID)
    }
    #if DEBUG
    func seedDebugComposer(_ args: [String]) async throws -> [String: Any] {
        prepareComposerTarget()
        return try await composer.debugControl("composer-debug-seed", args: args)
    }
    func startDebugComposer(_ args: [String]) async throws -> [String: Any] {
        prepareComposerTarget()
        return try await composer.debugControl("composer-debug-start", args: args)
    }
    #endif
    func stopComposer() {
        panelGesture.runEnded()
        if starting { cancelComposer(); return }
        Task { await composer.stop() }
    }
    func cancelComposer() { Task { await clearComposer() } }
    private func clearComposer() async {
        sessionTask?.cancel(); sessionTask = nil; starting = false
        await composer.cancel()
        guard composer.snapshot.lines.isEmpty, composer.status == "idle" else { return }
        notch.hide(); writer = nil; composerTargetToken = nil; panelGesture.runEnded()
    }
    func insertComposer(origin: ComposerInsertOrigin = .macPanelButton) { Task { _ = await performComposerInsertion(origin: origin) } }
    private func performComposerInsertion(expectedTarget: String? = nil, origin: ComposerInsertOrigin) async -> ComposerHostActionResult {
        guard !inserting else { return .init(succeeded: false, message: "Insertion already in progress. Draft kept.") }
        guard !composer.renderedText.isEmpty || !composer.tail.isEmpty else { return .init(succeeded: false, message: "The composer is empty.") }
        if let expectedTarget, expectedTarget != composerTargetToken {
            return .init(succeeded: false, message: "The target field changed. Draft kept.")
        }
        inserting = true
        defer { inserting = false }
        sessionTask?.cancel(); starting = false
        let requestedSessionID = composer.sessionID
        let requestedTarget = composerTargetToken, requestedWriter = writer
        let pid = targetPID, secure = secureField, restore = settings.restoreClipboard
        panelGesture.runEnded()
        await composer.traceInsertion("requested", origin: origin)
        let text: String
        do { text = try await composer.prepareForInsertion() }
        catch {
            await composer.traceInsertion("undelivered", origin: origin, detail: ["reason": "prepare.failed"])
            guard composer.sessionID == requestedSessionID else { return .init(succeeded: false, message: "Composition changed; insertion discarded.") }
            let message = "Couldn't finish preparing the text. Draft kept. Try Insert again."
            hud.show(toast: message); notch.show(controller: self, targetPID: pid)
            return .init(succeeded: false, message: message)
        }
        guard requestedSessionID == composer.sessionID, requestedTarget == composerTargetToken else {
            return .init(succeeded: false, message: "Composition or target changed. Draft kept.")
        }
        let sessionID = composer.sessionID, snapshot = composer.snapshot, tail = composer.tail
        notch.hide()
        let action = requestedWriter?.finish(finalText: text) ?? .paste(text)
        let route: String
        switch action { case .done: route = "fieldwriter"; case .paste: route = "paste"; case .copy: route = "clipboard" }
        var delivered = false
        var failure = "Couldn't insert into the bound text field. Draft kept."
        switch action {
        case .done: delivered = true
        case .copy(let text):
            paster.copy(text); failure = "Copied — paste with ⌘V. Draft kept."; hud.show(toast: failure)
        case .paste(let text):
            let result = await paster.paste(text, restoreClipboard: restore, targetPID: pid, secureField: secure)
            switch result {
            case .pasted: delivered = true
            case .copied(let reason): failure = reason.toast + " Draft kept."; hud.show(toast: failure)
            }
        }
        writer = nil; composerTargetToken = nil
        // FieldWriter/paste report their own completion; neither proves the target app shows the text.
        await composer.traceInsertion(delivered ? "acknowledged" : "undelivered", origin: origin,
            detail: delivered ? ["ack": route] : ["reason": route + ".not.delivered"])
        if delivered, composer.sessionID == sessionID, composer.snapshot == snapshot, composer.tail == tail {
            // Delivery has already succeeded. Reuse the existing nonactivating panel for
            // its flight instead of recreating the view or delaying the target insertion.
            let presentation = notch.revealForSend()
            await composer.insert()
            let acknowledgement = composer.successfulInsertionID, remainingSession = composer.sessionID
            if let presentation {
                notch.finishSend(presentation) { [weak self] in
                    guard let self else { return false }
                    return composer.successfulInsertionID == acknowledgement && composer.sessionID == remainingSession
                        && composer.renderedText.isEmpty && composer.tail.isEmpty && !isDictating
                }
            }
            return .init(succeeded: true, message: "Draft inserted into the bound text field.")
        }
        if delivered { failure = "Inserted. Draft changed during insertion; latest edits kept."; hud.show(toast: failure) }
        notch.show(controller: self, targetPID: pid)
        return .init(succeeded: delivered, message: failure)
    }
    func beginRecording(_ target: HotkeyTarget = .panel) {
        guard tap.isActive else { permissions.requestAccessibility(); return }
        panelGesture.reset(); dictationGesture.reset()
        recorder = HotkeyRecorderLogic(); recordingTarget = target; recordingPreview = nil
    }
    func cancelRecording() { recordingTarget = nil; recordingPreview = nil }
    private func handle(_ sample: TapSample) {
        guard let event = sample.event else { panelGesture.reset(); dictationGesture.reset(); return }
        if let target = recordingTarget {
            switch recorder.feed(event) {
            case .none: break
            case .preview(let text): recordingPreview = text
            case .captured(let spec):
                let other = target == .panel ? settings.dictationHotkey : settings.hotkey
                if let other, spec.conflicts(with: other) {
                    recordingPreview = "Already used by the \(target == .panel ? "dictation" : "composer") shortcut."
                    recorder = HotkeyRecorderLogic()
                    return
                }
                if target == .panel { settings.hotkey = spec } else { settings.dictationHotkey = spec }
                cancelRecording()
            case .cancelled: cancelRecording()
            }
            return
        }
        if let trigger = settings.hotkey?.triggerEvent(for: event) {
            panelGesture.feed(trigger, at: sample.time, mode: settings.gestureMode) { [weak self] in self?.dispatch($0) }
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
        guard !isDictating, !starting else { dictationPill?.show(notice: "Close the composer before dictating."); dictationGesture.runEnded(); return }
        switch permissions.mic {
        case .granted: break
        case .undetermined:
            Task { await permissions.requestMicrophone() }
            dictationPill?.show(notice: "Allow microphone access, then press the dictation shortcut again.")
            dictationGesture.runEnded(); return
        case .denied:
            dictationPill?.show(notice: "Microphone access is off. Allow Legato in System Settings, Privacy & Security.")
            dictationGesture.runEnded(); return
        }
        Task { if await !dictation.start() { dictationGesture.runEnded() } }
    }
    private func stopDictation() { Task { await dictation.stop() } }
    private func cancelDictation() { Task { await dictation.cancel(); dictationGesture.runEnded() } }
    private func dispatch(_ action: HotkeyGesture.Action?) {
        switch action {
        case .start: toggle()
        case .stop: stopComposer()
        case .cancel: cancelComposer()
        case nil: break
        }
    }
    func refreshRecent() async { recent = (try? await history.recent(limit: 20)) ?? [] }
    func copy(_ entry: DictationEntry) { paster.copy(entry.text) }
    func delete(_ entry: DictationEntry) { Task { try? await history.delete(id: entry.id); await refreshRecent() } }
}

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
