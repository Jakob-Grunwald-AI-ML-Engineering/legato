import Foundation
import LegatoAgent
import LegatoKeyboardCore
import LegatoCore
import LegatoVocabulary

/// Read-only request view. Approved spellings overlay the vocabulary in memory so revocation
/// never needs to undo a write to the user's manual or history-learned vocabulary.
struct RequestVocabulary: Sendable {
    private let fileURL: URL
    private let corrections: CorrectionStore
    private let languages: @Sendable () -> [String]
    private let spellChecker: any SpellChecking
    private let halfLife: TimeInterval

    init(fileURL: URL, settings: EngineSettings? = nil) {
        let effectiveSettings: EngineSettings
        #if os(iOS)
        effectiveSettings = settings ?? EngineSettings(defaults: UserDefaults(suiteName: LinkChannel.appGroupID) ?? .standard)
        #else
        effectiveSettings = settings ?? EngineSettings()
        #endif
        self.init(fileURL: fileURL, languages: { VocabularyService.configuredLanguages(effectiveSettings) },
                  spellChecker: PlatformSpellChecker(), halfLife: Decay.defaultHalfLife)
    }

    init(fileURL: URL, languages: @escaping @Sendable () -> [String], spellChecker: any SpellChecking, halfLife: TimeInterval) {
        self.fileURL = fileURL
        self.corrections = CorrectionStore(root: fileURL.deletingLastPathComponent())
        self.languages = languages
        self.spellChecker = spellChecker
        self.halfLife = halfLife
    }

    private var selector: HintSelector { HintSelector(languages: languages(), halfLife: halfLife) }

    private func evidence() async -> (VocabularySnapshot, [CorrectionCandidate]) {
        var snapshot = (try? VocabularySnapshot.read(from: fileURL)) ?? VocabularySnapshot()
        let approved = (try? await corrections.approvedCandidates()) ?? []
        for preference in approved where preference.kind == .vocabulary && !snapshot.isBlocked(preference.after) {
            guard !preference.after.isEmpty, preference.after.utf8.count <= 256 else { continue }
            let key = VocabularyEntry.key(for: preference.after)
            let prior = snapshot.entry(forText: preference.before)
            let alias = prior?.source == .manual || prior?.pinned == true ? [] : [preference.before]
            if let index = snapshot.entries.firstIndex(where: { VocabularyEntry.key(for: $0.text) == key }) {
                snapshot.entries[index].source = .manual
                snapshot.entries[index].correctionTarget = true
                if !alias.isEmpty, !snapshot.entries[index].aliases.contains(preference.before) {
                    snapshot.entries[index].aliases.append(preference.before)
                }
            } else {
                let term = VocabularyEntry(text: preference.after, source: .manual,
                    score: Double(preference.records.count), lastSeen: preference.records.map(\.date).max() ?? .distantPast,
                    correctionTarget: true, aliases: alias)
                snapshot.entries.append(term)
            }
        }
        return (snapshot, approved)
    }

    func hints(for sink: VocabularyHintSink, limit: Int) async -> [SelectedHint] {
        let (snapshot, _) = await evidence()
        return selector.hints(from: snapshot, for: sink, limit: limit)
    }

    func sonioxTerms() async -> [String] {
        await hints(for: .soniox, limit: VocabularyService.engineHintLimit).map(\.text)
    }

    func cleanup(for text: String) async -> CleanupPersonalization {
        let (snapshot, approved) = await evidence()
        let selected = await selector.cleanupTerms(for: text, from: snapshot, spellChecker: spellChecker)
        var budget = 16_384
        let terms = selected.filter { term in
            guard term.utf8.count <= budget else { return false }
            budget -= term.utf8.count
            return true
        }
        var examples: [CleanupPersonalization.Example] = []
        for candidate in approved {
            guard examples.count < 6 else { break }
            guard candidate.before.utf8.count <= 256, candidate.after.utf8.count <= 256 else { continue }
            if candidate.kind == .vocabulary {
                guard terms.contains(where: { VocabularyEntry.key(for: $0) == VocabularyEntry.key(for: candidate.after) }) else { continue }
            } else if !candidate.matchesSourcePhrase(in: text) {
                continue
            }
            let example = CleanupPersonalization.Example(before: candidate.before, after: candidate.after)
            if !examples.contains(example) { examples.append(example) }
        }
        return CleanupPersonalization(vocabulary: terms, examples: examples)
    }
}
