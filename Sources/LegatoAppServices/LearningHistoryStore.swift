import Foundation
import LegatoCore

/// A ``HistoryStore`` that lets the vocabulary learn from what is appended. Every call goes to the wrapped
/// store; after an append that succeeded, the entry's raw text (or final text when no raw text exists) is handed to the service, which learns in
/// the background. A failed append observes nothing, and the observing never delays or fails an append.
///
/// A delete that succeeded also tells the service to forget that dictation, so a cancelled or deleted dictation
/// stops teaching. The service runs the forget after any learning it started for the same dictation.
public struct LearningHistoryStore: HistoryStore {
    private let base: any HistoryStore
    private let vocabulary: VocabularyService

    public init(_ base: any HistoryStore, vocabulary: VocabularyService) {
        self.base = base
        self.vocabulary = vocabulary
    }

    public func append(_ entry: DictationEntry) async throws {
        try await base.append(entry)
        vocabulary.learnFromDictation(text: entry.rawText ?? entry.text, locale: Locale(identifier: entry.localeIdentifier), id: entry.id)
    }

    /// Upserts are provisional checkpoints of a draft, so they teach nothing: repeated edits must not
    /// re-count pairs, and generated text is not a spoken sighting.
    public func upsert(_ entry: DictationEntry) async throws { try await base.upsert(entry) }

    public func recent(limit: Int) async throws -> [DictationEntry] { try await base.recent(limit: limit) }

    public func delete(id: UUID) async throws {
        try await base.delete(id: id)
        // After the base delete, so the pair rebuild reads history without the dictation.
        vocabulary.forget(dictationID: id, remainingHistory: base)
    }
}
