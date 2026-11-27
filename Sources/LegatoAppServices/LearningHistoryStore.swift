import Foundation
import LegatoCore
import LegatoAgent
import LegatoVocabulary

/// A ``HistoryStore`` that lets the vocabulary learn from what is appended. Every call goes to the wrapped
/// store; after an append that succeeded, the entry's raw text (or final text when no raw text exists) is handed to the service, which learns in
/// the background. A failed append observes nothing, and the observing never delays or fails an append.
///
/// A delete that succeeded also tells the service to forget that dictation, so a cancelled or deleted dictation
/// stops teaching. The service runs the forget after any learning it started for the same dictation.
public struct LearningHistoryStore: HistoryStore {
    private let base: any HistoryStore
    private let vocabulary: VocabularyService
    private let recentTakes: RecentTakesStore?
    private let styleDiagnostics: StyleDiagnosticLog?
    private let styleFinalizations: Bool
    private let topicHistory: VocabularyTopicHistory

    func topicContext(textBeforeCursor: String = "", since: Date = .distantPast) -> VocabularyTopicContext {
        topicHistory.context(field: textBeforeCursor, since: since)
    }

    func warmTopicContext() async { await topicHistory.warm() }

    public init(_ base: any HistoryStore, vocabulary: VocabularyService, recentTakes: RecentTakesStore? = nil,
                styleDiagnostics: StyleDiagnosticLog? = nil, styleFinalizations: Bool = true) {
        self.styleDiagnostics = styleDiagnostics
        self.styleFinalizations = styleFinalizations
        self.recentTakes = recentTakes
        self.base = base
        self.topicHistory = VocabularyTopicHistory(history: base)
        self.vocabulary = vocabulary
    }

    public func append(_ entry: DictationEntry) async throws {
        try await base.append(entry)
        topicHistory.observe(entry)
        if entry.recognitionHints != nil {
            didFinalize(entry)
        } else if let raw = entry.spokenEvidence {
            vocabulary.learnFromDictation(text: raw, locale: Locale(identifier: entry.localeIdentifier), id: entry.id)
        }
    }

    /// Only an explicitly finalized recognition can teach. Checkpoints, old imports and Magic writes have no hints receipt.
    public func upsert(_ entry: DictationEntry) async throws {
        try await base.upsert(entry)
        topicHistory.observe(entry)
        if entry.recognitionHints != nil { didFinalize(entry) }
    }

    private func didFinalize(_ entry: DictationEntry) {
        if styleFinalizations, entry.spokenEvidence != nil, let styleDiagnostics {
            styleDiagnostics.record(.init(takeID: entry.id, platform: styleDiagnostics.platform, action: .finalized,
                                          eventID: entry.id, at: entry.date))
        }
        vocabulary.learnFromFinalizedTake(entry, history: base)
    }

    public func recent(limit: Int) async throws -> [DictationEntry] { try await base.recent(limit: limit) }

    public func delete(id: UUID) async throws {
        try await base.delete(id: id)
        styleDiagnostics?.record(takeID: id, action: .deleted)
        topicHistory.forget(id)
        recentTakes?.forget(id: id)
        // After the base delete, so the pair rebuild reads history without the dictation.
        vocabulary.forget(dictationID: id, remainingHistory: base)
    }
}
