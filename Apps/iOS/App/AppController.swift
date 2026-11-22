import Foundation
import LegatoAppServices
import LegatoAudio
import LegatoCore
import LegatoKeyboardCore
import LegatoVocabulary
import LegatoAgent
import LegatoComposerDoc
import Observation
import UIKit

/// Owns iOS dictation, microphone admission, meetings and their app presentation.
@MainActor @Observable
final class AppController {
    enum ToggleOutcome: Sendable, Equatable {
        case started, stopped(String?), needsOnboarding(ReadinessIssue), needsForeground(ForegroundReason), failed(String), busy
    }
    static let shared = AppController()
    let vocabulary: VocabularyService
    let keyboardHost: KeyboardLinkHost?
    let history: any HistoryStore
    let corrections: CorrectionStore
    let microphone: MicrophoneHost
    let keyboardSession: KeyboardSession
    let dictation: DictationPipeline
    private let holdActivity: HoldActivityPresenter
    let meetings: IOSMeetingController
    var notice: String {
        if meetings.isActive { return "Meeting recording. Stop the meeting to use dictation." }
        return microphone.error ?? (microphone.microphoneRecovering ? "Reconnecting microphone…" : microphone.status.capitalized)
    }
    var historyRevision = 0
    var isDictating: Bool { microphone.isListening }

    private init() {
        var root = AppGroup.containerURL
            ?? URL.applicationSupportDirectory.appending(path: "Legato", directoryHint: .isDirectory)
        #if LEGATO_INTERNAL
        if let fixture = IOSMeetingFixture.current { root = fixture.applicationRoot }
        #endif
        let settings = EngineSettings(defaults: AppGroup.defaults)
        vocabulary = VocabularyService(fileURL: root.appending(path: "vocabulary.json"),
            languages: { VocabularyService.configuredLanguages(settings) },
            pairsFileURL: root.appending(path: "wordpairs-dictated.json"))
        corrections = CorrectionStore(root: root)
        history = LearningHistoryStore(JSONLHistoryStore(fileURL: root.appending(path: "history.jsonl")), vocabulary: vocabulary)
        microphone = MicrophoneHost(vocabularyURL: root.appending(path: "vocabulary.json"),
            keepMicrophoneActive: ComposerMicrophonePreference.keepActive())
        #if LEGATO_INTERNAL
        if UserDefaults.standard.bool(forKey: "LegatoOfflineFixture") {
            dictation = DictationPipeline(recentTakes: RecentTakesStore(fileURL: root.appending(path: "recent-takes.json")),
                                          history: history, cleaner: DebugStreamingCleaner(chunkMilliseconds: 0),
                                          sendMode: { DictationSendSetting.mode(in: AppGroup.defaults) }, supportsLive: true,
                                          liveSend: { DictationSendSetting.liveSend(in: AppGroup.defaults) }, groupsLiveHistory: true, stagedLive: true)
            keyboardSession = KeyboardSession.offlineFixture(microphone: microphone, sink: dictation,
                                                             instruction: InstructionSession(runner: IOSOfflineInstructionRunner(), history: history))
        } else {
            dictation = DictationPipeline(vocabularyURL: root.appending(path: "vocabulary.json"),
                                          recentTakesURL: root.appending(path: "recent-takes.json"), history: history, defaults: AppGroup.defaults,
                                          supportsLive: true, groupsLiveHistory: true, stagedLive: true)
            keyboardSession = KeyboardSession(microphone: microphone, sink: dictation,
                                              instruction: InstructionSession(vocabularyURL: root.appending(path: "vocabulary.json"), history: history))
        }
        dictation.diagnostics = { event, fields in AudioDiagnostics.log(event, fields) }
        #else
        dictation = DictationPipeline(vocabularyURL: root.appending(path: "vocabulary.json"),
                                      recentTakesURL: root.appending(path: "recent-takes.json"), history: history, defaults: AppGroup.defaults,
                                      supportsLive: true, groupsLiveHistory: true, stagedLive: true)
        keyboardSession = KeyboardSession(microphone: microphone, sink: dictation,
                                          instruction: InstructionSession(vocabularyURL: root.appending(path: "vocabulary.json"), history: history))
        #endif
        #if LEGATO_INTERNAL
        keyboardSession.instruction.diagnostics = { event, fields in AudioDiagnostics.log(event, fields) }
        #endif
        holdActivity = HoldActivityPresenter(microphone: microphone, keyboard: keyboardSession)
        #if LEGATO_INTERNAL
        keyboardHost = IOSMeetingFixture.current == nil ? KeyboardLinkHost() : nil
        #else
        keyboardHost = KeyboardLinkHost()
        #endif
        let host = keyboardHost
        meetings = IOSMeetingController(root: root.appending(path: "Meetings"),
            vocabularyURL: root.appending(path: "vocabulary.json"), keyboard: keyboardSession, microphone: microphone,
            publishReservation: { active in host?.link.meetingChanged(active: active) })
        holdActivity.onDismissal = { [weak self] holdID in
            await self?.stopDictationActivity(holdID: holdID)
        }
        keyboardHost?.onChoices = { [weak self] choices in
            for choice in choices {
                self?.vocabulary.recordChoice(original: choice.original, chosen: choice.chosen,
                    fromVocabulary: choice.fromVocabulary)
            }
        }
        microphone.inputRoute = Self.inputRoutePolicy()
        keyboardHost?.attach(microphone, keyboardSession: keyboardSession, dictation: dictation)
        keyboardHost?.link.onRequest = { [weak self] request in
            guard let self else { return false }
            guard !self.meetings.isActive, !self.meetings.fixtureMode else { return false }
            switch request.command {
            // With the keyboard on screen a tap only opens the pre-warmed gate on its surface's route.
            case .start where self.keyboardSession.isOpen: return await self.keyboardSession.openGate(tapAt: request.at)
            case .stop where self.keyboardSession.isOpen: await self.keyboardSession.closeGate()
            case .start: await self.readyMicrophone()
            case .stop: await self.keyboardSession.closeGate()
            case .send: await self.keyboardSession.sendNow()
            case .editPreview: await self.keyboardSession.sendNow(editPreview: true, preview: request.preview)
            case .beginPreviewHold, .releasePreviewHold, .cancelPreviewHold:
                self.keyboardSession.handlePreviewHold(request)
            // The preview's swipe right: the same, with the words as spoken (no cleanup).
            case .sendRaw: await self.keyboardSession.sendRawNow(preview: request.preview)
            // The preview's swipe left: the words still in it are dropped for a short undo window.
            case .discard: await self.keyboardSession.discardNow()
            case .undoDiscard: await self.keyboardSession.undoDiscardNow()
            case .arm: await self.readyMicrophone()
            default: await self.microphone.releaseMicrophone()
            }
            return true
        }
        keyboardHost?.startListening()
        Task { [history] in
            if await ComposerHistoryBackfill.run(sessionsRoot: URL.documentsDirectory.appending(path: "sessions"), history: history,
                excluding: [], markerURL: root.appending(path: "history-backfill.v1.done")) > 0 { historyRevision += 1 }
        }
        #if LEGATO_INTERNAL
        DebugBridge.start()
        #endif
    }

    /// #226: built-in mic while the mic is only held, the headset's for a take. Read per call, so the internal
    /// toggle takes effect without a relaunch; release builds always read false and never touch the route.
    private static func inputRoutePolicy() -> InputRoutePolicy {
        InputRoutePolicy(
            preferIdle: { if Settings.airpodsIdleBuiltIn { PreferredInputRoute.apply(.builtIn) } },
            preferTake: { if Settings.airpodsIdleBuiltIn { PreferredInputRoute.apply(.bluetooth) } })
    }

    func toggle(afterForegroundHop: ForegroundReason? = nil) async -> ToggleOutcome {
        if afterForegroundHop != nil {
            do { try await IOSForegroundAdmission.waitUntilActive() }
            catch { return .failed(error.localizedDescription) }
        }
        if ShortcutActionSetting.action(in: AppGroup.defaults) == .meeting {
            if meetings.isActive { await meetings.stop(); return .stopped(nil) }
            return await startMeeting()
        }
        guard !meetings.isActive else { return .failed("Stop the meeting before dictating.") }
        if keyboardSession.route != .idle { await keyboardSession.closeGate(); return .stopped(nil) }
        if !microphone.isArmed {
            guard UIApplication.shared.applicationState == .active else { return .needsForeground(.backgroundStartRefused) }
            await readyMicrophone()
            guard microphone.isArmed else { return .failed(microphone.error ?? "Microphone could not start.") }
        }
        if keyboardSession.isOpen {
            return await keyboardSession.openGate() ? .started : .failed(keyboardSession.dictationNotice ?? "Dictation could not start.")
        }
        return .started
    }
    func startMeetingFromActivity(holdID: String?) async throws {
        try await IOSForegroundAdmission.waitUntilActive()
        guard canStartMeetingFromActivity(holdID) else { return }
        _ = await startMeeting(while: { self.canStartMeetingFromActivity(holdID) })
    }

    private func canStartMeetingFromActivity(_ holdID: String?) -> Bool {
        holdActivity.ownsHold(holdID) && microphone.isArmed && !microphone.microphoneRecovering
            && keyboardSession.route == .idle && !meetings.isActive
    }

    private func startMeeting(while canStart: () -> Bool = { true }) async -> ToggleOutcome {
        guard UIApplication.shared.applicationState == .active else { return .needsForeground(.backgroundStartRefused) }
        meetings.open()
        await meetings.prepare()
        guard !meetings.isActive, canStart() else { return .busy }
        meetings.start()
        return meetings.isActive ? .started : .failed(meetings.notice ?? "Meeting could not start.")
    }

    func copy(_ text: String) { UIPasteboard.general.string = text }
    func recentEntries(limit: Int = 100) async -> [DictationEntry] { (try? await history.recent(limit: limit)) ?? [] }
    func deleteEntry(id: UUID) async { try? await history.delete(id: id) }
    func stopIfRunning() async { await keyboardSession.closeGate() }
    func stopDictationActivity(holdID: String?) async {
        await holdActivity.stop(holdID: holdID) { await releaseMicrophone() }
    }

    /// Closes the keyboard take before releasing the microphone and its keyboard lease.
    func releaseMicrophone() async {
        guard !meetings.isActive else { return }
        await keyboardSession.closeGate(releasingMicrophone: true)
        guard !meetings.isActive, !microphone.isArmed else { return }
        keyboardHost?.link.leaseChanged(until: nil)
    }
    func prepareForBackground() async {
        if !ComposerMicrophonePreference.keepActive() { await keyboardSession.closeGate() }
        await microphone.prepareForBackground()
    }
    func readyMicrophone() async {
        guard !meetings.isActive else { return }
        await holdActivity.arming { await microphone.arm() }
        keyboardHost?.link.leaseChanged(until: microphone.isArmed ? Date().addingTimeInterval(3600) : nil)
    }
    func handle(_ url: URL) async {
        if url.host == "meetings" { meetings.open(); return }
        guard !meetings.isActive, !meetings.fixtureMode else { return }
        if let request = KeyboardURL.parse(url), request.command == .arm,
           keyboardHost?.link.admitURL(requestID: request.requestID, command: request.command) == .act {
            await readyMicrophone()
        }
    }
}
