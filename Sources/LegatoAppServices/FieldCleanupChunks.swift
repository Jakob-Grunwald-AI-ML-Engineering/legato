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
        private var completeDocument = false
        public init() {}

        public func start(in text: String, documentID: String?, complete: Bool) -> String.Index {
            guard let documentID, documentID == self.documentID, !snapshot.isEmpty else { return text.startIndex }
            let offset: Int
            if complete && completeDocument {
                offset = FieldMerge.position(frontier, from: Array(snapshot), to: Array(text), afterInsertion: false)
            } else {
                let prefix = String(snapshot.prefix(frontier))
                guard text.hasPrefix(prefix) else { return text.startIndex }
                offset = frontier
            }
            return text.index(text.startIndex, offsetBy: min(offset, text.count))
        }

        public mutating func confirm(proposed: String, actual: String, documentID: String?, complete: Bool) {
            // The field may have gained words while the model worked. Those words were never
            // cleaned: map the proposal's end with a before-insertion bias to leave them pending.
            let end = FieldMerge.position(proposed.count, from: Array(proposed), to: Array(actual), afterInsertion: false)
            let covered = String(actual.prefix(end))
            let starts = FieldCleanupChunks.wordStarts(in: covered)
            let start = starts.isEmpty ? covered.endIndex : starts[max(0, starts.count - FieldCleanupChunks.overlap)]
            frontier = covered.distance(from: covered.startIndex, to: start)
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
    @MainActor public static func clean(_ source: String, using clean: (String) async -> String?) async -> String? {
        let starts = wordStarts(in: source)
        guard starts.count > words else { return await clean(source) }
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
            guard !Task.isCancelled, let result = await clean(input) else { return nil }
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
    /// cleaned; otherwise the first answer's failure. `calls` counts the cleanup calls made.
    @MainActor public static func cleanSplitting(_ source: String, using clean: (String) async -> Attempt)
        async -> (result: Attempt, calls: Int, keptRaw: Int) {
        var calls = 0, keptRaw = 0
        func part(_ text: String) async -> (text: String, cleaned: Bool)? {
            calls += 1
            switch await clean(text) {
            case .cleaned(let result): return (result, true)
            case .failed: return nil
            case .rejected:
                guard !Task.isCancelled, let cut = sentenceCut(in: text) else { keptRaw += 1; return (text, false) }
                let left = String(text[..<cut]), right = String(text[cut...])
                guard let a = await part(left), let b = await part(right) else { return nil }
                return (keepingSeparators(of: left, around: a.text) + keepingSeparators(of: right, around: b.text), a.cleaned || b.cleaned)
            }
        }
        calls += 1
        let first = await clean(source)
        guard case .rejected = first, let cut = sentenceCut(in: source) else { return (first, calls, 0) }
        let left = String(source[..<cut]), right = String(source[cut...])
        guard let a = await part(left), let b = await part(right) else { return (.rejected, calls, keptRaw) }
        guard a.cleaned || b.cleaned else { return (.rejected, calls, keptRaw) }
        return (.cleaned(keepingSeparators(of: left, around: a.text) + keepingSeparators(of: right, around: b.text)), calls, keptRaw)
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
