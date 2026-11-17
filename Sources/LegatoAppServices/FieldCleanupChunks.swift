import Foundation
import LegatoKeyboardCore

/// Bounded overlapping field passages. 60/12 is a candidate measured for coverage/call count
/// on recorded takes, not a claim of optimal semantic context (see field-cleanup-measurements).
/// The final stop pass remains a separate whole-document request.
public enum FieldCleanupChunks {
    public static let words = 60
    public static let overlap = 12

    /// Only field-confirmed work advances coverage. The frontier keeps the intended overlap;
    /// changes before it shift its position without sending the old prefix to the model again.
    public struct Coverage {
        private var documentID: String?
        private var snapshot = ""
        private var frontier = 0
        private var coveredEnd = 0
        private var completeDocument = false
        public init() {}

        /// Where the overlap of the confirmed text starts in `text`: the next passage starts there.
        public func start(in text: String, documentID: String?, complete: Bool) -> String.Index {
            offset(frontier, in: text, documentID: documentID, complete: complete).map { text.index(text.startIndex, offsetBy: $0) }
                ?? text.startIndex
        }

        /// Where the confirmed text ends in `text`; nil when nothing of it is known there.
        public func end(in text: String, documentID: String?, complete: Bool) -> String.Index? {
            offset(coveredEnd, in: text, documentID: documentID, complete: complete).map { text.index(text.startIndex, offsetBy: $0) }
        }

        private func offset(_ value: Int, in text: String, documentID: String?, complete: Bool) -> Int? {
            guard let documentID, documentID == self.documentID, !snapshot.isEmpty else { return nil }
            if complete && completeDocument {
                return min(text.count, FieldMerge.position(value, from: Array(snapshot), to: Array(text), afterInsertion: false))
            }
            // A bounded read: the confirmed text up to here must still open it as it was.
            let prefix = String(snapshot.prefix(max(frontier, value)))
            guard text.hasPrefix(prefix) else { return nil }
            return min(value, text.count)
        }

        public mutating func confirm(proposed: String, actual: String, documentID: String?, complete: Bool) {
            // The field may have gained words while the model worked. Those words were never
            // cleaned: map the proposal's end with a before-insertion bias to leave them pending.
            let end = FieldMerge.position(proposed.count, from: Array(proposed), to: Array(actual), afterInsertion: false)
            let covered = String(actual.prefix(end))
            let starts = FieldCleanupChunks.wordStarts(in: covered)
            let start = starts.isEmpty ? covered.endIndex : starts[max(0, starts.count - FieldCleanupChunks.overlap)]
            frontier = covered.distance(from: covered.startIndex, to: start)
            coveredEnd = end
            snapshot = actual; self.documentID = documentID; completeDocument = complete
        }
    }

    public static func wordStarts(in text: String) -> [String.Index] {
        var starts: [String.Index] = []
        var wasSpace = true
        for i in text.indices {
            let space = text[i].isWhitespace
            if wasSpace && !space { starts.append(i) }
            wasSpace = space
        }
        return starts
    }

    /// Every new word is consumed once. A later input includes the previous result's overlap,
    /// and replaces it rather than appending another copy. Identity cleanup is byte-preserving.
    /// `clean` gets each input and the text that stands before it (`before`, then the output so far), as context.
    @MainActor public static func clean(_ source: String, before: String = "",
                                        using clean: (_ text: String, _ before: String) async -> String?) async -> String? {
        let starts = wordStarts(in: source)
        guard starts.count > words else { return await clean(source, before) }
        var consumed = 0
        var output = ""
        while consumed < starts.count {
            let count = consumed == 0 ? words : words - overlap
            let end = min(starts.count, consumed + count)
            let lower = consumed == 0 ? source.startIndex : starts[consumed]
            let upper = end == starts.count ? source.endIndex : starts[end]
            let oldStarts = wordStarts(in: output)
            let overlapStart = oldStarts.isEmpty ? output.endIndex : oldStarts[max(0, oldStarts.count - overlap)]
            let input = String(output[overlapStart...]) + source[lower..<upper]
            guard !Task.isCancelled, let result = await clean(input, before + output[..<overlapStart]) else { return nil }
            output = String(output[..<overlapStart]) + keepingSeparators(of: input, around: result)
            consumed = end
        }
        return output
    }

    /// Providers trim boundary spaces. Keep existing separators so joins cannot swallow a list break or glue words
    /// together. Interior formatting belongs to cleanup.
    static func keepingSeparators(of input: String, around result: String) -> String {
        let lead = String(input.prefix(while: \.isWhitespace))
        let trail = String(input.reversed().prefix(while: \.isWhitespace).reversed())
        return lead.isEmpty && trail.isEmpty ? result : lead + result.trimmingCharacters(in: .whitespacesAndNewlines) + trail
    }

    /// One cleanup call's answer.
    public enum Attempt: Sendable, Equatable {
        case cleaned(String)
        /// The result failed the guard (`DictationTakeGuard`): it concerns some part of the text.
        case rejected
        /// No result (timeout, provider error): splitting would not help.
        case failed(String)
    }

    /// A text whose cleanup the guard rejected is cleaned again in two halves split at a sentence end, each on its own,
    /// down to single sentences; a sentence the guard still rejects stays as it was. So one refused sentence (a German
    /// "um" before a time, say) keeps only itself raw, not the whole take. `.cleaned` when at least one part was
    /// cleaned; otherwise the first answer's failure. `calls` counts the cleanup calls made; `refused` holds the sentences
    /// kept as they were (trimmed). Each call gets the text that stands before its part as context (`before`, then the
    /// left half as cleaned), so a half never reads as a new text.
    @MainActor public static func cleanSplitting(_ source: String, before: String = "",
                                                 using clean: (_ text: String, _ before: String) async -> Attempt)
        async -> (result: Attempt, calls: Int, keptRaw: Int, refused: [String]) {
        var calls = 0, keptRaw = 0
        var refused: [String] = []
        func halves(_ text: String, before: String, cut: String.Index) async -> (text: String, cleaned: Bool)? {
            let left = String(text[..<cut]), right = String(text[cut...])
            guard let a = await part(left, before: before) else { return nil }
            let leftText = keepingSeparators(of: left, around: a.text)
            guard let b = await part(right, before: before + leftText) else { return nil }
            return (leftText + keepingSeparators(of: right, around: b.text), a.cleaned || b.cleaned)
        }
        func part(_ text: String, before: String) async -> (text: String, cleaned: Bool)? {
            calls += 1
            switch await clean(text, before) {
            case .cleaned(let result): return (result, true)
            case .failed: return nil
            case .rejected:
                guard !Task.isCancelled, let cut = sentenceCut(in: text) else {
                    keptRaw += 1; refused.append(text.trimmingCharacters(in: .whitespacesAndNewlines))
                    return (text, false)
                }
                return await halves(text, before: before, cut: cut)
            }
        }
        calls += 1
        let first = await clean(source, before)
        guard case .rejected = first else { return (first, calls, 0, []) }
        guard let cut = sentenceCut(in: source) else { return (first, calls, 0, [source.trimmingCharacters(in: .whitespacesAndNewlines)]) }
        guard let split = await halves(source, before: before, cut: cut), split.cleaned else { return (.rejected, calls, keptRaw, refused) }
        return (.cleaned(split.text), calls, keptRaw, refused)
    }

    /// Where a passage starting at `start` begins once the sentences in `skipped` that open it are left out (they stand
    /// before it as context then). Never past the last letter or digit before `end`: something is left to clean.
    public static func skipping(_ skipped: Set<String>, from start: String.Index, before end: String.Index, in text: String) -> String.Index {
        var start = start
        while let sentence = skipped.first(where: { !$0.isEmpty && text[start..<end].hasPrefix($0) }) {
            var next = text.index(start, offsetBy: sentence.count)
            while next < end, text[next].isWhitespace { next = text.index(after: next) }
            guard text[next..<end].contains(where: { $0.isLetter || $0.isNumber }) else { break }
            start = next
        }
        return start
    }

    /// A take's own text in `text`, from the shadow's `start` and `end` (characters): it starts at its first non-space (the
    /// separator in front of it stays with the text before) and ends at `end`, or at `caret` when `end` is unknown. Without
    /// a known start it starts at the text's start.
    public static func take(start: Int?, end: Int?, caret: Int, in text: String) -> Range<String.Index> {
        let upper = text.index(text.startIndex, offsetBy: min(text.count, max(0, end ?? caret)))
        guard let start, start > 0 else { return text.startIndex..<upper }
        var lower = text.index(text.startIndex, offsetBy: min(start, text.distance(from: text.startIndex, to: upper)))
        while lower < upper, text[lower].isWhitespace { lower = text.index(after: lower) }
        return lower..<upper
    }

    /// Where the sentence holding `index` starts in `text`: after the last sentence end (".", "!" or "?" and a space) or
    /// line break before it, at its first non-space; `text`'s start when there is none.
    public static func sentenceStart(of index: String.Index, in text: String) -> String.Index {
        var i = index
        while i > text.startIndex {
            let previous = text.index(before: i)
            let c = text[previous]
            if c.isNewline { break }
            if c.isWhitespace, previous > text.startIndex, endsSentence(text[text.index(before: previous)]) { break }
            i = previous
        }
        while i < index, text[i].isWhitespace { i = text.index(after: i) }
        return i
    }

    /// The end of the last finished sentence in `text` after `from` and up to `upper` (just past its ".", "!" or "?", where
    /// a space, a line break or `upper` follows): nil when no sentence ends there. Words after it are a sentence still
    /// being said.
    public static func finishedSentencesEnd(in text: String, after from: String.Index, upTo upper: String.Index? = nil) -> String.Index? {
        let upper = upper ?? text.endIndex
        var i = upper
        while i > from {
            let previous = text.index(before: i)
            if endsSentence(text[previous]), i == upper || text[i].isWhitespace,
               text[from..<previous].contains(where: { $0.isLetter || $0.isNumber }) { return i }
            i = previous
        }
        return nil
    }

    private static func endsSentence(_ c: Character) -> Bool { ".!?".contains(c) }

    /// The line breaks in the field are the user's or the field's (an Enter between dictated words, a list): a result that
    /// lost one gets it back where it stood, with the rest of its changes (those touching the words at the break drop).
    /// Breaks the result adds ("new paragraph") stay.
    public static func keepingLineBreaks(of passage: String, in cleaned: String) -> String {
        let breaks = passage.filter(\.isNewline).count
        guard breaks > 0, cleaned.filter(\.isNewline).count < breaks else { return cleaned }
        // Against the passage with its breaks as spaces, the breaks are the field's own change: it wins.
        let base = Array(passage.map { $0.isNewline ? " " : $0 })
        return String(FieldMerge.rebase(base: base, kept: Array(passage), incoming: Array(cleaned)).text)
    }

    /// The sentence end nearest the middle of `text` (after its punctuation and the space that follows), nil for one
    /// sentence. The cut lies at the start of the space, so each half keeps its own separators.
    static func sentenceCut(in text: String) -> String.Index? {
        var cuts: [String.Index] = []
        var i = text.startIndex
        while i < text.endIndex {
            let next = text.index(after: i)
            if ".!?".contains(text[i]), next < text.endIndex, text[next].isWhitespace,
               text[next...].contains(where: { !$0.isWhitespace }), text[..<next].contains(where: \.isLetter) {
                cuts.append(next)
            }
            i = next
        }
        let middle = text.count / 2
        return cuts.min { abs(text.distance(from: text.startIndex, to: $0) - middle) < abs(text.distance(from: text.startIndex, to: $1) - middle) }
    }
}
