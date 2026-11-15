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
            // Providers trim boundary spaces. Keep existing separators so chunk joins cannot
            // swallow a list break or glue words together. Interior formatting belongs to cleanup.
            let lead = String(input.prefix(while: \.isWhitespace))
            let trail = String(input.reversed().prefix(while: \.isWhitespace).reversed())
            let joined = lead.isEmpty && trail.isEmpty ? result : lead + result.trimmingCharacters(in: .whitespacesAndNewlines) + trail
            output = String(output[..<overlapStart]) + joined
            consumed = end
        }
        return output
    }
}
