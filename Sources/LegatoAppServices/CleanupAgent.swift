import Foundation
import LegatoCore
import LegatoFieldEdit
import LegatoPostProcessing

/// The Live-mode cleanup agent: a ``FieldAgent`` that reads the change feed into the app's one rolling
/// ``LLMSession`` and turns the model's sentence rewrites into the smallest field patches.
///
/// - The session is injected and never created, trimmed early or closed here (`SelectedModelWarmup` owns it for
///   the app's lifetime); the agent only appends context and asks, and trims at the token budget keeping the
///   newest context.
/// - The model sees the run's text as numbered sentences and answers `[{sentence: n, text: "…"}]`
///   (``SentenceEdit``). It never computes positions: each rewritten sentence becomes one `ContiguousPatch` step
///   at the sentence's known UTF-16 location, in its own transaction (one conflict never blocks the others),
///   origin `.agent`, owner the run, `expect` the replaced text, based on the newest batch's version and session.
/// - The user's text is authoritative: a sentence the user touched is locked and never edited again; a conflict
///   caused by the user is noted in the session; a superseded or handed-back edit is planned again from the feed.
/// - A model that fails, answers off-schema or out of range, or exceeds the run's timeout changes nothing: the raw
///   text stays.
///
/// One agent per run: its options are frozen when it is made. Call ``finish()`` at stop for the final pass.
///
/// Which text is the run's. Only text the agent can prove is the run's is ever edited: the span that the feed
/// attributes to a non-user origin (ASR). A resync batch and a reset carry no attribution, so the run is
/// re-anchored conservatively: its last known text must occur exactly once in the new window, else nothing is
/// the run's until new ASR text lands. The whole window is never taken as the run's. **Integration (L6)
/// requirement:** make the first `consume` before the run's first text reaches the field (an empty sync); text
/// already in the field at the first sync cannot be attributed from a resync (no events) and is never edited.
public actor CleanupAgent: FieldAgent {
    /// What a run freezes at its start.
    public struct Options: Sendable, Equatable {
        /// The run the agent's edits belong to (``EditTransaction/owner``).
        public var owner: String
        public var locale: Locale
        /// The user's names and terms, for the prompt.
        public var vocabulary: [String]
        /// The most one model pass may take; a pass past it keeps the raw text.
        public var timeout: Duration
        /// The writing style, automatic-emoji setting and number normalization the run was started with.
        public var style: CleanupStyle
        public var emoji: MessageEmojiStyle
        public var itn: Bool

        public init(
            owner: String, locale: Locale = Locale(identifier: "en"), vocabulary: [String] = [], timeout: Duration = .seconds(5),
            style: CleanupStyle = .verbatim, emoji: MessageEmojiStyle = .off, itn: Bool = false
        ) {
            self.owner = owner
            self.locale = locale
            self.vocabulary = vocabulary
            self.timeout = timeout
            self.style = style
            self.emoji = emoji
            self.itn = itn
        }

        /// The run's cleanup settings, frozen: the setting's per-stage limit is the pass timeout.
        public init(_ cleanup: CleanupOptions, owner: String, locale: Locale, vocabulary: [String] = []) {
            self.init(
                owner: owner, locale: locale, vocabulary: vocabulary, timeout: .seconds(cleanup.timeoutSeconds),
                style: cleanup.style, emoji: cleanup.emoji, itn: cleanup.itn)
        }
    }

    private struct Sentence {
        var number: Int
        var location: Int
        var text: String
        var role: CleanupPrompt.Agent.Role
    }

    private struct Plan {
        var version: FieldVersion
        var session: UUID
        var sentences: [Sentence]
        var request: String
    }

    private struct Planned {
        var old: String
        var new: String
    }

    private enum Reply {
        case edits([SentenceEdit])
        case timedOut
        case failed
    }

    private enum Writer { case runText, user, other }

    private let session: any LLMSession
    private let options: Options

    // The agent's copy of the field, folded from the feed.
    private var sessionID: UUID?
    private var version = FieldVersion(0)
    private var window = ""
    private var lastSeq = 0
    /// The run's own text: the spans the queue wrote for non-user origins, sorted, never touching each other.
    /// Text between spans is never the run's.
    private var runs: [Span] = []
    /// What the user wrote or changed; the sentences touching it are locked.
    private var touched: [Span] = []
    /// UTF-16 units at the end of the run's last span that are tentative (not final yet, the engine may still change
    /// them): never offered to the model, so never edited.
    private var tentativeTail = 0

    // What the model has decided about the run's text.
    private var pending: [UUID: Planned] = [:]
    private var reviewed: Set<String> = []
    /// Sentences whose pass failed or timed out: not asked again while listening, retried by the final pass.
    private var skipped: Set<String> = []
    private var attempts: [String: Int] = [:]
    private var busy = false
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []

    public init(session: any LLMSession, options: Options) {
        self.session = session
        self.options = options
    }

    // MARK: FieldAgent

    /// Takes in a feed batch and plans edits for the run's finished, unchecked sentences. A pass already in
    /// flight makes this a feed-only call (nothing returned): ask again with ``replan()`` or the next batch.
    public func consume(_ batch: FeedBatch) async -> [EditTransaction] {
        var context = ""
        if batch.resync || batch.session != sessionID {
            guard batch.resync, let text = batch.window else { return [] }  // Another queue, no window: wait for a resync.
            if sessionID == nil { context = "\n[new dictation run]\n" }  // One run's text apart from the last run's.
            adopt(text, batch)
            context += "\n[field synced]\n"
        } else {
            for entry in batch.entries where entry.seq > lastSeq {
                lastSeq = entry.seq
                context += apply(entry.event)
            }
            version = batch.version
        }
        await append(context)
        return await pass(final: false)
    }

    public func conflicted(_ conflict: Conflict, for transaction: UUID) async {
        await append(handBack(transaction, conflict: conflict, counts: Self.counts(conflict)))
    }

    public func superseded(_ transaction: UUID, by landed: UUID) async {
        _ = handBack(transaction, conflict: nil, counts: false)
    }

    // MARK: Entry points beyond the protocol

    /// Recognized text from outside the feed (iOS: the app's in-process ASR); the feed carries it only as
    /// confirmed field writes.
    public func hear(_ text: String) async {
        await append(text)
    }

    /// The writer shows `length` UTF-16 units of tentative text at the end of the run's text (Mac live streaming).
    /// It is left out of the sentences the model sees until it is final (`length` 0), so no edit lands in text the
    /// engine is about to replace.
    public func setTentative(length: Int) {
        tentativeTail = max(0, length)
    }

    /// Plans again from what the agent knows now (after a conflict or supersede, without waiting for a batch).
    public func replan() async -> [EditTransaction] {
        await pass(final: false)
    }

    /// The final pass at stop: every sentence not yet checked, the unfinished last one included, with the same
    /// timeout (the raw text stays when it runs out). Sentences a rolling pass gave up on are tried once more.
    public func finish() async -> [EditTransaction] {
        while busy { await withCheckedContinuation { idleWaiters.append($0) } }  // A rolling pass in flight finishes first.
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
    }

    /// Each run span and the user-touched spans inside it, found again in `text` after a resync or reset: a
    /// span only when its last known text occurs exactly once there; the others are dropped.
    private func reanchored(in text: String) -> (runs: [Span], touched: [Span]) {
        let old = window as NSString, new = text as NSString
        var kept: [Span] = [], inside: [Span] = []
        for run in runs where run.length > 0 && run.end <= old.length {
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
        }
        return (Self.merged(kept), inside)
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

    private func apply(_ event: FeedEvent) -> String {
        switch event {
        case .asrDelta(let text):
            return text
        case .applied(let id, let origin, let steps, _):
            let landed = pending.removeValue(forKey: id) != nil
            var note = ""
            for step in steps {
                fold(step, as: origin.isUser ? .user : .runText)
                if origin == .agent, landed { note += "\n[applied] \(step.expect) -> \(step.text)\n" }
                if origin.isUser { note += "\n[user] \(step.expect) -> \(step.text)\n" }
            }
            return note
        case .foreign(let step, let byUser, _):
            fold(step, as: byUser ? .user : .other)
            return byUser ? "\n[user] \(step.expect) -> \(step.text)\n" : ""
        case .conflict(let id, let conflict):
            return handBack(id, conflict: conflict, counts: Self.counts(conflict))
        case .superseded(let id, _), .withdrawn(let id):
            return handBack(id, conflict: nil, counts: false)
        case .rebased(let text, let shift, _):
            window = text
            runs = runs.map { Span(location: $0.location + shift, length: $0.length) }
            touched = touched.map { Span(location: $0.location + shift, length: $0.length) }
            return ""
        case .reset(let reason, let text, _):
            let anchored = reason == .cleared ? nil : reanchored(in: text)
            window = text
            pending = [:]
            runs = anchored?.runs ?? []
            touched = anchored?.touched ?? []
            return "\n[field reset: \(reason.rawValue)]\n"
        }
    }

    /// Whether a conflict goes toward giving its sentence up. `outOfWindow` does not: the queue could not map the
    /// edit from its base (the field moved on under a long pass, a reset): no one disagreed with it, so it is
    /// planned again from the newest field.
    private static func counts(_ conflict: Conflict) -> Bool { conflict.reason != .outOfWindow }

    /// A planned edit that did not land. Returns the session note for it. Only a real conflict (`counts`) goes
    /// toward giving the sentence up; a superseded or withdrawn edit is planned again at no cost.
    private func handBack(_ id: UUID, conflict: Conflict?, counts: Bool) -> String {
        guard let planned = pending.removeValue(forKey: id) else { return "" }
        reviewed.remove(planned.new)
        let tries = attempts[planned.old, default: 0] + (counts ? 1 : 0)
        attempts[planned.old] = tries
        if tries >= 2 {
            reviewed.insert(planned.old)  // Gave up on this sentence: it stays as it is.
        } else {
            reviewed.remove(planned.old)
        }
        guard let conflict, conflict.byUser else { return "" }
        return "\n[conflict] \(conflict.note ?? Conflict.userNote) Sentence: \(planned.old)\n"
    }

    private func fold(_ step: EditStep, as writer: Writer) {
        var units = Array(window.utf16)
        guard step.span.location >= 0, step.span.length >= 0, step.span.end <= units.count else { return }
        units.replaceSubrange(step.span.location..<step.span.end, with: step.text.utf16)
        window = String(decoding: units, as: UTF16.self)
        runs = runs.map { Self.mapped($0, through: step) }
        touched = touched.map { Self.mapped($0, through: step) }
        let result = Span(location: step.span.location, length: step.text.utf16.count)
        switch writer {
        case .runText:
            // A new run write joins a span it touches; otherwise it is a span of its own.
            if result.length > 0 { runs = Self.merged(runs + [result]) }
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

    // MARK: Planning

    private func plan(final: Bool) -> Plan? {
        guard let sessionID, !runs.isEmpty else { return nil }
        let text = window as NSString
        var found: [(location: Int, text: String)] = []
        for (index, run) in runs.enumerated() {
            // The newest span ends in the tentative text, if any.
            let cut = index == runs.count - 1 ? min(tentativeTail, run.length) : 0
            let region = NSIntersectionRange(NSRange(location: run.location, length: run.length - cut), NSRange(location: 0, length: text.length))
            guard region.length > 0 else { continue }
            text.enumerateSubstrings(in: region, options: .bySentences) { _, range, _, _ in
                let body = Self.trimmed(range, in: text)
                if body.length > 0 { found.append((body.location, text.substring(with: body))) }
            }
        }
        guard !found.isEmpty else { return nil }
        // The newest sentences that fit the window the context can afford.
        var kept = 0, characters = 0
        for sentence in found.reversed() {
            if kept > 0, characters + sentence.text.count > windowCharacterLimit { break }
            characters += sentence.text.count
            kept += 1
        }
        let shown = found.suffix(kept)

        var sentences: [Sentence] = []
        for (index, sentence) in shown.enumerated() {
            let span = Span(location: sentence.location, length: sentence.text.utf16.count)
            let isLast = sentence.location == found.last?.location
            let role: CleanupPrompt.Agent.Role
            if touched.contains(where: { Self.touches($0, span) }) {
                role = .locked
            } else if (!final && sentence.text.contains(where: \.isNewline)) || reviewed.contains(sentence.text)
                || (!final && skipped.contains(sentence.text))
                || (!final && isLast && !Self.endsSentence(sentence.text))
            {
                role = .keep
            } else {
                role = .review
            }
            sentences.append(Sentence(number: index + 1, location: sentence.location, text: sentence.text, role: role))
        }
        guard sentences.contains(where: { $0.role == .review }) else { return nil }
        let request = CleanupPrompt.Agent.request(
            sentences: sentences.map { .init(number: $0.number, text: $0.text, role: $0.role) },
            locale: options.locale, vocabulary: options.vocabulary,
            style: options.style, emoji: options.emoji, itn: options.itn)
        return Plan(version: version, session: sessionID, sentences: sentences, request: request)
    }

    private func pass(final: Bool) async -> [EditTransaction] {
        guard !busy, let plan = plan(final: final) else { return [] }
        busy = true
        defer {
            busy = false
            let waiting = idleWaiters
            idleWaiters = []
            for waiter in waiting { waiter.resume() }
        }

        guard await makeRoom(for: plan.request) else { return fail(plan) }
        let reply = await ask(plan.request, final: final)
        if Task.isCancelled { return [] }
        if case .timedOut = reply {
            // The turn may still complete and stay in the session's history: say its answer was thrown away.
            await append("\n[discarded] The previous request timed out; its answer was not applied and the text is unchanged.\n")
        }
        guard case .edits(let answer) = reply else { return fail(plan) }

        // Off-schema in meaning: a sentence the window does not have, or one named twice. Nothing is guessed.
        let numbers = answer.map(\.sentence)
        guard numbers.allSatisfy({ (1...plan.sentences.count).contains($0) }), Set(numbers).count == numbers.count else {
            return fail(plan)
        }
        var transactions: [EditTransaction] = []
        for edit in answer.sorted(by: { $0.sentence < $1.sentence }) {
            let sentence = plan.sentences[edit.sentence - 1]
            let new = edit.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard sentence.role == .review, Self.isPlausible(new, for: sentence.text),
                let step = ContiguousPatch.between(sentence.text, new, at: sentence.location)
            else { continue }
            let transaction = EditTransaction(
                origin: .agent, owner: options.owner, base: plan.version, steps: [step], session: plan.session)
            pending[transaction.id] = Planned(old: sentence.text, new: new)
            reviewed.insert(new)
            transactions.append(transaction)
        }
        // A sentence the answer left out ("needs no change") is settled only by the final pass: a small model may
        // skip one it should have fixed, so while listening it is set aside (as after a failed pass) for the final
        // pass to review again, never left raw for good.
        let answered = Set(answer.map { plan.sentences[$0.sentence - 1].text })
        for sentence in plan.sentences where sentence.role == .review {
            if final || answered.contains(sentence.text) {
                reviewed.insert(sentence.text)
                skipped.remove(sentence.text)
            } else {
                skipped.insert(sentence.text)
            }
        }
        return transactions
    }

    /// The pass produced nothing: the raw text stays, and the sentences are not asked again while listening.
    private func fail(_ plan: Plan) -> [EditTransaction] {
        for sentence in plan.sentences where sentence.role == .review { skipped.insert(sentence.text) }
        return []
    }

    // MARK: Session

    /// The window the model may be shown: about a third of the budget in characters.
    private var windowCharacterLimit: Int { max(200, session.tokenBudget) }

    private func append(_ text: String) async {
        guard !text.isEmpty else { return }
        try? await session.append(.text(text))
    }

    /// Scrolls the context when the request would overflow the budget: the oldest history goes, the newest
    /// stays (the session keeps its head). False when the session cannot say or cannot make room.
    private func makeRoom(for request: String) async -> Bool {
        do {
            let usage = try await session.usage()
            let requestTokens = request.count / 3 + 16
            let budget = session.tokenBudget
            guard usage.total + requestTokens > budget else { return true }
            let keep = max(0, (budget - usage.head - requestTokens) / 2)
            try await session.trim(keepingSuffix: keep)
            return true
        } catch {
            return false
        }
    }

    private func ask(_ request: String, final: Bool) async -> Reply {
        let session = session, timeout = options.timeout
        let start = ContinuousClock.now
        let reply = await withTaskGroup(of: Reply.self) { group in
            group.addTask {
                do { return .edits(try await session.respondStructured([SentenceEdit].self, to: request)) } catch { return .failed }
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
        let outcome: String
        switch reply {
        case .edits(let edits): outcome = "edits=\(edits.count)"
        case .timedOut: outcome = "timedOut"
        case .failed: outcome = "failed"
        }
        CleanupCallTrace.emit("cleanup.call", [
            "kind": "agent", "final": final ? "1" : "0", "backend": String(describing: type(of: session)),
            "ms": CleanupCallTrace.milliseconds(since: start), "outcome": outcome, "inChars": String(request.count),
        ])
        return reply
    }

    // MARK: Text helpers

    private static func trimmed(_ range: NSRange, in text: NSString) -> NSRange {
        var start = range.location, end = range.location + range.length
        func isSpace(_ index: Int) -> Bool {
            guard let scalar = Unicode.Scalar(text.character(at: index)) else { return false }
            return CharacterSet.whitespacesAndNewlines.contains(scalar)
        }
        while start < end, isSpace(start) { start += 1 }
        while end > start, isSpace(end - 1) { end -= 1 }
        return NSRange(location: start, length: end - start)
    }

    /// Whether `span` is where the user wrote or deleted: sentences touching it are locked.
    private static func touches(_ touched: Span, _ sentence: Span) -> Bool {
        if touched.length == 0 { return touched.location >= sentence.location && touched.location <= sentence.end }
        return touched.location < sentence.end && touched.end > sentence.location
    }

    private static func endsSentence(_ text: String) -> Bool {
        let closers: Set<Character> = ["\"", "'", ")", "\u{201D}", "\u{2019}", "\u{00BB}"]
        guard let last = text.last(where: { !closers.contains($0) }) else { return false }
        return ".!?\u{2026}".contains(last)
    }

    /// A rewrite is a cleanup, not a new text: not empty, and not several times longer or shorter.
    private static func isPlausible(_ new: String, for old: String) -> Bool {
        !new.isEmpty && new.count <= old.count * 3 + 20 && new.count * 3 + 20 >= old.count
    }
}
