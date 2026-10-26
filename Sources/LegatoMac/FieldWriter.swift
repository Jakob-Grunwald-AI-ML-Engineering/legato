import Foundation
import LegatoCore

/// What to do with the dictated text once the run is over.
public enum FinishAction: Sendable, Equatable {
    /// Everything is in the field.
    case done
    /// Nothing (or not everything) is in the field and the caller should paste this text.
    case paste(String)
    /// Part of the text is in the field and the rest is only safe to put on the pasteboard.
    case copy(String)
}

/// Why `FieldWriter` stopped writing into the field.
public enum DegradeReason: Sendable, Equatable {
    /// The element lost keyboard focus.
    case focusLost
    /// Our text in the field no longer reads as we left it (the user edited it).
    case drift
    /// The target threw on a write.
    case writeFailed
    /// The write returned but the readback does not show it (ignored or altered).
    case notApplied
    /// The field's selection or text could not be read.
    case unreadable
}

/// Writes a dictation's edits into a `TextTarget`, one writer per run. Create it when the run
/// starts, `apply` every `TranscriptEdit` in order, then call `finish` once.
///
/// Every write is checked by reading the span back. Anything unexpected *degrades* the writer
/// (`degradeReason`): it stops touching the field and only collects text, and `finish` says how
/// to deliver what the field is missing.
///
/// - `finish(finalText:)` takes the run's final text (the history entry's, which is trimmed);
///   nil means "use what was committed". With no target everything is `.paste`.
/// - If `finish` finds the field missing the tail of the final text (edits still in flight) it
///   writes that too, so call it after the edit stream has been drained.
/// - A first write that fails, or is ignored (the field reads exactly as before), leaves nothing
///   of ours in the field: `.paste(full text)`, never a duplicate. A failure after text landed
///   gives `.copy(remainder)`: the pasteboard only, because pasting could land somewhere else
///   or duplicate. A first write that cannot be verified (readback failed) or that altered the
///   field without showing our text (truncated, mangled) is `.copy(full text)` as part of it
///   may have landed.
/// - A text the field is missing that the writer cannot place (the final text does not continue
///   what was written) is `.copy(final text)`; nothing is appended blindly.
/// - Leading whitespace of the first phrase is not written, so the field matches the trimmed text.
/// - Tentative text left in the field by a mid-run degrade in `.streamLive` is not cleaned up
///   by `finish`.
/// - `revert()` is for a cancelled run: it removes what this writer typed (and puts back the
///   selection the first write replaced) if the field still reads exactly as the writer left
///   it; otherwise it leaves everything alone. The writer ignores all edits after it.
@MainActor
public final class FieldWriter {
    public enum Mode: String, Sendable, Codable, CaseIterable {
        /// Finished phrases are written as they arrive; tentative text is left to the HUD.
        case streamCommitted
        /// Tentative text is written too and replaced in place until it is finished.
        case streamLive
        /// Nothing is written until `finish`, which does one verified write.
        case insertOnStop
    }

    public let mode: Mode
    /// Set once the writer stopped writing into the field; from then on text is only collected.
    public private(set) var degradeReason: DegradeReason?

    private let target: (any TextTarget)?
    /// Everything the engine committed, as received.
    private var committed = ""
    /// The committed text verified to be in the field, starting at `spanStart` (UTF-16).
    private var written = ""
    private var spanStart: Int?
    /// Streaming live only: tentative text currently shown in the field right after `written`.
    private var tentative = ""
    /// A write was attempted whose landing could not be verified (the readback failed).
    private var uncertainWrite = false
    /// What the first write replaced: `replacedText` is nil when the selection could not be read.
    private var replacedLength = 0
    private var replacedText: String?
    /// `revert()` ran: the run was cancelled and the writer no longer touches the field.
    private var closed = false

    public init(target: (any TextTarget)?, mode: Mode = .streamCommitted) {
        self.target = target
        self.mode = mode
    }

    public func apply(_ edit: TranscriptEdit) {
        guard !closed else { return }
        switch edit {
        case .commit(let delta):
            guard !delta.isEmpty else { return }
            committed += delta
            guard degradeReason == nil, mode != .insertOnStop else { return }
            update(appending: delta, tentative: "")
        case .replaceVolatile(let text):
            guard degradeReason == nil, mode == .streamLive else { return }
            update(appending: "", tentative: text)
        case .revise:
            break
        }
    }

    public enum RevertResult: Sendable, Equatable {
        /// The writer had put nothing into the field.
        case nothingWritten
        /// Our text is gone from the field.
        case removed
        /// Our text may still be in the field: it was edited, the focus moved, or removing failed.
        case leftInPlace
    }

    /// Takes back what this writer typed (a cancelled run). Never deletes anything it cannot
    /// prove is its own: the span must read back exactly as written, in the still-focused field.
    @discardableResult
    public func revert() -> RevertResult {
        guard !closed else { return .nothingWritten }
        closed = true
        guard let target, let start = spanStart else { return .nothingWritten }
        let shown = written + tentative
        guard !shown.isEmpty else { return .nothingWritten }
        guard target.isFocused() else { return .leftInPlace }
        let range = UTF16Range(location: start, length: shown.utf16.count)
        guard let current = try? target.text(in: range), current == shown else { return .leftInPlace }
        let restore: String
        if replacedLength == 0 {
            restore = ""
        } else if let replacedText {
            restore = replacedText
        } else {
            return .leftInPlace
        }
        do { try target.replace(range, with: restore) } catch { return .leftInPlace }
        guard let after = try? target.text(in: range), after != shown else { return .leftInPlace }
        written = ""
        tentative = ""
        spanStart = nil
        return .removed
    }

    public func finish(finalText: String?) -> FinishAction {
        if degradeReason == nil, !tentative.isEmpty { update(appending: "", tentative: "") }
        let final = (finalText ?? committed).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !final.isEmpty else { return .done }
        guard target != nil else { return .paste(final) }
        guard let remainder = Self.remainder(of: final, after: written) else { return .copy(final) }
        let rest = remainder.trimmingCharacters(in: .whitespacesAndNewlines)

        if degradeReason == nil {
            guard !rest.isEmpty else { return .done }
            // Edits still in flight: the field is missing the tail of the final text.
            let tail = written.last?.isWhitespace == true ? String(remainder.drop(while: \.isWhitespace)) : remainder
            update(appending: tail, tentative: "")
            if degradeReason == nil { return .done }
        }
        if written.isEmpty { return uncertainWrite ? .copy(final) : .paste(final) }
        return rest.isEmpty ? .done : .copy(rest)
    }

    // MARK: Cleanup and versions

    public enum SwapResult: Sendable, Equatable {
        /// Nothing of ours is in the field (nothing written, no target, or reverted).
        case nothingWritten
        /// The field now shows the new text where ours was.
        case swapped
        /// The field no longer ends with our text (edited, typed after, caret or focus moved) or the write
        /// failed or could not be verified: the field was left as it was, as far as can be told.
        case leftInPlace
    }

    /// `finish(finalText:)` for a run whose text was cleaned up: `rawText` is what the engine heard (what
    /// streamed into the field), `cleanedText` the trimmed result. Call it once instead of `finish(finalText:)`.
    ///
    /// - Nothing of ours in the field yet (nothing streamed, `.insertOnStop`, Hold): one verified write of
    ///   the cleaned text, as `finish(finalText: cleanedText)`.
    /// - Replace: the raw text is finished first (a missing tail is flushed), then swapped for the cleaned
    ///   text with `swapWritten(for:)`. If the field no longer ends with the raw text or the swap fails,
    ///   the field is left and the result is `.copy(cleanedText)`.
    /// - Clipboard: the raw text is finished and stays; the result is `.copy(cleanedText)`.
    ///
    /// `.paste` and `.copy` carry the whole cleaned text: `.paste` when nothing of ours landed in the field,
    /// `.copy` when (some of) the raw text is in it and stays.
    public func finish(rawText: String?, cleanedText: String, delivery: CleanupDelivery) -> FinishAction {
        let cleaned = cleanedText.trimmingCharacters(in: .whitespacesAndNewlines)
        if spanStart == nil, degradeReason == nil, !uncertainWrite {
            return finish(finalText: cleaned)
        }
        switch finish(finalText: rawText) {
        case .paste:
            return cleaned.isEmpty ? .done : .paste(cleaned)
        case .copy:
            return cleaned.isEmpty ? .done : .copy(cleaned)
        case .done:
            guard !cleaned.isEmpty else { return .done }
            if delivery == .clipboard { return .copy(cleaned) }
            switch swapWritten(for: cleaned) {
            case .swapped: return .done
            case .nothingWritten: return .paste(cleaned)
            case .leftInPlace: return .copy(cleaned)
            }
        }
    }

    /// Swaps the text this writer put into the field for `text`, in one write verified by readback: for the
    /// cleaned text at the end of a run, and afterwards for its versions (raw, refined). Only while the
    /// focused field still ends with our text exactly as written and the caret sits right after it; any
    /// trailing whitespace the field got stays after the new text.
    @discardableResult
    public func swapWritten(for text: String) -> SwapResult {
        guard !closed, let target, let start = spanStart, tentative.isEmpty else { return .nothingWritten }
        let body = String(written.reversed().drop(while: \.isWhitespace).reversed())
        guard !body.isEmpty else { return .nothingWritten }
        guard degradeReason == nil, target.isFocused() else { return .leftInPlace }
        let span = UTF16Range(location: start, length: written.utf16.count)
        guard let current = try? target.text(in: span), current == written,
              let selection = try? target.selectedRange(), selection == UTF16Range(location: span.end, length: 0)
        else { return .leftInPlace }
        if text == body { return .swapped }
        let replacement = text + written.dropFirst(body.count)
        do {
            try target.replace(span, with: replacement)
        } catch {
            degrade(.writeFailed)
            return .leftInPlace
        }
        guard let readback = try? target.text(in: UTF16Range(location: start, length: replacement.utf16.count)),
              readback == replacement
        else {
            degrade(.notApplied)
            return .leftInPlace
        }
        written = replacement
        return .swapped
    }

    // MARK: Writing

    /// Appends `delta` to the committed text and shows `newTentative` after it, replacing whatever
    /// tentative text is in the field, in one write verified by readback. Degrades on any problem;
    /// `written` only grows when the readback matches.
    private func update(appending delta: String, tentative newTentative: String) {
        guard let target else { return }
        var delta = delta
        var newTentative = newTentative
        if written.isEmpty {
            delta = String(delta.drop(while: \.isWhitespace))
            if delta.isEmpty { newTentative = String(newTentative.drop(while: \.isWhitespace)) }
        }
        let insertion = delta + newTentative
        if delta.isEmpty, newTentative == tentative { return } // nothing changes
        if insertion.isEmpty, tentative.isEmpty { return } // never delete a selection for nothing
        guard target.isFocused() else { return degrade(.focusLost) }

        let start: Int
        let range: UTF16Range
        // First write only: the text around the insertion before it, to tell "ignored" from "altered".
        var probe: (window: UTF16Range, before: String)?
        var replaced: String??
        if let spanStart {
            start = spanStart
            // Our text must be exactly where we left it before we change it.
            let shown = written + tentative
            do {
                let current = try target.text(in: UTF16Range(location: start, length: shown.utf16.count))
                guard current == shown else { return degrade(.drift) }
            } catch {
                return degrade(.unreadable)
            }
            range = UTF16Range(location: start + written.utf16.count, length: tentative.utf16.count)
        } else {
            do {
                range = try target.selectedRange() // the first write replaces the selection
            } catch {
                return degrade(.unreadable)
            }
            start = range.location
            let window = UTF16Range(location: start, length: range.length + insertion.utf16.count)
            if let before = try? target.text(in: window) { probe = (window, before) }
            replaced = .some(range.length == 0 ? "" : try? target.text(in: range))
        }

        do {
            try target.replace(range, with: insertion)
        } catch {
            return degrade(.writeFailed)
        }
        let expected = written + insertion
        do {
            let readback = try target.text(in: UTF16Range(location: start, length: expected.utf16.count))
            guard readback == expected else {
                if let probe {
                    // Unchanged field: nothing of ours is in it. Anything else may hold part of our text.
                    let now = try? target.text(in: probe.window)
                    if now != probe.before { uncertainWrite = true }
                } else if spanStart == nil {
                    uncertainWrite = true
                }
                return degrade(.notApplied)
            }
        } catch {
            uncertainWrite = true
            return degrade(.unreadable)
        }
        if spanStart == nil, let replaced {
            replacedLength = range.length
            replacedText = replaced
        }
        spanStart = start
        written += delta
        tentative = newTentative
    }

    private func degrade(_ reason: DegradeReason) {
        if degradeReason == nil { degradeReason = reason }
    }

    /// The part of `final` (trimmed) that is not yet in the field, or nil when `final` does not
    /// continue what was written. `written` may carry whitespace that `final` was trimmed of.
    private static func remainder(of final: String, after written: String) -> String? {
        if written.isEmpty { return final }
        if final.hasPrefix(written) { return String(final.dropFirst(written.count)) }
        let trimmed = written.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, final.hasPrefix(trimmed) { return String(final.dropFirst(trimmed.count)) }
        return nil
    }
}
