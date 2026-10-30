import AppKit
import LegatoAppServices
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
    var notice = "Composer coming"
    var isDictating: Bool { false }
    var isRecordingHotkey = false
    var recordingPreview: String?
    var onboardingRequests = 0
    var setupAttention: Bool { !permissions.accessibility || settings.hotkey == nil }
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
    }
    func bootstrap() {
        guard !bootstrapped else { return }; bootstrapped = true
        permissions.hotkeyTapActive = tap.start()
        eventTask = Task { for await sample in tap.samples { handle(sample) } }
        pollTask = Task {
            while !Task.isCancelled {
                permissions.refresh()
                if !tap.isActive { permissions.hotkeyTapActive = tap.start() }
                try? await Task.sleep(for: .seconds(2))
            }
        }
        #if LEGATO_INTERNAL
        DebugBridge.start()
        #endif
    }
    func toggle() { notice = "Composer coming"; hud.show(toast: notice); gesture.runEnded() }
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
    private func dispatch(_ action: HotkeyGesture.Action?) { if action == .start { toggle() } }
    func refreshRecent() async { recent = (try? await history.recent(limit: 20)) ?? [] }
    func copy(_ entry: DictationEntry) { paster.copy(entry.text) }
    func delete(_ entry: DictationEntry) { Task { try? await history.delete(id: entry.id); await refreshRecent() } }
}
