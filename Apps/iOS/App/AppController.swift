import Foundation
import LegatoAppServices
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
    var notice: String { composer.error ?? composer.status.capitalized }
    var lastTranscript: String?
    var isDictating: Bool { composer.isListening }

    private init() {
        let root = AppGroup.containerURL
            ?? URL.applicationSupportDirectory.appending(path: "Legato", directoryHint: .isDirectory)
        let settings = EngineSettings(defaults: AppGroup.defaults)
        vocabulary = VocabularyService(fileURL: root.appending(path: "vocabulary.json"),
            languages: { VocabularyService.configuredLanguages(settings) },
            pairsFileURL: root.appending(path: "wordpairs-dictated.json"))
        history = LearningHistoryStore(JSONLHistoryStore(fileURL: root.appending(path: "history.jsonl")), vocabulary: vocabulary)
        composer = ComposerSession(vocabularyURL: root.appending(path: "vocabulary.json"),
            keepMicrophoneActive: ComposerMicrophonePreference.keepActive(), history: history)
        keyboardHost = KeyboardLinkHost()
        keyboardHost?.onChoices = { [weak self] choices in
            for choice in choices {
                self?.vocabulary.recordChoice(original: choice.original, chosen: choice.chosen,
                    fromVocabulary: choice.fromVocabulary)
            }
        }
        keyboardHost?.attach(composer)
        keyboardHost?.link.onRequest = { [weak self] request in
            guard let self else { return false }
            switch request.command {
            case .start: await self.composer.start()
            case .stop: await self.composer.stop()
            case .arm: await self.composer.arm(); self.keyboardHost?.link.leaseChanged(until: self.composer.isArmed ? Date().addingTimeInterval(3600) : nil)
            default: await self.composer.releaseMicrophone()
            }
            return true
        }
        keyboardHost?.startListening()
        #if LEGATO_INTERNAL
        DebugBridge.start()
        #endif
    }

    func toggle(afterForegroundHop: ForegroundReason? = nil) async -> DictationCoordinator.Outcome {
        if composer.isListening { await composer.stop() } else { await composer.start() }
        lastTranscript = composer.renderedText
        if let error = composer.error { return .failed(error) }
        return composer.isListening ? .started : .stopped(composer.renderedText)
    }
    func copy(_ text: String) { UIPasteboard.general.string = text }
    func recentEntries(limit: Int = 100) async -> [DictationEntry] { (try? await history.recent(limit: limit)) ?? [] }
    func deleteEntry(id: UUID) async { try? await history.delete(id: id) }
    func stopIfRunning() async { await composer.stop() }
    func handle(_ url: URL) async {
        if let request = KeyboardURL.parse(url), request.command == .arm,
           keyboardHost?.link.admitURL(requestID: request.requestID, command: request.command) == .act {
            await composer.arm(); keyboardHost?.link.leaseChanged(until: composer.isArmed ? Date().addingTimeInterval(3600) : nil)
        }
    }
    func insertResult() async { if let lastTranscript { _ = await keyboardHost?.insert(lastTranscript) } }
    func copyResult() async { if let lastTranscript { UIPasteboard.general.string = lastTranscript } }
}
