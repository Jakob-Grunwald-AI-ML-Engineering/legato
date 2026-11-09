import Foundation

/// Whether the context the host reports is the echo of the keyboard's own edit.
public enum OwnEditEcho {
    /// The host may trim its context differently from what the keyboard tracked, so a suffix match is the same
    /// text. An empty side only matches an empty side: "nothing before the cursor" is no suffix of anything.
    public static func isSame(expected: String, reported: String) -> Bool {
        if expected == reported { return true }
        guard !expected.isEmpty, !reported.isEmpty else { return false }
        if expected.hasSuffix(reported) || reported.hasSuffix(expected) { return true }
        // A block-based host starts a window at a block's start with "\n " (`FieldReader.trusted(before:)`).
        let trusted = FieldReader.trusted(before: reported)
        return trusted.count < reported.count && !trusted.isEmpty && expected.hasSuffix(trusted)
    }
}
