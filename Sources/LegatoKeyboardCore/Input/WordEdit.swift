import Foundation

/// One edit at the cursor: move `forward` characters, delete `deleteCount` characters backwards, then
/// insert `insert`. Units are Characters (grapheme clusters); `ProxyDocument` converts if the host
/// counts differently.
public struct WordEdit: Sendable, Equatable {
    public var forward: Int
    public var deleteCount: Int
    public var insert: String

    public init(forward: Int, deleteCount: Int, insert: String) {
        self.forward = forward
        self.deleteCount = deleteCount
        self.insert = insert
    }

    /// Replaces `span` (up to three words around the cursor) with `text`. With `matchingCaseOf`, a
    /// lowercase `text` takes that word's capitalisation.
    public static func replace(span: WordSpan, with text: String, matchingCaseOf typed: String? = nil) -> WordEdit {
        WordEdit(
            forward: span.after, deleteCount: span.before + span.after,
            insert: typed.map { matchCase(text, to: $0) } ?? text)
    }

    /// Completes the typed `prefix` with `candidate` and a trailing space, in the typed word's case.
    public static func complete(prefix: String, with candidate: String) -> WordEdit {
        WordEdit(forward: 0, deleteCount: prefix.count, insert: matchCase(candidate, to: prefix) + " ")
    }

    /// A lowercase candidate takes the typed word's capitalisation: all caps (two or more letters) or a
    /// capital first letter. A candidate with capitals of its own is left alone.
    public static func matchCase(_ candidate: String, to typed: String) -> String {
        guard candidate == candidate.lowercased(), let first = typed.first(where: \.isLetter) else { return candidate }
        let letters = typed.filter(\.isLetter)
        if letters.count >= 2, letters == letters.uppercased() { return candidate.uppercased() }
        if first.isUppercase, typed.first == first { return candidate.prefix(1).uppercased() + candidate.dropFirst() }
        return candidate
    }
}
