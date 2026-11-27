import Foundation
import LegatoAgent
import LegatoCore
import LegatoKeyboardCore
import LegatoVocabulary
import os

/// A bounded projection of existing History. Loading old rows never holds up a recognizer start.
/// Provisional and model output can identify echoes in the field, but only finalized, retained
/// speech with a request receipt supplies a previous-take observation.
private struct TopicObservation: Sendable {
    let id: UUID
    let date: Date
    let take: VocabularyTopicContext.Take?
    let excludedFieldWords: Set<String>
    let shownWords: Set<String>

    init(_ entry: DictationEntry) {
        id = entry.id
        date = entry.date
        let raw = entry.spokenEvidence.map { String($0.suffix(RecentTakesStore.entryLimit)) }
        if let raw, let hints = entry.recognitionHints {
            take = .init(raw: raw, recognitionHints: hints)
        } else {
            take = nil
        }
        // A prior model-only or recognizer-cued word in the host field is not an independent topic cue.
        let shown = VocabularyLearner.cueWords(in: String(entry.displayText.suffix(RecentTakesStore.entryLimit)))
        shownWords = shown
        if let take {
            excludedFieldWords = shown.subtracting(VocabularyLearner.cueWords(in: take.raw))
                .union(VocabularyLearner.cueWords(in: take.recognitionHints.joined(separator: " ")))
        } else {
            excludedFieldWords = shown
        }
    }
}

extension VocabularyTopicContext {
    fileprivate init(observations: [TopicObservation], field: String, since: Date, now: Date) {
        let available = observations.filter { $0.date <= now && now.timeIntervalSince($0.date) <= RecentTakesStore.maxAge }
        self.init(recentTakes: available.reversed().filter { $0.date >= since }.compactMap(\.take),
                  textBeforeCursor: String(field.suffix(KeyboardPresence.contextLimit)),
                  excludedFieldWords: available.reduce(into: []) { $0.formUnion($1.date >= since ? $1.excludedFieldWords : $1.shownWords) })
    }
}

final class VocabularyTopicHistory: Sendable {
    private struct Window: Sendable {
        var rows: [TopicObservation] = []
        var loading: Task<Void, Never>?
        var canUseField = false
        // While existing History loads, remember mutations so its read cannot revive a deleted
        // row or replace a newer version. Once warm, only the bounded observation window remains.
        var changedDuringLoad: Set<UUID>? = []
    }

    private let window = OSAllocatedUnfairLock(initialState: Window())
    private let history: any HistoryStore

    init(history: any HistoryStore) {
        self.history = history
        load()
    }

    private func load() {
        window.withLock { state in
            guard state.loading == nil else { return }
            state.changedDuringLoad = []
            state.canUseField = false
            state.loading = Task(priority: .utility) { [history, window] in
                let entries = try? await history.recent(limit: RecentTakesStore.capacity)
                let now = Date()
                let rows = (entries ?? []).filter { now.timeIntervalSince($0.date) <= RecentTakesStore.maxAge }.map(TopicObservation.init)
                window.withLock { state in
                    let changed = state.changedDuringLoad ?? []
                    // The fresh read owns all untouched rows, including a predecessor revealed by deletion.
                    if entries != nil {
                        state.rows.removeAll { !changed.contains($0.id) }
                        state.rows += rows.filter { !changed.contains($0.id) }
                        state.canUseField = true
                    }
                    Self.trim(&state.rows, now: now)
                    state.changedDuringLoad = nil
                    state.loading = nil
                }
            }
        }
    }

    func warm() async {
        let task = window.withLock { $0.loading }
        await task?.value
    }

    func observe(_ entry: DictationEntry) {
        let row = TopicObservation(entry)
        window.withLock { state in
            state.changedDuringLoad?.insert(entry.id)
            state.rows.removeAll { $0.id == entry.id }
            state.rows.insert(row, at: 0)
            Self.trim(&state.rows, now: Date())
        }
    }

    func forget(_ id: UUID) {
        let refill = window.withLock { state in
            state.changedDuringLoad?.insert(id)
            let wasFull = state.rows.count == RecentTakesStore.capacity
            let removed = state.rows.contains { $0.id == id }
            state.rows.removeAll { $0.id == id }
            return removed && wasFull
        }
        if refill { load() }
    }

    func context(field: String, since: Date) -> VocabularyTopicContext {
        let now = Date()
        let (rows, ready) = window.withLock { state in
            state.rows.removeAll { now.timeIntervalSince($0.date) > RecentTakesStore.maxAge }
            return (state.rows, state.canUseField)
        }
        return .init(observations: rows, field: ready ? field : "", since: since, now: now)
    }

    private static func trim(_ rows: inout [TopicObservation], now: Date) {
        rows.removeAll { now.timeIntervalSince($0.date) > RecentTakesStore.maxAge }
        rows.sort { $0.date > $1.date }
        if rows.count > RecentTakesStore.capacity { rows.removeLast(rows.count - RecentTakesStore.capacity) }
    }
}
