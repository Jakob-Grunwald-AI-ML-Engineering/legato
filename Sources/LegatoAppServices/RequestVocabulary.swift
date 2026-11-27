import Foundation
import LegatoAgent
import LegatoKeyboardCore
import LegatoCore
import LegatoVocabulary

/// Read-only request view. Qualified and explicitly approved spellings overlay the vocabulary so revocation
/// never needs to undo a write to the user's manual or history-learned vocabulary.
struct RequestVocabulary: Sendable {
    private let fileURL: URL
    private let corrections: CorrectionStore
    private let languages: @Sendable () -> [String]
    private let spellChecker: any SpellChecking
    private let halfLife: TimeInterval
    private let history: LearningHistoryStore?

    init(fileURL: URL, settings: EngineSettings? = nil, history: (any HistoryStore)? = nil) {
        let effectiveSettings: EngineSettings
        #if os(iOS)
        effectiveSettings = settings ?? EngineSettings(defaults: UserDefaults(suiteName: LinkChannel.appGroupID) ?? .standard)
        #else
        effectiveSettings = settings ?? EngineSettings()
        #endif
        self.init(fileURL: fileURL, languages: { VocabularyService.configuredLanguages(effectiveSettings) },
                  spellChecker: PlatformSpellChecker(), halfLife: Decay.defaultHalfLife, history: history as? LearningHistoryStore)
    }

    init(fileURL: URL, languages: @escaping @Sendable () -> [String], spellChecker: any SpellChecking, halfLife: TimeInterval, history: LearningHistoryStore? = nil) {
        self.fileURL = fileURL
        self.history = history
        self.corrections = CorrectionStore(root: fileURL.deletingLastPathComponent())
        self.languages = languages
        self.spellChecker = spellChecker
        self.halfLife = halfLife
    }

    private var selector: HintSelector { HintSelector(languages: languages(), halfLife: halfLife) }

    private func evidence(matching draft: String? = nil) async -> (VocabularySnapshot, [CorrectionCandidate]) {
        var snapshot = (try? VocabularySnapshot.read(from: fileURL)) ?? VocabularySnapshot()
        let suppressed = (try? await corrections.suppressedSpellings()) ?? []
        snapshot.suppressLearnedSpellings(suppressed)
        let active = (try? await corrections.activeCandidates()) ?? []
        snapshot.applySpellingEdits(from: active)
        for preference in active where preference.kind == .vocabulary {
            // Learned substitutions provide independent evidence for a target, not universal aliases.
            // An automatic term can reach a cleanup/Magic request only if its exact spelling occurs there.
            if preference.approvedSource == nil, let draft, !preference.matchesTargetPhrase(in: draft) { continue }
            guard let index = snapshot.overlay(preference, automaticSource: .history) else { continue }
            if let alias = preference.approvedSource, alias != preference.after {
                let existing = snapshot.entry(forText: alias)
                if existing?.source != .manual && existing?.pinned != true && !snapshot.entries[index].aliases.contains(alias) {
                    snapshot.entries[index].aliases.append(alias)
                }
            }
        }
        return (snapshot, active.filter { $0.state == .approved })
    }

    func hints(for sink: VocabularyHintSink, limit: Int, context: VocabularyTopicContext = .init()) async -> [SelectedHint] {
        let (snapshot, _) = await evidence()
        return selector.hints(from: snapshot, for: sink, limit: limit, context: context)
    }

    func sonioxTerms() async -> [String] {
        await hints(for: .soniox, limit: VocabularyService.engineHintLimit).map(\.text)
    }

    @MainActor func sonioxTerms(contextFor: (Date) -> VocabularyTopicContext) async -> [String] {
        let since = try? await corrections.personalizationEnabledSince()
        let context = since.map(contextFor) ?? .init()
        return await hints(for: .soniox, limit: VocabularyService.engineHintLimit, context: context).map(\.text)
    }

    func cleanup(for text: String, context: VocabularyTopicContext? = nil) async -> CleanupPersonalization {
        let (snapshot, approved) = await evidence(matching: text)
        let since = try? await corrections.personalizationEnabledSince()
        let topic = since.map { context ?? history?.topicContext(since: $0) ?? .init() } ?? .init()
        let selected = await selector.cleanupTerms(for: text, from: snapshot, spellChecker: spellChecker,
                                                   context: topic)
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
                guard candidate.approvedSource != nil, terms.contains(where: { VocabularyEntry.key(for: $0) == VocabularyEntry.key(for: candidate.after) }) else { continue }
            } else if !candidate.matchesSourcePhrase(in: text) {
                continue
            }
            let example = CleanupPersonalization.Example(before: candidate.before, after: candidate.after)
            if !examples.contains(example) { examples.append(example) }
        }
        return CleanupPersonalization(vocabulary: terms, examples: examples)
    }
}
