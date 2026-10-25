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
/// - A first write that fails, is ignored or lies leaves nothing of ours in the field:
///   `.paste(full text)`, never a duplicate. A failure after text landed gives
///   `.copy(remainder)`: the pasteboard only, because pasting could land somewhere else or
///   duplicate. A first write that cannot be verified (readback failed) is `.copy(full text)`
///   as it may have landed.
/// - A text the field is missing that the writer cannot place (the final text does not continue
///   what was written) is `.copy(final text)`; nothing is appended blindly.
/// - Leading whitespace of the first phrase is not written, so the field matches the trimmed text.
/// - Tentative text left in the field by a mid-run degrade in `.streamLive` is not cleaned up.
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

    public init(target: (any TextTarget)?, mode: Mode = .streamCommitted) {
        self.target = target
        self.mode = mode
    }

    public func apply(_ edit: TranscriptEdit) {
        switch edit {
        case .commit(let delta):
            guard !delta.isEmpty else { return }
            committed += delta
            guard degradeReason == nil, mode != .insertOnStop else { return }
            update(appending: delta, tentative: "")
        case .replaceVolatile(let text):
            guard degradeReason == nil, mode == .streamLive else { return }
            update(appending: "", tentative: text)
        }
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
        }

        do {
            try target.replace(range, with: insertion)
        } catch {
            return degrade(.writeFailed)
        }
        let expected = written + insertion
        do {
            let readback = try target.text(in: UTF16Range(location: start, length: expected.utf16.count))
            guard readback == expected else { return degrade(.notApplied) }
        } catch {
            uncertainWrite = true
            return degrade(.unreadable)
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
