import Foundation
import LegatoCore
import LegatoFieldEdit
import LegatoPostProcessing

/// The cleanup agent: a ``FieldAgent`` that rewrites the run's text one finished sentence at a time on the app's one
/// rolling ``LLMSession`` and turns each rewrite into the smallest field patches (spike #95).
///
/// - **Endpointing.** A ``SentenceEndpointer`` decides when a sentence of the run's final text is finished (more
///   text follows it, terminal punctuation, a run-on at the word limit, or a pause). Tentative text is never
///   offered. A run-on or a pause cuts the text there, so what follows is the next sentence.
/// - **Turns.** Each finished sentence is one user turn (`User: <sentence>`), the reply the rewritten sentence in
///   plain text (`Assistant: <sentence>`). The session's head holds the instructions and few-shot pairs for the
///   run's style (``CleanupPrompt/Agent/sessionHead(locale:style:emoji:itn:)``); the earlier turns are the context.
///   Before every turn the session is trimmed to stay within ``Options/contextShare`` percent of the backend's
///   budget, dropping the oldest turns and keeping the head.
/// - **Patches.** A rewrite the ``RewriteGuard`` lets through is diffed word by word against the recognized
///   sentence (``RewritePatch``): one transaction per sentence (one conflict never blocks the others), origin
///   `.agent`, owner the run, every step's `expect` the replaced text, based on the version and session the sentence
///   was read at. A reply that fails, times out, is empty or drifts changes nothing.
/// - **The user's text is authoritative.** A sentence the user touched is never edited again; an edit handed back
///   for a conflict is planned again once, then given up; a superseded or out-of-window edit is planned again.
/// - **Stop.** ``finish()`` sends every sentence not checked yet through the same turns, the unfinished last one
///   included. In ``Mode/replace`` nothing is asked while listening: at stop the whole run's text is rewritten
///   through the same session (in chunks that fit the context share) and lands as minimal patches, grouped and
///   guarded per sentence.
///
/// The session is injected and never created or closed here (`SelectedModelWarmup` owns it for the app's lifetime).
/// One agent per run: its options are frozen when it is made.
///
/// Which text is the run's. Only text the agent can prove is the run's is ever edited: the span that the feed
/// attributes to a non-user origin (ASR). A resync batch and a reset carry no attribution, so the run is
/// re-anchored conservatively: its last known text must occur exactly once in the new window, else nothing is
/// the run's until new ASR text lands. The whole window is never taken as the run's. **Integration requirement:**
/// make the first `consume` before the run's first text reaches the field (an empty sync); text already in the
/// field at the first sync cannot be attributed from a resync (no events) and is never edited.
public actor CleanupAgent: FieldAgent {
    /// How the run is cleaned.
    public enum Mode: Sendable, Equatable {
        /// Sentence by sentence while dictating, the rest at stop.
        case live
        /// Once, at stop: the whole text rewritten (it reads as a full rewrite, but lands as minimal patches).
        case replace
    }

    /// What a run freezes at its start.
    public struct Options: Sendable, Equatable {
        /// The run the agent's edits belong to (``EditTransaction/owner``).
        public var owner: String
        public var locale: Locale
        /// The most one model turn may take; a turn past it keeps the raw text.
        public var timeout: Duration
        /// The writing style, automatic-emoji setting and number normalization the run was started with (they shape
        /// the session's head, see ``sessionHead(for:)``).
        public var style: CleanupStyle
        public var emoji: MessageEmojiStyle
        public var itn: Bool
        public var mode: Mode
        public var endpoint: SentenceEndpointer.Config
        /// The share of the session's token budget a turn may hold, in percent.
        public var contextShare: Int

        public init(
            owner: String, locale: Locale = Locale(identifier: "en"), timeout: Duration = .seconds(5),
            style: CleanupStyle = .verbatim, emoji: MessageEmojiStyle = .off, itn: Bool = false, mode: Mode = .live,
            endpoint: SentenceEndpointer.Config = .init(), contextShare: Int = RewriteContext.share
        ) {
            self.owner = owner
            self.locale = locale
            self.timeout = timeout
            self.style = style
            self.emoji = emoji
            self.itn = itn
            self.mode = mode
            self.endpoint = endpoint
            self.contextShare = contextShare
        }

        /// The run's cleanup settings, frozen: the setting's per-stage limit is the turn timeout, Replace delivery
        /// is ``Mode/replace``, every other delivery ``Mode/live``.
        public init(_ cleanup: CleanupOptions, owner: String, locale: Locale) {
            self.init(
                owner: owner, locale: locale, timeout: .seconds(cleanup.timeoutSeconds), style: cleanup.style,
                emoji: cleanup.emoji, itn: cleanup.itn, mode: cleanup.delivery == .replace ? .replace : .live)
        }
    }

    /// The head the run's session must have (instructions and examples for its style).
    public static func sessionHead(for options: Options) -> [LLMSessionChunk] {
        CleanupPrompt.Agent.sessionHead(locale: options.locale, style: options.style, emoji: options.emoji, itn: options.itn)
    }

    private struct Segment {
        var location: Int
        var text: String
        var isLast: Bool
        var span: Span { Span(location: location, length: text.utf16.count) }
    }

    private struct Planned {
        var old: String
        /// The texts the rewrite settled (the rewrite and each sentence of it).
        var settled: [String]
    }

    private enum Writer { case asr, agent, user, other }

    private let session: any LLMSession
    private let options: Options
    private let endpointer: SentenceEndpointer
    private let now: @Sendable () -> ContinuousClock.Instant
    private let wake: (@Sendable () async -> Void)?

    // The agent's copy of the field, folded from the feed.
    private var sessionID: UUID?
    private var version = FieldVersion(0)
    private var window = ""
    private var lastSeq = 0
    /// The run's own text: the spans the queue wrote for non-user origins, sorted, never touching each other.
    private var runs: [Span] = []
    /// What the user wrote or changed; the sentences touching it are never edited.
    private var touched: [Span] = []
    /// UTF-16 units at the end of the run's last span that are tentative: never offered to the model.
    private var tentativeTail = 0
    /// Where the endpointer cut unpunctuated text (a pause, a run-on): the text after a cut is the next sentence.
    private var cuts: [Int] = []
    /// When recognized text last changed the run's text (for the pause).
    private var lastHeard: ContinuousClock.Instant?

    // What the model has decided.
    private var pending: [UUID: Planned] = [:]
    /// Sentence texts that need nothing more: rewritten, found right, rejected, or given up.
    private var reviewed: Set<String> = []
    /// Sentences whose turn failed or timed out: not asked again while listening, retried at stop.
    private var skipped: Set<String> = []
    private var attempts: [String: Int] = [:]
    private var busy = false
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []
    private var pauseTimer: Task<Void, Never>?

    /// - Parameters:
    ///   - now: the clock the pause is measured on.
    ///   - wake: called once the speaker has paused for the endpointer's pause after recognized text, so the run
    ///     asks again (``replan()``) without waiting for new text. Nil: a pause is only seen at the next batch.
    public init(
        session: any LLMSession, options: Options, now: @escaping @Sendable () -> ContinuousClock.Instant = { .now },
        wake: (@Sendable () async -> Void)? = nil
    ) {
        self.session = session
        self.options = options
        self.endpointer = SentenceEndpointer(config: options.endpoint)
        self.now = now
        self.wake = wake
    }

    // MARK: FieldAgent

    /// Takes in a feed batch and, in Live mode, rewrites the run's next finished sentences. A turn already in flight
    /// makes this a feed-only call (nothing returned): ask again with ``replan()`` or the next batch.
    public func consume(_ batch: FeedBatch) async -> [EditTransaction] {
        if batch.resync || batch.session != sessionID {
            guard batch.resync, let text = batch.window else { return [] }  // Another queue, no window: wait for a resync.
            adopt(text, batch)
        } else {
            for entry in batch.entries where entry.seq > lastSeq {
                lastSeq = entry.seq
                apply(entry.event)
            }
            version = batch.version
        }
        let made = await pass(final: false)
        schedulePauseWake()
        return made
    }

    public func conflicted(_ conflict: Conflict, for transaction: UUID) async {
        handBack(transaction, counts: Self.counts(conflict))
    }

    public func superseded(_ transaction: UUID, by landed: UUID) async {
        handBack(transaction, counts: false)
    }

    // MARK: Entry points beyond the protocol

    /// The writer shows `length` UTF-16 units of tentative text at the end of the run's text. It is left out of
    /// what the model sees until it is final (`length` 0), so no edit lands in text the engine is about to replace.
    public func setTentative(length: Int) {
        tentativeTail = max(0, length)
    }

    /// Asks again from what the agent knows now (after a conflict, a supersede or a pause, without waiting for a batch).
    public func replan() async -> [EditTransaction] {
        await pass(final: false)
    }

    /// The stop: Live sends every sentence not checked yet through the same turns, the unfinished last one included
    /// (a sentence whose turn failed while listening is tried once more); Replace rewrites the whole run's text.
    /// Each turn has the run's timeout; the raw text stays where it runs out.
    public func finish() async -> [EditTransaction] {
        pauseTimer?.cancel()
        while busy { await withCheckedContinuation { idleWaiters.append($0) } }  // A turn in flight finishes first.
        return await pass(final: true)
    }

    // MARK: Feed

    private func adopt(_ text: String, _ batch: FeedBatch) {
        // Another queue instance may be another field: its window is no place to look for this run's text.
        let sameQueue = sessionID == batch.session
        let anchored = sameQueue ? reanchored(in: text) : nil
        sessionID = batch.session
        version = batch.version
        window = text
        lastSeq = batch.lastSeq ?? 0
        pending = [:]
        runs = anchored?.runs ?? []
        touched = anchored?.touched ?? []
        cuts = anchored?.cuts ?? []
    }

    /// Each run span and the user-touched spans and cuts inside it, found again in `text` after a resync or reset: a
    /// span only when its last known text occurs exactly once there; the others are dropped.
    private func reanchored(in text: String) -> (runs: [Span], touched: [Span], cuts: [Int]) {
        let old = window as NSString, new = text as NSString
        var kept: [Span] = [], inside: [Span] = [], movedCuts: [Int] = []
        // A span part of which left the window (iOS: negative offsets) has no known text to look for.
        for run in runs where run.length > 0 && run.location >= 0 && run.end <= old.length {
            let known = old.substring(with: NSRange(location: run.location, length: run.length))
            var found: [Int] = []
            var from = 0
            while from < new.length, found.count < 2 {
                let hit = new.range(of: known, options: [.literal], range: NSRange(location: from, length: new.length - from))
                guard hit.location != NSNotFound else { break }
                found.append(hit.location)
                from = hit.location + 1
            }
            guard found.count == 1, let location = found.first else { continue }
            let shift = location - run.location
            kept.append(Span(location: location, length: run.length))
            for span in touched {
                // A deletion at the run's edge is outside it.
                if span.length == 0 {
                    if span.location > run.location && span.location < run.end { inside.append(Span(location: span.location + shift, length: 0)) }
                    continue
                }
                let start = max(span.location, run.location), end = min(span.end, run.end)
                if start < end { inside.append(Span(location: start + shift, length: end - start)) }
            }
            movedCuts += cuts.filter { $0 > run.location && $0 <= run.end }.map { $0 + shift }
        }
        return (Self.merged(kept), inside, movedCuts.sorted())
    }

    /// Spans sorted, with overlapping or touching ones joined.
    private static func merged(_ spans: [Span]) -> [Span] {
        var out: [Span] = []
        for span in spans.sorted(by: { $0.location < $1.location }) {
            if let last = out.last, span.location <= last.end {
                out[out.count - 1] = Span(location: last.location, length: max(last.end, span.end) - last.location)
            } else {
                out.append(span)
            }
        }
        return out
    }

    private func apply(_ event: FeedEvent) {
        switch event {
        case .asrDelta:
            break
        case .applied(let id, let origin, let steps, _):
            pending.removeValue(forKey: id)
            let writer: Writer = origin.isUser ? .user : origin == .agent ? .agent : .asr
            for step in steps { fold(step, as: writer) }
        case .foreign(let step, let byUser, _):
            fold(step, as: byUser ? .user : .other)
        case .conflict(let id, let conflict):
            handBack(id, counts: Self.counts(conflict))
        case .superseded(let id, _), .withdrawn(let id):
            handBack(id, counts: false)
        case .rebased(let text, let shift, _):
            window = text
            runs = runs.map { Span(location: $0.location + shift, length: $0.length) }
            touched = touched.map { Span(location: $0.location + shift, length: $0.length) }
            cuts = cuts.map { $0 + shift }
        case .reset(let reason, let text, _):
            let anchored = reason == .cleared ? nil : reanchored(in: text)
            window = text
            pending = [:]
            runs = anchored?.runs ?? []
            touched = anchored?.touched ?? []
            cuts = anchored?.cuts ?? []
        }
    }

    /// Whether a conflict goes toward giving its sentence up. `outOfWindow` does not: the queue could not map the
    /// edit from its base (the field moved on under a long turn, a reset): no one disagreed with it.
    private static func counts(_ conflict: Conflict) -> Bool { conflict.reason != .outOfWindow }

    /// A planned edit that did not land. Only a real conflict (`counts`) goes toward giving the sentence up; a
    /// superseded or withdrawn edit is planned again at no cost.
    private func handBack(_ id: UUID, counts: Bool) {
        guard let planned = pending.removeValue(forKey: id) else { return }
        for text in planned.settled where text != planned.old { reviewed.remove(text) }
        let tries = attempts[planned.old, default: 0] + (counts ? 1 : 0)
        attempts[planned.old] = tries
        if tries >= 2 {
            reviewed.insert(planned.old)  // Gave up on this sentence: it stays as it is.
        } else {
            reviewed.remove(planned.old)
        }
    }

    private func fold(_ step: EditStep, as writer: Writer) {
        var units = Array(window.utf16)
        guard step.span.location >= 0, step.span.length >= 0, step.span.end <= units.count else { return }
        units.replaceSubrange(step.span.location..<step.span.end, with: step.text.utf16)
        window = String(decoding: units, as: UTF16.self)
        runs = runs.map { Self.mapped($0, through: step) }
        touched = touched.map { Self.mapped($0, through: step) }
        cuts = cuts.map { Self.mappedCut($0, through: step, pushed: writer == .agent) }
        let result = Span(location: step.span.location, length: step.text.utf16.count)
        switch writer {
        case .asr, .agent:
            // A new run write joins a span it touches; otherwise it is a span of its own.
            if result.length > 0 { runs = Self.merged(runs + [result]) }
            if writer == .asr { lastHeard = now() }
        case .user: touched.append(result)
        case .other: break
        }
    }

    /// `span` after `step` landed: unchanged before it, shifted after it, grown or shrunk around it when they overlap.
    static func mapped(_ span: Span, through step: EditStep) -> Span {
        let start = step.span.location, end = step.span.end, delta = step.text.utf16.count - step.span.length
        if span.end <= start { return span }
        if span.location >= end { return Span(location: span.location + delta, length: span.length) }
        let location = min(span.location, start)
        return Span(location: location, length: max(span.end, end) + delta - location)
    }

    /// A cut after `step`: an agent edit that ends at it or covers it (the sentence before it rewritten) moves it to
    /// the edit's end; recognized text that lands at it stays after it (it starts the next sentence).
    static func mappedCut(_ cut: Int, through step: EditStep, pushed: Bool) -> Int {
        let start = step.span.location, end = step.span.end, delta = step.text.utf16.count - step.span.length
        if cut < start || (cut == start && !(pushed && step.span.length == 0)) { return cut }
        if cut > end || (cut == end && !pushed) { return cut + delta }
        return start + step.text.utf16.count
    }

    // MARK: Sentences

    /// The run's final text as sentences: split by its punctuation and the endpointer's cuts, trimmed. Tentative
    /// text is left out; a sentence cut by the window's start (iOS) is left out.
    private func segments() -> [Segment] {
        guard sessionID != nil, !runs.isEmpty else { return [] }
        let text = window as NSString
        var found: [Segment] = []
        let cuts = cuts
        for (index, run) in runs.enumerated() {
            let tentative = index == runs.count - 1 ? min(tentativeTail, run.length) : 0
            // Clipped by hand: `NSIntersectionRange` takes a negative location as a huge one.
            let start = max(run.location, 0), end = min(run.end - tentative, text.length)
            guard end > start else { continue }
            var first = run.location < 0
            text.enumerateSubstrings(in: NSRange(location: start, length: end - start), options: .bySentences) { _, range, _, _ in
                var bounds = [range.location]
                bounds += cuts.filter { $0 > range.location && $0 < range.location + range.length }
                bounds.append(range.location + range.length)
                for (lower, upper) in zip(bounds, bounds.dropFirst()) {
                    let body = Self.trimmed(NSRange(location: lower, length: upper - lower), in: text)
                    if body.length > 0, !first {
                        found.append(Segment(location: body.location, text: text.substring(with: body), isLast: false))
                    }
                    first = false
                }
            }
        }
        if !found.isEmpty { found[found.count - 1].isLast = true }
        return found
    }

    /// The first sentence to ask about now, or nil. A sentence ready by a pause or the word limit gets a cut at its
    /// end, so the text after it is the next one.
    private func nextReady(final: Bool, tried: Set<String>) -> Segment? {
        let quiet = tentativeTail > 0 ? Duration.zero : lastHeard.map { now() - $0 } ?? .zero
        for segment in segments() {
            if touched.contains(where: { Self.touches($0, segment.span) }) { continue }
            if reviewed.contains(segment.text) || tried.contains(segment.text) { continue }
            if !final, skipped.contains(segment.text) { continue }
            guard let reason = endpointer.ready(segment.text, isLast: segment.isLast, quiet: quiet, final: final) else { continue }
            if reason == .pause || reason == .length || reason == .end {
                let end = segment.span.end
                if !cuts.contains(end) { cuts = (cuts + [end]).sorted() }
            }
            return segment
        }
        return nil
    }

    /// After recognized text, a wake once the pause has passed (the next batch may never come).
    private func schedulePauseWake() {
        guard let wake, options.mode == .live else { return }
        pauseTimer?.cancel()
        guard let last = segments().last, !reviewed.contains(last.text), !skipped.contains(last.text),
              endpointer.ready(last.text, isLast: true, quiet: .zero, final: false) == nil
        else { return }
        let pause = options.endpoint.pause
        pauseTimer = Task {
            try? await Task.sleep(for: pause + .milliseconds(20))
            guard !Task.isCancelled else { return }
            await wake()
        }
    }

    // MARK: Turns

    private func pass(final: Bool) async -> [EditTransaction] {
        guard !busy else { return [] }
        if options.mode == .replace && !final { return [] }
        busy = true
        defer {
            busy = false
            let waiting = idleWaiters
            idleWaiters = []
            for waiter in waiting { waiter.resume() }
        }
        if options.mode == .replace { return await rewriteRun() }
        var made: [EditTransaction] = []
        var tried: Set<String> = []
        while let segment = nextReady(final: final, tried: tried) {
            tried.insert(segment.text)
            made += await turn(segment, final: final)
            if Task.isCancelled { return [] }
            // While listening, an edit goes out as soon as there is one.
            if !final, !made.isEmpty { break }
        }
        return made
    }

    /// One sentence through the model: its rewrite as one transaction, or nothing.
    private func turn(_ segment: Segment, final: Bool) async -> [EditTransaction] {
        guard let sessionID else { return [] }
        let base = version
        guard let reply = await ask(segment.text, kind: "agent", final: final) else {
            skipped.insert(segment.text)
            return []
        }
        skipped.remove(segment.text)
        guard let rewrite = RewriteReply.clean(reply, keepLineBreaks: options.style == .markdown),
              RewriteGuard.accepts(rewrite, reference: segment.text)
        else {
            reviewed.insert(segment.text)  // Drifted or empty: the sentence stays as heard.
            CleanupCallTrace.emit("agent.reject", ["final": final ? "1" : "0", "inChars": String(segment.text.count)])
            return []
        }
        let settled = [rewrite] + Self.sentences(of: rewrite)
        reviewed.insert(segment.text)
        reviewed.formUnion(settled)
        let steps = RewritePatch.steps(segment.text, rewrite, at: segment.location)
        guard !steps.isEmpty else { return [] }
        let transaction = EditTransaction(origin: .agent, owner: options.owner, base: base, steps: steps, session: sessionID)
        pending[transaction.id] = Planned(old: segment.text, settled: settled)
        return [transaction]
    }

    /// Replace: the run's whole text, rewritten in chunks that fit the context share, as minimal patches grouped
    /// and guarded per sentence; a sentence the user touched is left as it is.
    private func rewriteRun() async -> [EditTransaction] {
        guard let sessionID else { return [] }
        let base = version
        let rewriter = PassageRewriter(session: session, options: options)
        var made: [EditTransaction] = []
        for region in runRegions() {
            for group in await rewriter.groups(region.text, at: region.location) {
                guard !group.steps.contains(where: { step in touched.contains { Self.touches($0, step.span) } }) else { continue }
                let transaction = EditTransaction(origin: .agent, owner: options.owner, base: base, steps: group.steps, session: sessionID)
                pending[transaction.id] = Planned(old: group.reference, settled: [])
                made.append(transaction)
            }
        }
        return made
    }

    /// Each run span's visible, final text, trimmed.
    private func runRegions() -> [(location: Int, text: String)] {
        guard sessionID != nil else { return [] }
        let text = window as NSString
        var out: [(Int, String)] = []
        for (index, run) in runs.enumerated() {
            let tentative = index == runs.count - 1 ? min(tentativeTail, run.length) : 0
            let start = max(run.location, 0), end = min(run.end - tentative, text.length)
            guard end > start else { continue }
            let body = Self.trimmed(NSRange(location: start, length: end - start), in: text)
            if body.length > 0 { out.append((body.location, text.substring(with: body))) }
        }
        return out
    }

    /// The reply to `request` as one user turn, within the run's timeout, after trimming the session to the context
    /// share; nil when it failed or timed out.
    private func ask(_ request: String, kind: String, final: Bool) async -> String? {
        await PassageRewriter(session: session, options: options).ask(request, kind: kind, final: final)
    }

    // MARK: Text helpers

    static func sentences(of text: String) -> [String] {
        var out: [String] = []
        let string = text as NSString
        string.enumerateSubstrings(in: NSRange(location: 0, length: string.length), options: .bySentences) { _, range, _, _ in
            let body = trimmed(range, in: string)
            if body.length > 0 { out.append(string.substring(with: body)) }
        }
        return out
    }

    static func trimmed(_ range: NSRange, in text: NSString) -> NSRange {
        var start = range.location, end = range.location + range.length
        func isSpace(_ index: Int) -> Bool {
            guard let scalar = Unicode.Scalar(text.character(at: index)) else { return false }
            return CharacterSet.whitespacesAndNewlines.contains(scalar)
        }
        while start < end, isSpace(start) { start += 1 }
        while end > start, isSpace(end - 1) { end -= 1 }
        return NSRange(location: start, length: end - start)
    }

    /// Whether `span` is where the user wrote or deleted: sentences touching it are never edited.
    private static func touches(_ touched: Span, _ sentence: Span) -> Bool {
        if touched.length == 0 { return touched.location >= sentence.location && touched.location <= sentence.end }
        return touched.location < sentence.end && touched.end > sentence.location
    }
}

/// A whole text rewritten at once on the rolling session (Replace, and a run whose agent was absent at stop): in
/// chunks of whole sentences that fit the context share, each a user turn closed by
/// ``CleanupPrompt/Agent/finalRequestLine``; the reply diffed into patches, grouped by the sentence they start in,
/// and each group kept only when the ``RewriteGuard`` lets that sentence's rewrite through.
public struct PassageRewriter: Sendable {
    /// One sentence's accepted patches.
    public struct Group: Sendable, Equatable {
        /// The sentence as recognized.
        public var reference: String
        public var steps: [EditStep]
    }

    /// The largest chunk one turn rewrites, in estimated tokens (the reply decodes at about 20 tokens a second on
    /// the phone, so a chunk stays within a few seconds).
    public static let chunkTokens = 160

    let session: any LLMSession
    let options: CleanupAgent.Options

    public init(session: any LLMSession, options: CleanupAgent.Options) {
        self.session = session
        self.options = options
    }

    /// `text` cleaned, or nil when nothing changed or no turn answered.
    public func cleaned(_ text: String) async -> String? {
        let groups = await groups(text, at: 0)
        guard !groups.isEmpty else { return nil }
        var units = Array(text.utf16)
        for step in groups.flatMap(\.steps).sorted(by: { $0.span.location > $1.span.location }) {
            units.replaceSubrange(step.span.location..<step.span.end, with: step.text.utf16)
        }
        let out = String(decoding: units, as: UTF16.self)
        return out == text ? nil : out
    }

    /// The accepted patch groups for `text`, which starts at UTF-16 offset `location` of the field.
    public func groups(_ text: String, at location: Int) async -> [Group] {
        var out: [Group] = []
        for chunk in chunks(text) {
            guard let reply = await ask(CleanupPrompt.Agent.finalRequest(chunk.text), kind: "final", final: true),
                  let rewrite = RewriteReply.clean(reply, keepLineBreaks: true)
            else { continue }
            out += Self.guardedGroups(chunk.text, rewrite, at: location + chunk.location)
        }
        return out
    }

    /// `rewrite`'s patches against `old`, grouped by the sentence of `old` each starts in; a group whose sentence
    /// rewrite the guard rejects is left out.
    static func guardedGroups(_ old: String, _ rewrite: String, at location: Int) -> [Group] {
        let string = old as NSString
        var sentences: [NSRange] = []
        string.enumerateSubstrings(in: NSRange(location: 0, length: string.length), options: .bySentences) { _, range, _, _ in
            sentences.append(range)
        }
        guard !sentences.isEmpty else { return [] }
        let hunks = RewritePatch.hunks(old, rewrite)
        let oldUnits = Array(old.utf16), newUnits = Array(rewrite.utf16)
        func sentence(of hunk: RewritePatch.Hunk) -> Int {
            // The sentence holding the first replaced word; an insertion belongs to the word before it.
            sentences.lastIndex(where: { $0.location <= hunk.anchor }) ?? 0
        }
        var byIndex: [Int: [RewritePatch.Hunk]] = [:]
        for hunk in hunks { byIndex[sentence(of: hunk), default: []].append(hunk) }
        var groups: [Group] = []
        for index in byIndex.keys.sorted() {
            let own = byIndex[index]!
            let range = sentences[index]
            let lower = range.location, upper = range.location + range.length
            var candidate = Array(oldUnits[lower..<upper])
            for hunk in own.reversed() {
                let from = min(max(hunk.old.lowerBound, lower), upper) - lower
                let to = min(max(hunk.old.upperBound, lower), upper) - lower
                candidate.replaceSubrange(from..<max(from, to), with: newUnits[hunk.new])
            }
            let reference = String(decoding: oldUnits[lower..<upper], as: UTF16.self).trimmingCharacters(in: .whitespacesAndNewlines)
            let rewritten = String(decoding: candidate, as: UTF16.self).trimmingCharacters(in: .whitespacesAndNewlines)
            guard RewriteGuard.accepts(rewritten, reference: reference) else { continue }
            let steps = own.compactMap { hunk in
                ContiguousPatch.between(
                    String(decoding: oldUnits[hunk.old], as: UTF16.self), String(decoding: newUnits[hunk.new], as: UTF16.self),
                    at: location + hunk.old.lowerBound)
            }
            if !steps.isEmpty { groups.append(Group(reference: reference, steps: steps)) }
        }
        return groups
    }

    /// Consecutive whole sentences of `text`, each chunk at most ``chunkTokens`` (or the context share's room) unless
    /// one sentence alone is longer. Locations are UTF-16 offsets into `text`.
    func chunks(_ text: String) -> [(location: Int, text: String)] {
        let string = text as NSString
        let limit = max(32, min(Self.chunkTokens, RewriteContext.budget(tokenBudget: session.tokenBudget, share: options.contextShare) / 4))
        var out: [(Int, String)] = []
        var start: Int?
        var end = 0
        func flush() {
            guard let from = start else { return }
            let body = CleanupAgent.trimmed(NSRange(location: from, length: end - from), in: string)
            if body.length > 0 { out.append((body.location, string.substring(with: body))) }
            start = nil
        }
        string.enumerateSubstrings(in: NSRange(location: 0, length: string.length), options: .bySentences) { _, range, _, _ in
            if let from = start,
               RewriteContext.estimatedTokens(string.substring(with: NSRange(location: from, length: range.location + range.length - from))) > limit {
                flush()
            }
            if start == nil { start = range.location }
            end = range.location + range.length
        }
        flush()
        return out
    }

    /// One user turn within the run's timeout, after trimming the session to the context share; nil when the turn
    /// failed or timed out.
    func ask(_ request: String, kind: String, final: Bool) async -> String? {
        let session = session, timeout = options.timeout
        let start = ContinuousClock.now
        var trimmedTo: Int?
        do {
            let usage = try await session.usage()
            let budget = RewriteContext.budget(tokenBudget: session.tokenBudget, share: options.contextShare)
            if let keep = RewriteContext.trimTarget(usage: usage, request: RewriteContext.estimatedTokens(request), budget: budget) {
                try await session.trim(keepingSuffix: keep)
                trimmedTo = keep
            }
        } catch {
            CleanupCallTrace.emit("cleanup.call", ["kind": kind, "final": final ? "1" : "0", "outcome": "failed", "ms": "0"])
            return nil
        }
        enum Reply: Sendable { case text(String), timedOut, failed }
        let reply = await withTaskGroup(of: Reply.self) { group in
            group.addTask {
                do { return .text(try await session.respond(to: request)) } catch { return .failed }
            }
            group.addTask {
                do {
                    try await Task.sleep(for: timeout)
                    return .timedOut
                } catch { return .failed }
            }
            let first = await group.next() ?? .failed
            group.cancelAll()
            return first
        }
        let outcome: String, text: String?
        switch reply {
        case .text(let answer): outcome = "text"; text = answer
        case .timedOut: outcome = "timedOut"; text = nil
        case .failed: outcome = "failed"; text = nil
        }
        var fields = [
            "kind": kind, "final": final ? "1" : "0", "backend": String(describing: type(of: session)),
            "ms": CleanupCallTrace.milliseconds(since: start), "outcome": outcome, "inChars": String(request.count),
        ]
        if let trimmedTo { fields["trimmedTo"] = String(trimmedTo) }
        CleanupCallTrace.emit("cleanup.call", fields)
        return text
    }
}
