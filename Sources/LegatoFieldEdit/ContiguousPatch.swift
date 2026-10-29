import Foundation

/// The smallest single range replace that turns one text into another (ported from the #70 spike).
public enum ContiguousPatch {
    /// The step turning `old` into `new`, where `old` starts at UTF-16 offset `location` of the field; nil when
    /// the two are byte-equal. The common prefix and suffix are found at Character boundaries but compared
    /// byte for byte, so canonically equivalent spellings (a decomposed é) count as different and are kept.
    public static func between(_ old: String, _ new: String, at location: Int) -> EditStep? {
        between(old, new, at: location, prefixLimit: .max)
    }

    /// The same with the common prefix capped at `prefixLimit` UTF-16 units (a host change anchored at the
    /// caret: the prefix never runs past the lower of the two carets) and, with `suffix` false, no common suffix
    /// (the change reaches the end of `old`, as on the text before an iOS caret).
    static func between(
        _ old: String, _ new: String, at location: Int, prefixLimit: Int, suffix: Bool = true
    ) -> EditStep? {
        let a = Array(old), b = Array(new)
        var prefix = 0, prefixUnits = 0
        while prefix < min(a.count, b.count), byteEqual(a[prefix], b[prefix]),
            prefixUnits + a[prefix].utf16.count <= prefixLimit
        {
            prefixUnits += a[prefix].utf16.count
            prefix += 1
        }
        var tail = 0
        while suffix, tail < min(a.count, b.count) - prefix, byteEqual(a[a.count - 1 - tail], b[b.count - 1 - tail]) {
            tail += 1
        }
        let removed = String(a[prefix..<(a.count - tail)])
        let inserted = String(b[prefix..<(b.count - tail)])
        guard !removed.isEmpty || !inserted.isEmpty else { return nil }
        return EditStep(span: Span(location: location + prefixUnits, length: removed.utf16.count), text: inserted, expect: removed)
    }
}
