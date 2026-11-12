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

/// The retained host shell. Composer participants replace this placeholder in later legs.
@MainActor @Observable
final class AppController {
    static let shared = AppController()
    let vocabulary: VocabularyService
    let keyboardHost: KeyboardLinkHost?
    let history: any HistoryStore
    let composer: ComposerSession
    let keyboardSession: KeyboardSession
    let dictation: DictationPipeline
    private let holdActivity: HoldActivityPresenter
    let meetings: IOSMeetingController
    var notice: String {
        if meetings.isActive { return "Meeting recording. Stop the meeting to use dictation; your draft is kept." }
        return composer.error ?? (composer.microphoneRecovering ? "Reconnecting microphone…" : composer.status.capitalized)
    }
    var lastTranscript: String?
    var isDictating: Bool { composer.isListening }

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
        history = LearningHistoryStore(JSONLHistoryStore(fileURL: root.appending(path: "history.jsonl")), vocabulary: vocabulary)
        composer = ComposerSession(vocabularyURL: root.appending(path: "vocabulary.json"),
            keepMicrophoneActive: ComposerMicrophonePreference.keepActive(), history: history)
        #if LEGATO_INTERNAL
        if UserDefaults.standard.bool(forKey: "LegatoOfflineFixture") {
            dictation = DictationPipeline(recentTakes: RecentTakesStore(fileURL: root.appending(path: "recent-takes.json")),
                                          history: history, cleaner: DebugStreamingCleaner(chunkMilliseconds: 0),
                                          sendMode: { DictationSendSetting.mode(in: AppGroup.defaults) }, supportsLive: true, groupsLiveHistory: true)
            keyboardSession = KeyboardSession.offlineFixture(composer: composer, sink: dictation,
                                                             instruction: InstructionSession(runner: IOSOfflineInstructionRunner(), history: history))
        } else {
            dictation = DictationPipeline(vocabularyURL: root.appending(path: "vocabulary.json"),
                                          recentTakesURL: root.appending(path: "recent-takes.json"), history: history, defaults: AppGroup.defaults,
                                          supportsLive: true, groupsLiveHistory: true)
            keyboardSession = KeyboardSession(composer: composer, sink: dictation,
                                              instruction: InstructionSession(vocabularyURL: root.appending(path: "vocabulary.json"), history: history))
        }
        dictation.diagnostics = { event, fields in AudioDiagnostics.log(event, fields) }
        #else
        dictation = DictationPipeline(vocabularyURL: root.appending(path: "vocabulary.json"),
                                      recentTakesURL: root.appending(path: "recent-takes.json"), history: history, defaults: AppGroup.defaults,
                                      supportsLive: true, groupsLiveHistory: true)
        keyboardSession = KeyboardSession(composer: composer, sink: dictation,
                                          instruction: InstructionSession(vocabularyURL: root.appending(path: "vocabulary.json"), history: history))
        #endif
        #if LEGATO_INTERNAL
        keyboardSession.instruction.diagnostics = { event, fields in AudioDiagnostics.log(event, fields) }
        #endif
        holdActivity = HoldActivityPresenter(composer: composer)
        #if LEGATO_INTERNAL
        keyboardHost = IOSMeetingFixture.current == nil ? KeyboardLinkHost() : nil
        #else
        keyboardHost = KeyboardLinkHost()
        #endif
        let host = keyboardHost
        meetings = IOSMeetingController(root: root.appending(path: "Meetings"),
            vocabularyURL: root.appending(path: "vocabulary.json"), keyboard: keyboardSession, composer: composer,
            publishReservation: { active in host?.link.meetingChanged(active: active) })
        keyboardHost?.onChoices = { [weak self] choices in
            for choice in choices {
                self?.vocabulary.recordChoice(original: choice.original, chosen: choice.chosen,
                    fromVocabulary: choice.fromVocabulary)
            }
        }
        composer.inputRoute = Self.inputRoutePolicy()
        keyboardHost?.attach(composer, keyboardSession: keyboardSession, dictation: dictation)
        keyboardHost?.link.onRequest = { [weak self] request in
            guard let self else { return false }
            guard !self.meetings.isActive, !self.meetings.fixtureMode else { return false }
            switch request.command {
            // With the keyboard on screen a tap only opens the pre-warmed gate on its surface's route.
            case .start where self.keyboardSession.isOpen: return await self.keyboardSession.openGate(tapAt: request.at)
            case .stop where self.keyboardSession.isOpen: await self.keyboardSession.closeGate()
            case .start: await self.composer.start()
            case .stop: await self.composer.stop()
            case .arm: await self.readyMicrophone()
            default: await self.composer.releaseMicrophone()
            }
            return true
        }
        keyboardHost?.startListening()
        Task { [composer] in await composer.backfillHistory(markerURL: root.appending(path: "history-backfill.v1.done")) }
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

    func toggle(afterForegroundHop: ForegroundReason? = nil) async -> DictationCoordinator.Outcome {
        guard !meetings.fixtureMode else { return .failed("Offline meetings fixture: use the Meetings tab. Composer drafts can be seeded for acceptance.") }
        guard !meetings.isActive else { return .failed("Stop the meeting before dictating. Your draft is kept.") }
        if composer.isListening { await composer.stop() }
        else { await holdActivity.arming { await composer.start() } }
        lastTranscript = composer.renderedText
        if let error = composer.error { return .failed(error) }
        return composer.isListening ? .started : .stopped(composer.renderedText)
    }
    func copy(_ text: String) { UIPasteboard.general.string = text }
    func recentEntries(limit: Int = 100) async -> [DictationEntry] { (try? await history.recent(limit: limit)) ?? [] }
    func deleteEntry(id: UUID) async { try? await history.delete(id: id) }
    func stopIfRunning() async { await composer.stop() }
    /// The Live Activity's Release button: the same release as the keyboard's, which ends the hold's activity.
    func releaseMicrophone() async {
        guard !meetings.isActive else { return }
        await composer.releaseMicrophone()
        keyboardHost?.link.leaseChanged(until: nil)
    }
    func readyMicrophone() async {
        await holdActivity.arming { await composer.arm() }
        keyboardHost?.link.leaseChanged(until: composer.isArmed ? Date().addingTimeInterval(3600) : nil)
    }
    func handle(_ url: URL) async {
        if url.host == "meetings" { meetings.open(); return }
        guard !meetings.isActive, !meetings.fixtureMode else { return }
        if let request = KeyboardURL.parse(url), request.command == .arm,
           keyboardHost?.link.admitURL(requestID: request.requestID, command: request.command) == .act {
            await readyMicrophone()
        }
    }
    func insertResult() async { if let lastTranscript { _ = await keyboardHost?.insert(lastTranscript) } }
    func copyResult() async { if let lastTranscript { UIPasteboard.general.string = lastTranscript } }
}
