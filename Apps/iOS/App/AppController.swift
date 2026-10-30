import Foundation
import LegatoAppServices
import LegatoCore
import LegatoKeyboardCore
import LegatoVocabulary
import Observation
import UIKit

/// The retained host shell. Composer participants replace this placeholder in later legs.
@MainActor @Observable
final class AppController {
    static let shared = AppController()
    let vocabulary: VocabularyService
    let keyboardHost: KeyboardLinkHost?
    let history: any HistoryStore
    var notice = "Composer coming"
    var lastTranscript: String?
    var isDictating: Bool { false }

    private init() {
        let root = AppGroup.containerURL
            ?? URL.applicationSupportDirectory.appending(path: "Legato", directoryHint: .isDirectory)
        let settings = EngineSettings(defaults: AppGroup.defaults)
        vocabulary = VocabularyService(fileURL: root.appending(path: "vocabulary.json"),
            languages: { VocabularyService.configuredLanguages(settings) },
            pairsFileURL: root.appending(path: "wordpairs-dictated.json"))
        history = LearningHistoryStore(JSONLHistoryStore(fileURL: root.appending(path: "history.jsonl")), vocabulary: vocabulary)
        keyboardHost = KeyboardLinkHost()
        keyboardHost?.onChoices = { [weak self] choices in
            for choice in choices {
                self?.vocabulary.recordChoice(original: choice.original, chosen: choice.chosen,
                    fromVocabulary: choice.fromVocabulary)
            }
        }
        keyboardHost?.link.onRequest = { [weak self] _ in
            self?.notice = "Composer coming"
            return false
        }
        keyboardHost?.startListening()
        #if LEGATO_INTERNAL
        DebugBridge.start()
        #endif
    }

    func toggle(afterForegroundHop: ForegroundReason? = nil) async -> DictationCoordinator.Outcome {
        notice = "Composer coming"
        return .failed(notice)
    }
    func copy(_ text: String) { UIPasteboard.general.string = text }
    func recentEntries(limit: Int = 100) async -> [DictationEntry] { (try? await history.recent(limit: limit)) ?? [] }
    func deleteEntry(id: UUID) async { try? await history.delete(id: id) }
    func stopIfRunning() async {}
    func handle(_ url: URL) async { _ = await toggle() }
    func insertResult() async { if let lastTranscript { _ = await keyboardHost?.insert(lastTranscript) } }
    func copyResult() async { if let lastTranscript { UIPasteboard.general.string = lastTranscript } }
}
