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
/// priority, and they run **one after another in the order they were started**: a ``forget(dictationID:)``
/// issued right after a ``learnFromDictation(text:locale:id:)`` (the Mac's cancel chord appends, then deletes)
/// therefore always lands after what it must undo. ``waitForLearning()`` lets tests, and a clean shutdown,
/// wait for what is in flight.
///
/// The configured languages are read on every use, not fixed at init, so a change of the dictation languages
/// applies to the next dictation.
///
/// Share exactly one instance per file (see ``VocabularyStore``).
public final class VocabularyService: VocabularyHintProvider, Sendable {
    /// Hints per engine (decision: 50 terms each).
    public static let engineHintLimit = 50

    public let store: VocabularyStore
    private let languages: @Sendable () -> [String]
    private let spellChecker: any SpellChecking
    private let tagger: any EntityTagging
    private let halfLife: TimeInterval
    private let now: @Sendable () -> Date
    private let queue = Mutex(Queue())

    private struct Queue {
        var count = 0
        var waiters: [CheckedContinuation<Void, Never>] = []
        /// The most recently started task; the next one waits for it.
        var tail: Task<Void, Never>?
    }

    /// - Parameters:
    ///   - fileURL: where `vocabulary.json` lives.
    ///   - languages: the configured language codes ("de", "en"), read on every use; a word is common when
    ///     any of them knows it.
    public init(
        fileURL: URL, languages: @escaping @Sendable () -> [String], spellChecker: any SpellChecking = PlatformSpellChecker(),
        tagger: any EntityTagging = NLEntityTagger(), halfLife: TimeInterval = Decay.defaultHalfLife,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        store = VocabularyStore(fileURL: fileURL)
        self.languages = languages
        self.spellChecker = spellChecker
        self.tagger = tagger
        self.halfLife = halfLife
        self.now = now
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

    private var learner: VocabularyLearner {
        VocabularyLearner(store: store, spellChecker: spellChecker, tagger: tagger, languages: languages(), now: now)
    }

    private var selector: HintSelector { HintSelector(languages: languages(), halfLife: halfLife) }

    // MARK: hints

    public func hints(for sink: HintSink, limit: Int) async -> [VocabularyHint] {
        guard let snapshot = try? await store.snapshot() else { return [] }
        return selector.hints(from: snapshot, for: Self.sink(sink), limit: limit)
            .map { VocabularyHint(text: $0.text, spellings: $0.spellings) }
    }

    /// The terms for the cleanup model's `<terms>` line given the text it will clean: pinned terms plus the
    /// ones this text seems to mention. A fuzzy hit on an ordinary word is left out (see
    /// ``HintSelector/cleanupTerms(for:from:spellChecker:limit:now:)``). Empty when the vocabulary can't be read.
    public func cleanupTerms(for text: String) async -> [String] {
        guard let snapshot = try? await store.snapshot() else { return [] }
        return await selector.cleanupTerms(for: text, from: snapshot, spellChecker: spellChecker)
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
        spawn { [self] in await learner.observe(text: text, locale: locale, dictationID: id) }
    }

    /// Learns from what cleanup run `runID` changed. Returns at once. `suggested`: the terms the model was
    /// given for the run; a substitution to one of them is not independent evidence and teaches nothing.
    ///
    /// A cleanup run has no dictation id (the dictation is saved after cleanup), so ``forget(dictationID:)``
    /// cannot find what a run taught: deleting a dictation leaves its cleanup runs' pending fixes in place.
    /// They hold only short raw → target fragments of one or two words.
    public func learnFromCleanup(
        raw: String, cleaned: String, style: CleanupStyle, runID: UUID, locale: Locale, suggested: [String] = []
    ) {
        let learning = Self.learningStyle(style)
        spawn { [self] in
            await learner.observeCleanup(
                raw: raw, cleaned: cleaned, style: learning, runID: runID, locale: locale, suggested: suggested)
        }
    }

    /// Takes dictation `id` back out of what it taught (the user deleted or cancelled it): see
    /// ``VocabularySnapshot/forget(_:)``. Returns at once; it runs after every learning task started before it.
    public func forget(dictationID id: UUID) {
        spawn { [store] in try? await store.forget(id: id) }
    }

    static func learningStyle(_ style: CleanupStyle) -> CleanupLearningStyle {
        switch style {
        case .verbatim: .verbatim
        case .message: .message
        }
    }

    /// How many learning tasks are in flight.
    public var pendingLearning: Int { queue.withLock { $0.count } }

    /// Returns once every learning task started so far has finished.
    public func waitForLearning() async {
        await withCheckedContinuation { continuation in
            let idle = queue.withLock { state in
                if state.count == 0 { return true }
                state.waiters.append(continuation)
                return false
            }
            if idle { continuation.resume() }
        }
    }

    /// Queues `work` behind every task started before it.
    private func spawn(_ work: @escaping @Sendable () async -> Void) {
        queue.withLock { state in
            state.count += 1
            let previous = state.tail
            state.tail = Task.detached(priority: .utility) { [self] in
                await previous?.value
                await work()
                finish()
            }
        }
    }

    private func finish() {
        let waiters = queue.withLock { state -> [CheckedContinuation<Void, Never>] in
            state.count -= 1
            guard state.count == 0 else { return [] }
            defer { state.waiters = [] }
            state.tail = nil
            return state.waiters
        }
        for waiter in waiters { waiter.resume() }
    }
}
