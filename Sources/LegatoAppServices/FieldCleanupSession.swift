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
    /// The passage to clean, whether it is the stop's final pass, and the text that stands before it in the field (context
    /// only: the cleaner continues it, never repeats or edits it).
    public var clean: @MainActor (_ passage: String, _ final: Bool, _ before: String) async -> String? = { _, _, _ in nil }
    /// Why the last `clean` call gave nil (`timeout`, `failed`, `rejected`): set by the `clean` closure, for diagnostics.
    public var cleanFailure: String?
    public var onResult: @MainActor (String, String, CleanupFieldStatus) async -> Void = { _, _, _ in }
    public var diagnostics: (@MainActor (String, [String: Any]) -> Void)?
    private var task: Task<Void, Never>?
    private var generation = 0
    private var requestID: String?
    private var requested = false
    private var finalRequested = false
    private var sentenceRequested = false
    private var lastRead = ""
    private var coverage = FieldCleanupChunks.Coverage()
    private var pendingText = ""
    /// The next pass is the one automatic pass after an edit the field could not place: it asks for no further one.
    private var repassing = false
    public private(set) var lastApplied = false

    public init() {}

    public func reset() {
        generation += 1
        task?.cancel(); task = nil
        if let requestID { field?.cancel(instructionID: requestID) }
        requestID = nil; requested = false; finalRequested = false; sentenceRequested = false; lastRead = ""; coverage = .init()
        pendingText = ""; repassing = false; lastApplied = false
    }

    /// Repeated pauses coalesce. A stop always gets a fresh pass, including long takes. An edit the field could not
    /// place (`ScopedEditAck.unplaceable`) gets one pass more on the text as it is read then, never a loop. `sentence`:
    /// a sentence just ended (iPhone): the pass goes without waiting for a full passage of new words; it cleans what is not
    /// covered yet with the coverage's overlap (about the sentence before) as context.
    public func request(final: Bool = false, pendingText: String = "", sentence: Bool = false) {
        requested = true; finalRequested = finalRequested || final; sentenceRequested = sentenceRequested || sentence
        if !pendingText.isEmpty { self.pendingText = pendingText }
        guard task == nil else { return }
        let token = generation
        task = Task { [weak self] in
            guard let self else { return }
            while requested, !Task.isCancelled, token == generation {
                // A pause pass starts in a pause; a sentence's pass starts at once (only its result waits for a gap).
                guard canApply() || sentenceRequested else { break }
                // The stop's pass covers the sentence's too.
                let final = finalRequested, sentence = sentenceRequested && !finalRequested
                let pending = self.pendingText
                self.pendingText = ""
                let repass = repassing
                requested = false; finalRequested = false; sentenceRequested = false; repassing = false
                await pass(final: final, sentence: sentence, pending: pending, repass: repass, generation: token)
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

    private func pass(final: Bool, sentence: Bool = false, pending: String, repass: Bool, generation token: Int) async {
        guard let field else { return }
        lastApplied = false
        let id = UUID().uuidString
        requestID = id
        let started = ContinuousClock.now
        func log(_ status: String, _ extra: [String: Any] = [:]) {
            report(status, final: final, sentence: sentence, repass: repass, started: started, extra)
        }
        defer { field.cancel(instructionID: id); if requestID == id { requestID = nil } }
        do {
            guard await deliveryReady(final: final, source: "", generation: token) else { return }
            let reply = try await field.read(.cleanup, instructionID: id, reading: {})
            guard token == generation, !Task.isCancelled else { return }
            guard reply.state == .done, reply.selection?.isEmpty != false else {
                log("readRefused"); await onResult("", "", .undelivered); return
            }
            let baseline = reply.above + reply.below
            let insertion = FieldInsertion.prepare(pending, contextBefore: reply.above, capitalization: .none)
            let following = insertion.isEmpty ? "" : FieldInsertion.trailingSeparator(after: insertion, before: reply.below.first)
            let source = reply.above + insertion + following + reply.below
            guard !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  final || source != lastRead else { log("unchanged"); return }
            let complete = reply.stop == .start && reply.stopBelow == .start
            let uncovered = final ? source.startIndex : coverage.start(in: source, documentID: reply.documentID, complete: complete)
            var start = uncovered, end = source.endIndex
            if sentence {
                // A sentence's pass cleans whole sentences: from the start of the one the uncovered text begins in (so the
                // sentence before is in it when the overlap reaches back) to the end of the last finished one. The words
                // after it are the next sentence, still being said: they are neither sent nor edited.
                start = FieldCleanupChunks.sentenceStart(of: uncovered, in: source)
                // Only a sentence that ends past what is cleaned already makes a pass.
                let cleanedEnd = coverage.end(in: source, documentID: reply.documentID, complete: complete) ?? uncovered
                guard let finished = FieldCleanupChunks.finishedSentencesEnd(in: source, after: max(uncovered, cleanedEnd)) else {
                    log("noSentence"); return
                }
                end = finished
            }
            let passage = String(source[start..<end])
            let words = FieldCleanupChunks.wordStarts(in: passage).count
            guard final || sentence || words >= FieldCleanupChunks.words else { log("short", ["words": words]); return }
            lastRead = source
            cleanFailure = nil
            let modelStarted = ContinuousClock.now
            let cleaned = await clean(passage, final, String(source[..<start]))
            let modelMs = Self.ms(since: modelStarted)
            guard token == generation, !Task.isCancelled else { return }
            guard let cleaned else {
                log("modelFailed", ["reason": cleanFailure ?? "failed", "modelMs": modelMs, "words": words, "sourceChars": source.count])
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
            // Re-read just before applying: the shared three-way merge keeps every change made since the read (the
            // user's, and speech typed meanwhile) and accepts cleanup changes only in untouched words.
            guard await deliveryReady(final: final, source: source, generation: token) else { return }
            let fresh = try await field.read(.cleanup, instructionID: id, reading: {})
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
            // A bounded read (the iPhone's shadow) is merged too when the text before the cleaned passage still opens the
            // field as read: both reads then start at the same place, and what changed since (speech typed during the model
            // call, a key) is the field's. Buffered words still to be inserted need the read exactly.
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
            let ack = await field.apply(edit)
            guard token == generation else { return }
            lastApplied = ack?.applied == true
            if ack?.applied == true { coverage.confirm(proposed: covered, actual: merged, documentID: fresh.documentID, complete: whole) }
            if ack?.unplaceable == true, ack?.applied != true, !repass, pending.isEmpty {
                // The field may hold part of this edit: the same text read again is still to be cleaned.
                lastRead = ""; requested = true; finalRequested = finalRequested || final; repassing = true
                sentenceRequested = sentenceRequested || sentence
            }
            let status: CleanupFieldStatus = ack?.applied == true ? (target == source ? .keptAsTyped : .cleaned) : ack?.stopped == true || ack == nil ? .undelivered : .keptAsTyped
            await onResult(source, ack?.applied == true ? merged : ack?.partial ?? current, status)
            var fields: [String: Any] = ["sourceChars": source.count, "targetChars": target.count, "unplaceable": ack?.unplaceable == true,
                                         "applied": ack?.applied == true, "modelMs": modelMs, "gapMs": gapMs, "mergeDropped": merge.dropped,
                                         "moved": current != baseline]
            // Why the field did not take it: no answer, the place was not found again, it stopped partway, or refused.
            if ack?.applied != true {
                fields["why"] = ack == nil ? "noAck" : ack?.unplaceable == true ? "unplaceable" : ack?.stopped == true ? "stopped" : "refused"
            }
            log(status.rawValue, fields)
        } catch {
            guard token == generation, !Task.isCancelled else { return }
            log("readFailed")
            await onResult("", "", .undelivered)
        }
    }
}
