import Foundation
import LegatoAgent
import LegatoCore
import LegatoKeyboardCore

/// Cleanup and Magic share the field's read/conditional-write interface. Speech remains in the
/// dictation queue; this owner never publishes a cleaned transcript back over a user's field.
@MainActor public final class FieldCleanupSession {
    public weak var field: (any InstructionField)?
    public var canApply: @MainActor () -> Bool = { true }
    /// Cross-process speech delivery must settle before either scope read. This wait owns no field lease.
    public var awaitDelivery: @MainActor () async -> Bool = { true }
    /// The passage to clean; whether it is a pass over the whole take (the stop's, or a long pause's: one call); the text
    /// that stands before it in the field (context only: the cleaner continues it, never repeats or edits it); and on a
    /// whole-take pass the take's raw recognized words (reference only: they show corrections across sentences that
    /// earlier passes tidied away; never inserted).
    public var clean: @MainActor (_ passage: String, _ whole: Bool, _ before: String, _ raw: String?) async -> String? = { _, _, _, _ in nil }
    /// The field's text as the keyboard's shadow has it (`FieldShadow`), asked with the live run's snapshot instead of a
    /// field read (iPhone, #299 round 4). Nil, or a nil answer (no live run): the pass reads the field.
    public var shadow: (@MainActor (_ passID: String) async -> FieldShadow?)?
    /// The take's raw recognized words for a whole-take pass (nil: none known).
    public var rawWords: @MainActor () -> String? = { nil }
    /// Why the last `clean` call gave nil (`timeout`, `failed`, `rejected`): set by the `clean` closure, for diagnostics.
    public var cleanFailure: String?
    /// Sentences of this take the guard refused, kept as typed (the `clean` closure adds them). A later sentence pass that
    /// would open with one (its overlap reaches back into it) starts after it, with it as context: sent again it is refused
    /// again and splits the pass into several calls (device run 4: 4–6 s per pass instead of under 1 s). The pass at the
    /// stop or in a long pause still covers it.
    public var refusedSentences: Set<String> = []
    public var onResult: @MainActor (String, String, CleanupFieldStatus) async -> Void = { _, _, _ in }
    public var diagnostics: (@MainActor (String, [String: Any]) -> Void)?
    private var task: Task<Void, Never>?
    private var generation = 0
    private var requestID: String?
    private var requested = false
    private var finalRequested = false
    private var sentenceRequested = false
    private var wholeRequested = false
    private var lastRead = ""
    private var lastWholeRead = ""
    private var coverage = FieldCleanupChunks.Coverage()
    private var pendingText = ""
    /// The next pass is the one automatic pass after an edit the field could not place: it asks for no further one.
    private var repassing = false
    public private(set) var lastApplied = false
    public private(set) var recoveryTarget: String?

    public init() {}

    public func reset() {
        generation += 1
        task?.cancel(); task = nil
        if let requestID { field?.cancel(instructionID: requestID) }
        requestID = nil; requested = false; finalRequested = false; sentenceRequested = false; wholeRequested = false
        lastRead = ""; lastWholeRead = ""; coverage = .init(); refusedSentences = []
        pendingText = ""; repassing = false; lastApplied = false; recoveryTarget = nil
    }

    /// Repeated pauses coalesce. A stop always gets a fresh pass, including long takes. An edit the field could not
    /// place (`ScopedEditAck.unplaceable`) gets one pass more on the text as it is read then, never a loop. `sentence`:
    /// a sentence just ended (iPhone): the pass goes without waiting for a full passage of new words; it cleans what is not
    /// covered yet with the coverage's overlap (about the sentence before) as context. `whole`: a long pause; the pass covers
    /// the whole take with its raw words, as the stop's does.
    public func request(final: Bool = false, pendingText: String = "", sentence: Bool = false, whole: Bool = false) {
        guard recoveryTarget == nil else { return }
        requested = true; finalRequested = finalRequested || final; sentenceRequested = sentenceRequested || sentence
        wholeRequested = wholeRequested || whole
        if !pendingText.isEmpty { self.pendingText = pendingText }
        guard task == nil else { return }
        let token = generation
        task = Task { [weak self] in
            guard let self else { return }
            while requested, recoveryTarget == nil, !Task.isCancelled, token == generation {
                // A pause pass starts in a pause; a sentence's pass starts at once (only its result waits for a gap).
                guard canApply() || sentenceRequested else { break }
                // The stop's pass covers the sentence's too, and so does a whole-take pass.
                let final = finalRequested, whole = finalRequested || wholeRequested
                let sentence = sentenceRequested && !whole
                let pending = self.pendingText
                self.pendingText = ""
                let repass = repassing
                requested = false; finalRequested = false; sentenceRequested = false; wholeRequested = false; repassing = false
                await pass(final: final, whole: whole, sentence: sentence, pending: pending, repass: repass, generation: token)
            }
            if token == generation { task = nil }
        }
    }

    public func settle() async { await task?.value }

    private func deliveryReady(final: Bool, source: String, generation token: Int) async -> Bool {
        let ready = await awaitDelivery()
        guard token == generation, !Task.isCancelled else { return false }
        guard ready else {
            await onResult(source, "", .undelivered)
            diagnostics?("field.cleanup", ["final": final, "status": "deliveryUnconfirmed"])
            return false
        }
        return true
    }

    /// One `field.cleanup` diagnostic per pass, whatever its end: counts and timings, never text.
    private func report(_ status: String, final: Bool, sentence: Bool, repass: Bool = false, started: ContinuousClock.Instant,
                        _ extra: [String: Any] = [:]) {
        var fields: [String: Any] = ["final": final, "sentence": sentence, "repass": repass, "status": status,
                                     "ms": Self.ms(since: started)]
        fields.merge(extra) { _, new in new }
        diagnostics?("field.cleanup", fields)
    }

    private static func ms(since start: ContinuousClock.Instant) -> Int {
        let parts = start.duration(to: .now).components
        return Int(parts.seconds * 1000 + parts.attoseconds / 1_000_000_000_000_000)
    }

    /// One pass. The field's text comes from the keyboard's shadow for a live run (no read; the keyboard marks the read
    /// under the pass's id and merges the edit around every change since, `FieldQueue.placeThroughRead`), else from a
    /// read, re-read before the edit (buffered words still to be inserted, the Mac). Logs one `field.cleanup` line with
    /// the phases' times since the request (ms): `shadowSentMs` (the keyboard sent its text), `shadowMs` (it arrived) or
    /// `readMs`, `modelStartMs`, `modelEndMs`, `applySentMs`, `confirmedMs`.
    private func pass(final: Bool, whole: Bool, sentence: Bool = false, pending: String, repass: Bool, generation token: Int) async {
        guard let field else { return }
        lastApplied = false
        let id = UUID().uuidString
        requestID = id
        let started = ContinuousClock.now, startedAt = Date()
        var phases: [String: Any] = [:]
        func mark(_ phase: String) { phases[phase] = Self.ms(since: started) }
        func log(_ status: String, _ extra: [String: Any] = [:]) {
            var fields = phases.merging(extra) { _, new in new }
            fields["whole"] = whole
            report(status, final: final, sentence: sentence, repass: repass, started: started, fields)
        }
        defer { field.cancel(instructionID: id); if requestID == id { requestID = nil } }
        do {
            let reply: FieldReadReply
            var takeStart: Int?, takeEnd: Int?
            var shadowed = false, bounded = false
            if pending.isEmpty, let ask = shadow, let answer = await ask(id) {
                guard token == generation, !Task.isCancelled else { return }
                mark("shadowMs")
                phases["shadowSentMs"] = max(0, Int(answer.at.timeIntervalSince(startedAt) * 1000))
                if let why = answer.refused {
                    log("shadowRefused", ["why": why])
                    if why != "syncPending" { await onResult("", "", .undelivered) }
                    return
                }
                reply = FieldReadReply(id: id, state: .done, above: answer.above, below: answer.below,
                                       documentID: answer.documentID, draftID: answer.draftID)
                takeStart = answer.takeStart; takeEnd = answer.takeEnd
                shadowed = true
            } else {
                guard await deliveryReady(final: final, source: "", generation: token) else { return }
                reply = try await field.read(.cleanup, instructionID: id, reading: {})
                mark("readMs")
                // A host that tells where the take stands bounds the read pass too (buffered words are not in the field yet).
                if pending.isEmpty { takeStart = reply.takeStart; takeEnd = reply.takeEnd; bounded = reply.takeEnd != nil }
            }
            guard token == generation, !Task.isCancelled else { return }
            guard reply.state == .done, reply.selection?.isEmpty != false else {
                log("readRefused"); await onResult("", "", .undelivered); return
            }
            let baseline = reply.above + reply.below
            let insertion = FieldInsertion.prepare(pending, contextBefore: reply.above, capitalization: .none)
            let following = insertion.isEmpty ? "" : FieldInsertion.trailingSeparator(after: insertion, before: reply.below.first)
            let source = reply.above + insertion + following + reply.below
            guard !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, final || source != (whole ? lastWholeRead : lastRead) else {
                log("unchanged"); return
            }
            let complete = reply.stop == .start && reply.stopBelow == .start
            // A pass from the shadow edits the take's own text only (#299 device run 4: a take dictated mid-word into a
            // note was cleaned across its edges and the user's sentence around it moved). It ends where the take's text
            // does (the caret when the shadow does not know): the user's text after it is neither sent nor edited. It
            // starts where the take does: the user's part of the sentence the take begins in is context, never edited (a
            // take begun mid-word or mid-sentence would otherwise hand the model a fragment to fix). Without a known start
            // it is the field's start, as before.
            let take = shadowed || bounded ? FieldCleanupChunks.take(start: takeStart, end: takeEnd, caret: reply.above.count, in: source) : nil
            var start = take?.lowerBound ?? source.startIndex, end = take?.upperBound ?? source.endIndex
            if !whole {
                let uncovered = coverage.start(in: source, documentID: reply.documentID, complete: complete)
                start = max(uncovered, start)
                if sentence {
                    // A sentence's pass cleans whole sentences: from the start of the one the uncovered text begins in (so
                    // the sentence before is in it when the overlap reaches back; never before the take) to the end of the
                    // last finished one. The words after it are the next sentence, still being said: they are neither sent
                    // nor edited.
                    start = max(FieldCleanupChunks.sentenceStart(of: uncovered, in: source), take?.lowerBound ?? source.startIndex)
                    // Only a sentence that ends past what is cleaned already makes a pass.
                    let cleanedEnd = coverage.end(in: source, documentID: reply.documentID, complete: complete) ?? uncovered
                    guard let finished = FieldCleanupChunks.finishedSentencesEnd(in: source, after: max(uncovered, cleanedEnd, start), upTo: end) else {
                        log("noSentence"); return
                    }
                    end = finished
                    start = FieldCleanupChunks.skipping(refusedSentences, from: start, before: end, in: source)
                }
            }
            let passage = start < end ? String(source[start..<end]) : ""
            let words = FieldCleanupChunks.wordStarts(in: passage).count
            guard words > 0, whole || sentence || words >= FieldCleanupChunks.words else { log("short", ["words": words]); return }
            if whole { lastWholeRead = source } else { lastRead = source }
            let raw = whole ? rawWords() : nil
            cleanFailure = nil
            mark("modelStartMs")
            let modelStarted = ContinuousClock.now
            let cleaned = await clean(passage, whole, String(source[..<start]), raw)
            let modelMs = Self.ms(since: modelStarted)
            mark("modelEndMs")
            guard token == generation, !Task.isCancelled else { return }
            let counts: [String: Any] = ["modelMs": modelMs, "words": words, "sourceChars": source.count, "shadow": shadowed,
                                         "rawWords": raw.map { FieldCleanupChunks.wordStarts(in: $0).count } ?? 0]
            // A provider trims its answer: the passage's own leading and trailing whitespace stays (a passage can end in
            // the space in front of the user's next sentence, which would be lost).
            guard let cleaned = cleaned.map({ FieldCleanupChunks.keepingSeparators(of: passage, around: FieldCleanupChunks.keepingLineBreaks(of: passage, in: $0)) }) else {
                log("modelFailed", counts.merging(["reason": cleanFailure ?? "failed"]) { _, new in new })
                await onResult(source, baseline, pending.isEmpty ? .keptAsTyped : .undelivered)
                return
            }
            // What the passage covers once cleaned (coverage ends there), and the field's text with it.
            let covered = String(source[..<start]) + cleaned
            let target = covered + source[end...]
            // A provider may finish after speech resumes. Keep its result until a pause, but never
            // hold up the incoming words or apply against a different read after a reset.
            let waitStarted = ContinuousClock.now
            while !canApply(), token == generation, !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(20))
            }
            let gapMs = Self.ms(since: waitStarted)
            guard token == generation, !Task.isCancelled else { return }
            if shadowed {
                // No re-read: the keyboard places the edit through every change since it sent its shadow and merges it
                // around them (the field's text wins); a field that still matches takes it at once. An edit it cannot
                // place drops, and one fresh pass follows.
                var fields = counts
                fields["gapMs"] = gapMs
                guard target != source else {
                    lastApplied = true
                    coverage.confirm(proposed: covered, actual: source, documentID: reply.documentID, complete: false)
                    log("noChange", fields.merging(["why": "cleanAsTyped"]) { _, new in new })
                    await onResult(source, source, .keptAsTyped)
                    return
                }
                let edit = ScopedEdit(instructionID: id, documentID: reply.documentID, before: reply.above, after: reply.below,
                                      target: target, draftID: reply.draftID, requiresShadowRead: true)
                mark("applySentMs")
                let ack = await field.apply(edit)
                mark("confirmedMs")
                guard token == generation else { return }
                let applied = ack?.applied == true
                lastApplied = applied
                let actual = ack?.confirmedText ?? target
                // The field's text past the passage may have grown meanwhile: coverage ends where the cleaned text does.
                if applied { coverage.confirm(proposed: covered, actual: actual, documentID: reply.documentID, complete: false) }
                recoveryTarget = ack?.recoveryTarget ?? (ack == nil ? target : nil)
                if !applied, ack != nil, ack?.stopped != true, recoveryTarget == nil, !repass {
                    repassNext(final: final, whole: whole, sentence: sentence)
                }
                let status: CleanupFieldStatus = applied
                    ? (actual == source ? .keptAsTyped : .cleaned)
                    : (ack?.stopped == true || ack == nil ? .undelivered : .keptAsTyped)
                await onResult(source, applied ? actual : ack?.partial ?? source, status)
                fields["targetChars"] = target.count; fields["applied"] = applied; fields["unplaceable"] = ack?.unplaceable == true
                if !applied { fields["why"] = Self.why(ack) }
                log(status.rawValue, fields)
                return
            }
            // Re-read just before applying: the shared three-way merge keeps every change made since the read (the
            // user's, and speech typed meanwhile) and accepts cleanup changes only in untouched words. Kept for buffered
            // words still to be inserted (they need the read exactly) and fields without a shadow (the Mac).
            guard await deliveryReady(final: final, source: source, generation: token) else { return }
            let fresh = try await field.read(.cleanup, instructionID: id, reading: {})
            mark("rereadMs")
            guard token == generation, !Task.isCancelled else { return }
            guard fresh.state == .done, fresh.documentID == reply.documentID, fresh.draftID == reply.draftID, fresh.selection?.isEmpty != false else {
                log("rereadRefused", ["modelMs": modelMs, "gapMs": gapMs]); await onResult(source, "", .undelivered); return
            }
            let current = fresh.above + fresh.below
            // Sending can clear a host field without changing its document ID. An empty
            // successor is no longer this cleanup's draft, including buffered speech not
            // yet inserted. Adapters also supply draftID to catch clear-then-type races.
            guard !current.isEmpty || baseline.isEmpty else {
                log("draftCleared", ["modelMs": modelMs, "gapMs": gapMs]); await onResult(source, "", .undelivered); return
            }
            let whole = reply.stop == .start && reply.stopBelow == .start && fresh.stop == .start && fresh.stopBelow == .start
            // A bounded read is merged too when the text before the cleaned passage still opens the field as read, so both
            // reads start at the same place, and what changed since (speech typed during the model call, a key) is the
            // field's. Buffered words still to be inserted need the read exactly.
            let sameStart = pending.isEmpty && current.hasPrefix(source[..<start])
            guard current == baseline || whole || sameStart else {
                log("fieldChanged", ["modelMs": modelMs, "gapMs": gapMs, "sourceChars": source.count, "currentChars": current.count])
                await onResult(source, current, pending.isEmpty ? .keptAsTyped : .undelivered); return
            }
            let merge = FieldMerge.rebase(base: Array(baseline), kept: Array(current), incoming: Array(target))
            let merged = String(merge.text)
            if current == merged {
                lastApplied = pending.isEmpty
                if pending.isEmpty { coverage.confirm(proposed: covered, actual: current, documentID: fresh.documentID, complete: whole) }
                // Nothing to change, or every change touched words changed since the read (the user's, or speech).
                log("noChange", ["modelMs": modelMs, "gapMs": gapMs, "mergeDropped": merge.dropped,
                                 "why": target == source ? "cleanAsTyped" : merge.dropped > 0 ? "touchedChangedWords" : "alreadyThere"])
                await onResult(source, current, pending.isEmpty ? .keptAsTyped : .undelivered)
                return
            }
            let edit = ScopedEdit(instructionID: id, documentID: reply.documentID,
                                  before: fresh.above, after: fresh.below, target: merged, draftID: fresh.draftID)
            mark("applySentMs")
            let ack = await field.apply(edit)
            mark("confirmedMs")
            guard token == generation else { return }
            lastApplied = ack?.applied == true
            if ack?.applied == true { coverage.confirm(proposed: covered, actual: merged, documentID: fresh.documentID, complete: whole) }
            if ack?.unplaceable == true, ack?.applied != true, !repass, pending.isEmpty { repassNext(final: final, whole: whole, sentence: sentence) }
            let status: CleanupFieldStatus = ack?.applied == true ? (target == source ? .keptAsTyped : .cleaned) : ack?.stopped == true || ack == nil ? .undelivered : .keptAsTyped
            await onResult(source, ack?.applied == true ? merged : ack?.partial ?? current, status)
            var fields: [String: Any] = ["sourceChars": source.count, "targetChars": target.count, "unplaceable": ack?.unplaceable == true,
                                         "applied": ack?.applied == true, "modelMs": modelMs, "gapMs": gapMs, "mergeDropped": merge.dropped,
                                         "moved": current != baseline]
            // Why the field did not take it: no answer, the place was not found again, it stopped partway, or refused.
            if ack?.applied != true { fields["why"] = Self.why(ack) }
            log(status.rawValue, fields)
        } catch {
            guard token == generation, !Task.isCancelled else { return }
            log("readFailed")
            await onResult("", "", .undelivered)
        }
    }

    private func repassNext(final: Bool, whole: Bool, sentence: Bool) {
        // The field may hold part of this edit: the text as it is then is cleaned once more, never in a loop.
        lastRead = ""; lastWholeRead = ""; requested = true; repassing = true
        finalRequested = finalRequested || final; wholeRequested = wholeRequested || (whole && !final)
        sentenceRequested = sentenceRequested || sentence
    }

    private static func why(_ ack: ScopedEditAck?) -> String {
        ack == nil ? "noAck" : ack?.unplaceable == true ? "unplaceable" : ack?.stopped == true ? "stopped" : "refused"
    }
}
