import Foundation
import LegatoCore
import LegatoEngines
import LegatoPostProcessing
import LegatoVocabulary
import Synchronization

/// An app's one owner of the personal vocabulary: the store, what learns into it and what selects hints
/// out of it. It is the ``VocabularyHintProvider`` the speech engines ask, and it feeds the cleanup step's
/// `<terms>` line.
///
/// Learning is fire-and-forget: the `learnFrom…` entry points return at once and the work runs in a task of
/// its own, so a dictation or a cleanup run never waits for the vocabulary, nor fails because of it. The
/// tasks are detached so they do not inherit the caller's actor (the apps call from the main actor) or its
/// priority; ``waitForLearning()`` lets tests, and a clean shutdown, wait for what is in flight.
///
/// Share exactly one instance per file (see ``VocabularyStore``).
public final class VocabularyService: VocabularyHintProvider, Sendable {
    /// Hints per engine (decision: 50 terms each).
    public static let engineHintLimit = 50

    public let store: VocabularyStore
    private let learner: VocabularyLearner
    private let selector: HintSelector
    private let inFlight = Mutex(InFlight())

    private struct InFlight {
        var count = 0
        var waiters: [CheckedContinuation<Void, Never>] = []
    }

    /// - Parameters:
    ///   - fileURL: where `vocabulary.json` lives.
    ///   - languages: the configured language codes ("de", "en"); a word is common when any knows it.
    public init(
        fileURL: URL, languages: [String], spellChecker: any SpellChecking = PlatformSpellChecker(),
        tagger: any EntityTagging = NLEntityTagger(), halfLife: TimeInterval = Decay.defaultHalfLife,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        let store = VocabularyStore(fileURL: fileURL)
        self.store = store
        learner = VocabularyLearner(
            store: store, spellChecker: spellChecker, tagger: tagger, languages: languages, now: now)
        selector = HintSelector(languages: languages, halfLife: halfLife)
    }

    /// The language codes ("de", "en") a vocabulary is checked against: the dictation languages of the
    /// engine settings, else the system's preferred languages; "en" when there are none.
    public static func configuredLanguages(
        _ settings: EngineSettings, system: [String] = Locale.preferredLanguages
    ) -> [String] {
        func code(_ identifier: String) -> String? { Locale(identifier: identifier).language.languageCode?.identifier }
        let chosen = settings.preferredLocales.map(\.identifier)
        var seen = Set<String>()
        let codes = (chosen.isEmpty ? system : chosen).compactMap(code).filter { seen.insert($0).inserted }
        return codes.isEmpty ? ["en"] : codes
    }

    // MARK: hints

    public func hints(for sink: HintSink, limit: Int) async -> [VocabularyHint] {
        guard let snapshot = try? await store.snapshot() else { return [] }
        return selector.hints(from: snapshot, for: Self.sink(sink), limit: limit)
            .map { VocabularyHint(text: $0.text, spellings: $0.spellings) }
    }

    /// The terms for the cleanup model's `<terms>` line given the text it will clean: pinned terms plus the
    /// ones this text seems to mention. Empty when the vocabulary can't be read.
    public func cleanupTerms(for text: String) async -> [String] {
        guard let snapshot = try? await store.snapshot() else { return [] }
        return selector.cleanupTerms(for: text, from: snapshot)
    }

    private static func sink(_ sink: HintSink) -> VocabularyHintSink {
        switch sink {
        case .nemotron: .nemotron
        case .appleSpeech: .appleSpeech
        case .cleanup: .cleanup
        }
    }

    // MARK: learning

    /// Learns from the final text of dictation `id`. Returns at once.
    public func learnFromDictation(text: String, locale: Locale, id: UUID) {
        spawn { [learner] in await learner.observe(text: text, locale: locale, dictationID: id) }
    }

    /// Learns from what cleanup run `runID` changed. Returns at once.
    public func learnFromCleanup(raw: String, cleaned: String, style: CleanupStyle, runID: UUID, locale: Locale) {
        let learning = Self.learningStyle(style)
        spawn { [learner] in
            await learner.observeCleanup(raw: raw, cleaned: cleaned, style: learning, runID: runID, locale: locale)
        }
    }

    static func learningStyle(_ style: CleanupStyle) -> CleanupLearningStyle {
        switch style {
        case .verbatim: .verbatim
        case .message: .message
        }
    }

    /// How many learning tasks are in flight.
    public var pendingLearning: Int { inFlight.withLock { $0.count } }

    /// Returns once every learning task started so far has finished.
    public func waitForLearning() async {
        await withCheckedContinuation { continuation in
            let idle = inFlight.withLock { state in
                if state.count == 0 { return true }
                state.waiters.append(continuation)
                return false
            }
            if idle { continuation.resume() }
        }
    }

    private func spawn(_ work: @escaping @Sendable () async -> Void) {
        inFlight.withLock { $0.count += 1 }
        Task.detached(priority: .utility) { [self] in
            await work()
            let waiters = inFlight.withLock { state -> [CheckedContinuation<Void, Never>] in
                state.count -= 1
                guard state.count == 0 else { return [] }
                defer { state.waiters = [] }
                return state.waiters
            }
            for waiter in waiters { waiter.resume() }
        }
    }
}
