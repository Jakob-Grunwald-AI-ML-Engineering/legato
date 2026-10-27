import Foundation
import LegatoKeyboardCore
import LegatoVocabulary
import UIKit
#if DEBUG
import OSLog
import os
#endif

/// Fills the word row. `SuggestionState` (LegatoKeyboardCore) decides what the row shows from the newest
/// intent; this type turns that into words and into what a tap does:
/// - completions of the word being typed, and predictions after a space (`WordSuggester`: vocabulary, the
///   word-pair models, `UITextChecker`);
/// - alternatives for a tapped word (`WordAlternatives.rank` over the last dictation's other versions, the
///   vocabulary and the spell checker). Local only, no model.
///
/// It reads `vocabulary.json` and the two word-pair files from the App Group container, off the main thread,
/// and again whenever one of them changes. Without Full Access there is no container: only the spell
/// checker is used. It also learns from what the user types (`wordpairs-typed.json`, the keyboard is that
/// file's only writer), never in secure fields or fields that are not prose, and only with Full Access.
@MainActor
final class SuggestionController {
    /// What tapping a slot does, parallel to `KeyboardController.suggestions`.
    enum Action: Equatable {
        /// Finish the word being typed (or, with an empty prefix, add a predicted word).
        case complete(prefix: String)
        /// Replace the words `original` (the span) with the slot's text.
        case replace(original: String, span: WordSpan, fromVocabulary: Bool)
    }

    /// What was read from the container.
    private struct Resources: Sendable {
        var snapshot: VocabularySnapshot?
        var vocabulary: VocabularySource?
        var matcher: TermMatcher?
        var termTexts: [UUID: String] = [:]
        var pairs: WordPairModel?
    }

    /// The modification dates of the three files.
    private struct Stamps: Equatable {
        var vocabulary: Date?
        var dictated: Date?
        var typed: Date?
    }

    private unowned let controller: KeyboardController
    private var state = SuggestionState()
    private var actions: [Action] = []
    /// The row generation `actions` were built for: a keystroke starts a new one, and until the new words are
    /// published a tap on the old ones would apply them to a field that has moved on.
    private var actionsGeneration = 0
    private var lastContent: WordRowContent = .empty
    private var generation = 0
    private var task: Task<Void, Never>?
    private var before = ""
    private var after = ""
    /// Harness: words shown whatever is typed (`LegatoHarnessSuggestions`).
    private var pinned: [String]?

    private var resources = Resources()
    private var loadedStamps: Stamps?
    private var loading = false
    private var lastCheck = Date.distantPast
    private var languages = ["en"]
    private static let checkInterval: TimeInterval = 1

    /// The context the keyboard expects the host to report next, so its echo isn't taken for a cursor move.
    private var own: (before: String, at: Date)?
    /// What has taken the row over (the dictation status, a hint) and whether a run is active; the state is told
    /// only of changes, since telling it again would reset what the row shows.
    private var takeoverStatus: String?
    private var takeoverRunning = false

    private var typedBuffer = TypedSentenceBuffer()
    private var typedStore: WordPairStore?
    private var typedWrittenStamp: Date?
    private var writeChain: Task<Void, Never>?

    #if DEBUG
    private static let logger = Logger(subsystem: "de.gruenwald.legato", category: "e2e")
    #endif

    init(controller: KeyboardController) {
        self.controller = controller
    }

    // MARK: Files

    private nonisolated static let vocabularyFile = "vocabulary.json"
    private nonisolated static let dictatedFile = "wordpairs-dictated.json"
    private nonisolated static let typedFile = "wordpairs-typed.json"

    /// The App Group container; nil without Full Access (or misconfigured signing).
    private var container: URL? {
        guard controller.fullAccess else { return nil }
        return FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: LinkChannel.appGroupID)
    }

    private nonisolated static func modified(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date
    }

    private func stamps(in directory: URL) -> Stamps {
        Stamps(
            vocabulary: Self.modified(directory.appending(path: Self.vocabularyFile)),
            dictated: Self.modified(directory.appending(path: Self.dictatedFile)),
            typed: Self.modified(directory.appending(path: Self.typedFile)))
    }

    /// Reads the files again when one of them changed (checked at most once a second).
    func reloadIfChanged(force: Bool = false) {
        let now = Date()
        guard force || now.timeIntervalSince(lastCheck) >= Self.checkInterval else { return }
        lastCheck = now
        refreshLanguages()
        guard let directory = container else {
            resources = Resources()
            loadedStamps = nil
            return
        }
        let current = stamps(in: directory)
        guard !loading, force || current != loadedStamps else { return }
        loadedStamps = current
        loading = true
        Task { [weak self] in
            let loaded = await Task.detached(priority: .utility) { Self.load(from: directory) }.value
            guard let self else { return }
            self.resources = loaded
            self.loading = false
            #if DEBUG
            Self.logger.notice("e2e kbd.memory availableMB=\(Int(os_proc_available_memory() / 1_048_576)) vocabulary=\(loaded.snapshot?.entries.count ?? -1) pairs=\(loaded.pairs?.previousWordCount ?? -1)")
            #endif
        }
    }

    private nonisolated static func load(from directory: URL) -> Resources {
        var out = Resources()
        if let snapshot = try? VocabularySnapshot.read(from: directory.appending(path: vocabularyFile)) {
            let live = snapshot.entries.filter { !$0.blocked }
            out.snapshot = snapshot
            out.vocabulary = VocabularySource(snapshot: snapshot)
            out.matcher = TermMatcher(terms: live.map(TermMatcher.Term.init))
            out.termTexts = Dictionary(live.map { ($0.id, $0.text) }, uniquingKeysWith: { first, _ in first })
        }
        let dictated = WordPairModel.read(from: directory.appending(path: dictatedFile))
        let typed = WordPairModel.read(from: directory.appending(path: typedFile))
        out.pairs = switch (dictated, typed) {
        case let (a?, b?): a.merged(with: b)
        case let (a?, nil): a
        case let (nil, b?): b
        case (nil, nil): nil
        }
        return out
    }

    private func refreshLanguages() {
        let stored = UserDefaults(suiteName: LinkChannel.appGroupID)?.stringArray(forKey: "legato.engine.preferredLocales") ?? []
        languages = SuggestionLanguages.codes(stored: stored, system: Locale.preferredLanguages)
    }

    // MARK: Fields

    /// The field's keyboard type as the core policy knows it.
    private var fieldKeyboard: SuggestionField.Keyboard {
        switch document.keyboardType {
        case .default: .default
        case .asciiCapable: .asciiCapable
        case .twitter: .twitter
        case .webSearch: .webSearch
        case .numbersAndPunctuation: .numbersAndPunctuation
        default: .other
        }
    }

    /// Whether the field takes suggestions: prose-like fields only (a password, address, number or URL doesn't).
    private var suggestsHere: Bool {
        SuggestionField.suggests(
            secure: document.isSecureTextEntry, keyboard: fieldKeyboard, contentType: document.textContentType?.rawValue)
    }

    /// Whether what is typed here may be learned (`SuggestionField.learns`).
    private var learnsHere: Bool {
        SuggestionField.learns(
            fullAccess: controller.fullAccess, secure: document.isSecureTextEntry, keyboard: fieldKeyboard,
            contentType: document.textContentType?.rawValue)
    }

    private var document: any TextDocument { controller.document }

    // MARK: Intents

    func appeared() {
        reloadIfChanged(force: true)
    }

    /// A new field: nothing of the old one carries over.
    func fieldChanged() {
        interruptTyping()
        state = SuggestionState()
        _ = state.runActive(takeoverRunning)
        _ = state.status(takeoverStatus)
        clear()
        lastContent = state.content
        own = nil
    }

    /// A key was typed or a word completed: `contextBefore` is the text before the cursor now.
    func keystroke(contextBefore: String) {
        reloadIfChanged()
        own = (contextBefore, Date())
        before = contextBefore
        after = document.contextAfter
        _ = state.keystroke(contextBefore: contextBefore, at: Date())
        refreshRow()
    }

    /// The keyboard is about to change the field so that the text before the cursor becomes `expected`.
    func willApplyOwnEdit(expectedContextBefore expected: String) {
        own = (expected, Date())
        state.willApplyOwnEdit(expectedContextBefore: expected, at: Date())
    }

    /// The host reported a new cursor or text. Returns whether the user moved the cursor (or the host changed
    /// the text) rather than the keyboard's own edit being echoed.
    @discardableResult
    func contextChanged() -> Bool {
        reloadIfChanged()
        var reported = document.contextBefore
        var foreign = true
        if let own, Date().timeIntervalSince(own.at) <= SuggestionState.settleWindow {
            // The host may trim its context differently from what the keyboard tracked: a suffix match is the same text.
            if OwnEditEcho.isSame(expected: own.before, reported: reported) {
                reported = own.before
                foreign = false
            }
        } else {
            own = nil
        }
        before = reported
        after = document.contextAfter
        _ = state.cursorMoved(contextBefore: reported, contextAfter: after, hasSelection: document.selectedText?.isEmpty == false, at: Date())
        refreshRow()
        return foreign
    }

    /// Status text or a run took the row over (or gave it back): predictions pause meanwhile, and start again
    /// from the cursor when the row is free.
    func setTakeover(status: String?, running: Bool) {
        let status = status?.isEmpty == false ? status : nil
        guard status != takeoverStatus || running != takeoverRunning else { return }
        let wasPaused = takeoverStatus != nil || takeoverRunning
        takeoverStatus = status
        takeoverRunning = running
        _ = state.runActive(running)
        _ = state.status(status)
        if wasPaused, status == nil, !running {
            before = document.contextBefore
            after = document.contextAfter
            own = (before, Date())
            _ = state.keystroke(contextBefore: before, at: Date())
        }
        refreshRow()
    }

    /// The harness's fixed words: shown whatever is typed.
    func pin(_ words: [String]) {
        pinned = words
        controller.suggestions = words
        actions = []
        actionsGeneration = generation
    }

    /// Takes the words off the row (after a swap, or when nothing applies).
    func clear() {
        task?.cancel()
        generation += 1
        publish([], [])
    }

    // MARK: Row

    private func refreshRow() {
        guard pinned == nil else { return }
        let content = state.content
        guard content != lastContent else { return }
        lastContent = content
        task?.cancel()
        generation += 1
        let id = generation
        guard suggestsHere else { return publish([], []) }
        switch content {
        case .empty, .status:
            publish([], [])
        case .predictions(let previous):
            let words = WordSuggester.predictions(
                previous: previous.map { [$0] } ?? [], pairs: resources.pairs, snapshot: resources.snapshot)
            publish(words, words.map { _ in .complete(prefix: "") })
        case .completions(let prefix):
            task = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(30)) // typing and deleting quickly: only the last one is asked
                guard !Task.isCancelled else { return }
                await self?.completions(prefix: prefix, id: id)
            }
        case .alternatives(let word, _, _):
            task = Task { [weak self] in await self?.alternatives(word: word, id: id) }
        }
    }

    private func publish(_ words: [String], _ actions: [Action]) {
        self.actions = actions
        actionsGeneration = generation
        if controller.suggestions != words { controller.suggestions = words }
    }

    private func completions(prefix: String, id: Int) async {
        let previous = WordContext.previousWord(beforePrefixIn: before).map { [$0] } ?? []
        let words = await WordSuggester.completions(
            prefix: prefix, previous: previous, snapshot: resources.snapshot, pairs: resources.pairs,
            completer: PlatformSpellChecker(), languages: languages)
        guard !Task.isCancelled, id == generation else { return }
        publish(words, words.map { _ in .complete(prefix: prefix) })
    }

    /// The tapped word's alternatives, ranked in two steps so the row isn't held up by the platform spell
    /// checker: the dictation's versions and the vocabulary first, then those plus the checker.
    private func alternatives(word: String, id: Int) async {
        let before = self.before, after = self.after
        guard let tapped = WordAtCursor.find(contextBefore: before, contextAfter: after) else {
            if id == generation { publish([], []) }
            return
        }
        let texts = controller.lastDictationTexts
        let location = texts.count > 1
            ? DictationLocator.locate(
                texts: texts, contextBefore: before, contextAfter: after, word: tapped, preferred: controller.shownVersionIndex)
            : nil
        var sources: [any AlternativeSource] = []
        if let location, let index = Self.tokenIndex(of: location, in: texts) {
            sources.append(VersionWordsSource(texts: texts, shown: location.version, wordIndex: index))
        }
        if let vocabulary = resources.vocabulary { sources.append(vocabulary) }

        let sentence = before + after
        let start = sentence.index(sentence.startIndex, offsetBy: before.count - tapped.charsBefore)
        let range = start..<sentence.index(start, offsetBy: tapped.word.count)
        let context = AlternativeContext(sentence: sentence, wordRange: range, languages: languages)

        if !sources.isEmpty {
            let quick = await WordAlternatives.rank(word: tapped.word, context: context, sources: sources)
            guard !Task.isCancelled, id == generation else { return }
            if !quick.isEmpty { publish(alternatives: quick, tapped: tapped, before: before, after: after, location: location, texts: texts) }
        }
        sources.append(SpellCheckerSource(checker: PlatformSpellChecker()))
        let ranked = await WordAlternatives.rank(word: tapped.word, context: context, sources: sources)
        guard !Task.isCancelled, id == generation else { return }
        publish(alternatives: ranked, tapped: tapped, before: before, after: after, location: location, texts: texts)
    }

    private static func tokenIndex(of location: DictationLocator.Location, in texts: [String]) -> Int? {
        let text = texts[location.version]
        let lo = text.index(text.startIndex, offsetBy: location.start)
        let hi = text.index(lo, offsetBy: location.length)
        return VersionWordsSource.tokenIndex(of: lo..<hi, in: text)
    }

    private func publish(
        alternatives ranked: [RankedAlternative], tapped: WordAtCursor, before: String, after: String,
        location: DictationLocator.Location?, texts: [String]
    ) {
        let replacements = ranked.map { alt -> Action in
            let span = replacementSpan(for: alt, tapped: tapped, before: before, after: after, location: location, texts: texts)
            return .replace(
                original: String(before.suffix(span.before)) + String(after.prefix(span.after)), span: span,
                fromVocabulary: alt.source == .vocabulary)
        }
        publish(ranked.map(\.text), replacements)
    }

    // MARK: Spans

    /// The words an alternative replaces: the tapped word, or more when the alternative stands for several
    /// ("kuber netties" for "Kubernetes"; a stretch the dictation's other version words differently).
    private func replacementSpan(
        for alt: RankedAlternative, tapped: WordAtCursor, before: String, after: String,
        location: DictationLocator.Location?, texts: [String]
    ) -> WordSpan {
        func expanded(_ left: Int, _ right: Int) -> WordSpan {
            WordSpanExpansion.span(contextBefore: before, contextAfter: after, tapped: tapped, left: left, right: right)
        }
        func text(of span: WordSpan) -> String { String(before.suffix(span.before)) + String(after.prefix(span.after)) }
        switch alt.source {
        case .spellChecker:
            return tapped.span
        case .engine:
            // Alignment is quadratic: only for dictations of a size where that is cheap.
            guard let location, texts.allSatisfy({ $0.count < 3_000 }) else { return tapped.span }
            let tappedWords = Self.words(tapped.word)
            for other in texts.indices where other != location.version {
                for block in WordAlignment.substitutions(from: texts[location.version], to: texts[other])
                where Self.words(block.targetText) == Self.words(alt.text) {
                    for p in block.raw.indices where Self.words(block.raw[p]) == tappedWords {
                        let span = expanded(p, block.raw.count - 1 - p)
                        if Self.words(text(of: span)) == Self.words(block.rawText) { return span }
                    }
                }
            }
            return tapped.span
        case .vocabulary:
            guard let matcher = resources.matcher else { return tapped.span }
            var best: (score: Double, span: WordSpan)?
            for left in 0...2 {
                for right in 0...(2 - left) {
                    let span = expanded(left, right)
                    let spanText = text(of: span)
                    guard spanText.split(whereSeparator: { $0 == " " || $0 == "\t" }).count == 1 + left + right else { continue }
                    for match in matcher.candidates(for: spanText, limit: 3)
                    where resources.termTexts[match.termID]?.lowercased() == alt.text.lowercased() {
                        if match.score > (best?.score ?? 0) { best = (match.score, span) }
                    }
                }
            }
            return best?.span ?? tapped.span
        }
    }

    private static func words(_ text: String) -> [String] {
        text.lowercased().split { !($0.isLetter || $0.isNumber) }.map(String.init)
    }

    // MARK: Taps

    /// A slot was tapped; `rank` 0 is the best suggestion.
    func tapped(rank: Int) {
        let words = controller.suggestions
        guard words.indices.contains(rank) else { return }
        let word = words[rank]
        if pinned != nil {
            // The harness's fixed words complete whatever is being typed.
            let prefix = TextContext(documentContextBeforeInput: controller.typing.contextBefore).wordPrefix
            controller.applyEdit(WordEdit.complete(prefix: prefix, with: word), removed: prefix, asTyping: true)
            return
        }
        // Words shown for an earlier state of the field (a key landed since) are not applied: their actions
        // describe a word that is no longer there.
        guard actionsGeneration == generation, actions.count == words.count else { return }
        switch actions[rank] {
        case .complete(let prefix):
            guard let edit = WordEdit.complete(prefix: prefix, with: word, contextBefore: controller.typing.contextBefore) else { return }
            controller.applyEdit(edit, removed: prefix, asTyping: true)
        case .replace(let original, let span, let fromVocabulary):
            controller.applyEdit(
                WordEdit.replace(span: span, with: word, matchingCaseOf: original), removed: original, asTyping: false)
            controller.recordChoice(ChoiceRecord(original: original, chosen: word, fromVocabulary: fromVocabulary, at: Date()))
            clear() // until the next intent
        }
    }

    // MARK: Learning from typing

    func typed(_ text: String) {
        guard learnsHere else { return }
        if let sentence = typedBuffer.typed(text) { learn(sentence) }
    }

    func deletedTyped() {
        guard learnsHere else { return }
        typedBuffer.deleted()
    }

    /// A completion or prediction replaced the last `count` typed characters with `text`: it counts as typed.
    func completed(deleting count: Int, with text: String) {
        guard learnsHere else { return }
        if let sentence = typedBuffer.completed(deleting: count, with: text) { learn(sentence) }
    }

    /// The typing is being undone: what was typed so far is dropped, not learned.
    func discardTyping() {
        typedBuffer.discard()
    }

    /// The cursor moved, the field changed or the host edited the text: what was typed so far is learned.
    func interruptTyping() {
        if let sentence = typedBuffer.interrupted(), learnsHere { learn(sentence) }
    }

    /// Writes are chained, so the one writer never works on two sentences at once.
    private func learn(_ sentence: String) {
        guard let directory = container else { return }
        let url = directory.appending(path: Self.typedFile)
        let previous = writeChain
        writeChain = Task { [weak self] in
            _ = await previous?.value
            guard let self else { return }
            // A file changed behind the store's back (the app wiped it) starts a fresh store, which reads it again.
            let stamp = Self.modified(url)
            if self.typedStore == nil || stamp != self.typedWrittenStamp {
                self.typedStore = WordPairStore(fileURL: url, languages: self.languages)
            }
            guard let store = self.typedStore else { return }
            try? await store.observe(text: sentence)
            self.typedWrittenStamp = Self.modified(url)
            self.lastCheck = .distantPast // the next row reads the new pairs
        }
    }
}
