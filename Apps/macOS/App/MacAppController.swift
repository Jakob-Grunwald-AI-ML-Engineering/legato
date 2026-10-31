import AppKit
import LegatoAppServices
import LegatoAgent
import LegatoCore
import LegatoMac
import LegatoVocabulary
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
    private var writer: FieldWriter?
    private var composerTargetToken: String?
    private var targetPID: pid_t?
    private var secureField = false
    private var starting = false
    private(set) var inserting = false
    private var sessionTask: Task<Void, Never>?
    var notice: String { composer.error ?? composer.status.capitalized }
    var isDictating: Bool { starting || composer.isListening }
    var isRecordingHotkey = false
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
    private var gesture = HotkeyGesture()
    private var armTask: Task<Void, Never>?
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
        composer.hostInsertionTarget = { [weak self] in self?.composerTargetToken }
        composer.hostInsertionUnavailableReason = { [weak self] in
            self?.secureField == true ? "The bound field is secure." : "No external text field is bound."
        }
        composer.hostInsertDraft = { [weak self] target in
            guard let self else { return .init(succeeded: false, message: "Composer closed. Draft kept.") }
            return await self.performComposerInsertion(expectedTarget: target)
        }
        composer.hostClearComposer = { [weak self] in await self?.clearComposer() }
    }
    func bootstrap() {
        guard !bootstrapped else { return }; bootstrapped = true
        permissions.hotkeyTapActive = hotkeysEnabled && tap.start()
        eventTask = Task { for await sample in tap.samples { handle(sample) } }
        pollTask = Task {
            while !Task.isCancelled {
                permissions.refresh()
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
        gesture.runEnded()
        if starting { cancelComposer(); return }
        Task { await composer.stop() }
    }
    func cancelComposer() { Task { await clearComposer() } }
    private func clearComposer() async {
        sessionTask?.cancel(); sessionTask = nil; starting = false
        await composer.cancel()
        guard composer.snapshot.lines.isEmpty, composer.status == "idle" else { return }
        notch.hide(); writer = nil; composerTargetToken = nil; gesture.runEnded()
    }
    func insertComposer() { Task { _ = await performComposerInsertion() } }
    private func performComposerInsertion(expectedTarget: String? = nil) async -> ComposerHostActionResult {
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
        gesture.runEnded()
        let text: String
        do { text = try await composer.prepareForInsertion() }
        catch {
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
    func beginRecording() {
        guard tap.isActive else { permissions.requestAccessibility(); return }
        armTask?.cancel(); gesture.reset(); recorder = HotkeyRecorderLogic(); isRecordingHotkey = true; recordingPreview = nil
    }
    func cancelRecording() { isRecordingHotkey = false; recordingPreview = nil }
    private func handle(_ sample: TapSample) {
        guard let event = sample.event else { gesture.reset(); return }
        if isRecordingHotkey {
            switch recorder.feed(event) {
            case .none: break
            case .preview(let text): recordingPreview = text
            case .captured(let spec): settings.hotkey = spec; cancelRecording()
            case .cancelled: cancelRecording()
            }
            return
        }
        guard let trigger = settings.hotkey?.triggerEvent(for: event) else { return }
        if gesture.mode != settings.gestureMode { gesture = HotkeyGesture(mode: settings.gestureMode) }
        dispatch(gesture.tick(at: sample.time))
        switch trigger {
        case .pressed: dispatch(gesture.pressed(at: sample.time))
        case .released: dispatch(gesture.released(at: sample.time))
        case .otherKeyDown: dispatch(gesture.otherKeyDown())
        }
        armTask?.cancel()
        if let deadline = gesture.armDeadline {
            armTask = Task {
                try? await Task.sleep(for: .seconds(max(0, deadline - ProcessInfo.processInfo.systemUptime)))
                guard !Task.isCancelled else { return }
                dispatch(gesture.tick(at: ProcessInfo.processInfo.systemUptime))
            }
        }
    }
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
