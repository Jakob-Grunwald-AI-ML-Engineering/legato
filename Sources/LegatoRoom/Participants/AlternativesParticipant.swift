import Foundation
import LegatoComposerDoc
import LegatoVocabulary

public struct AlternativesEvent: Codable, Sendable, Equatable {
    public var lineID: String
    public var wordID: String
    public var candidates: [String]
}

/// Shares the persistent vocabulary with Soniox and the keyboard; never maintains a separate lexicon.
public actor AlternativesParticipant {
    private let room: Room
    private let store: VocabularyStore
    private let learner: VocabularyLearner?
    private let spellChecker: (any SpellChecking)?
    private let wordPairs: WordPairModel
    private let runID: UUID
    private var previous = DocumentSnapshot(revision: 0, lines: [])
    private var processed: Set<String> = []
    private var task: Task<Void, Never>?
    public init(room: Room, store: VocabularyStore, learner: VocabularyLearner? = nil,
                spellChecker: (any SpellChecking)? = PlatformSpellChecker(), wordPairs: WordPairModel = WordPairModel(), runID: UUID = UUID()) {
        self.room = room; self.store = store; self.learner = learner
        self.spellChecker = spellChecker; self.wordPairs = wordPairs; self.runID = runID
    }
    public func start() async {
        guard task == nil else { return }
        let events = await room.subscribe(participant: .alternatives, channels: [.docSnapshot, .docOps])
        previous = await room.documentSnapshot
        task = Task { [weak self] in
            for await event in events { guard !Task.isCancelled else { break }; await self?.receive(event) }
        }
        await populate(previous)
    }
    public func stop() { task?.cancel(); task = nil }
    private func receive(_ envelope: Envelope) async {
        if envelope.channel == .docOps, let transaction = try? envelope.payload.decode(Transaction.self), transaction.origin == .agent {
            for op in transaction.ops {
                guard case let .replaceInLine(lineID, old, new) = op,
                      old.split(whereSeparator: \.isWhitespace).count == 1,
                      new.split(whereSeparator: \.isWhitespace).count == 1,
                      let line = previous.lines.first(where: { $0.id == lineID }),
                      let word = line.words.first(where: { $0.text == old && $0.confidence != nil }) else { continue }
                await learner?.observeCleanup(raw: old, cleaned: new, style: .verbatim, runID: runID,
                                              locale: Locale(identifier: word.language ?? "en"))
            }
        }
        if envelope.channel == .docSnapshot, let snapshot = try? envelope.payload.decode(DocumentSnapshot.self) {
            previous = snapshot
            await populate(snapshot)
        }
    }
    private func populate(_ snapshot: DocumentSnapshot) async {
        guard let vocabulary = try? await store.snapshot() else { return }
        var sources: [any AlternativeSource] = [VocabularySource(snapshot: vocabulary), CorrectionHistorySource(snapshot: vocabulary)]
        if let spellChecker { sources.append(SpellCheckerSource(checker: spellChecker)) }
        for line in snapshot.lines {
            let sentence = line.words.map(\.text).joined(separator: " ")
            var offset = sentence.startIndex
            for word in line.words {
                let end = sentence.index(offset, offsetBy: word.text.count)
                let range = offset..<end
                offset = end < sentence.endIndex ? sentence.index(after: end) : end
                guard let confidence = word.confidence, confidence < 0.6, !word.pinned,
                      processed.insert(word.id + ":" + word.text).inserted else { continue }
                let context = AlternativeContext(sentence: sentence, wordRange: range, languages: [word.language ?? "en"])
                let ranked = await WordAlternatives.rank(word: word.text, context: context, sources: sources, wordPairs: wordPairs)
                let candidates = ranked.map(\.text)
                guard word.alternatives != candidates else { continue }
                let current = await room.documentSnapshot
                guard let latest = current.lines.first(where: { $0.id == line.id }),
                      latest.words.contains(where: { $0.id == word.id && $0.text == word.text && !$0.pinned }) else { continue }
                do {
                    try await room.applyDocument([.setAlternatives(lineID: line.id, wordID: word.id, alternatives: candidates)], origin: .system, versions: [line.id: latest.version])
                    try await room.publish(channel: .alternatives, participant: .alternatives,
                                           payload: .encoding(AlternativesEvent(lineID: line.id, wordID: word.id, candidates: candidates)))
                } catch { processed.remove(word.id + ":" + word.text) }
            }
        }
    }
}
