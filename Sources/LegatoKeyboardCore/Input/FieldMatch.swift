import Foundation

/// Where a host's report (the text before and after the cursor, cut to its window) fits in known text. The field queue
/// confirms an op only when the report pins the cursor at the expected place and at no other: a short web window (a
/// few words, often nothing after the cursor) that also fits where the cursor was before a move confirms nothing.
public enum FieldMatch {
    /// The reverse match (the report reaches back past the known text) needs this much known text before the cursor:
    /// a report that merely ends in the first few characters of the known text says nothing about where it is.
    public static let reverseMatchChars = 12

    /// Whether the report pins the cursor at the end of `expectedBefore`, in `expectedBefore + expectedAfter`.
    public static func confirms(expectedBefore: String, expectedAfter: String, reportedBefore: String, reportedAfter: String) -> Bool {
        let before = Array(expectedBefore)
        return positions(in: before + Array(expectedAfter), reportedBefore: reportedBefore, reportedAfter: reportedAfter) == [before.count]
    }

    /// Every cursor position (characters into `text`) the field's report fits. Before the cursor the report is the
    /// known text's end there (hosts trim their context), or reaches back past the start of the known text; nothing
    /// reported before it fits only the start. After the cursor the report starts with the known text there, or is a
    /// trimmed part of it, or goes on past it; nothing reported after it fits anywhere.
    ///
    /// A block-based host's window that starts at a block's start begins with "\n " (`FieldReader.trusted(before:)`):
    /// when the report fits nowhere as it is (or only past the known text's end), its trusted part counts, at positions
    /// where a line break precedes it.
    public static func positions(in text: [Character], reportedBefore: String, reportedAfter: String) -> [Int] {
        let exact = fits(in: text, reportedBefore: Array(reportedBefore), reportedAfter: Array(reportedAfter))
        let trusted = Array(FieldReader.trusted(before: reportedBefore))
        guard trusted.count < reportedBefore.count, reportedBefore.first?.isNewline == true else { return exact }
        // Exact fits whose report after the cursor runs past the known text's end say little: the echo reading counts
        // as well (an emptied block, "\n " then a space, also fits a model that knows nothing past it).
        if !exact.isEmpty {
            guard exact.allSatisfy({ $0 + reportedAfter.count > text.count }) else { return exact }
            let echoed = echoPositions(in: text, reportedBefore: reportedBefore, reportedAfter: reportedAfter)
                .filter { $0 + reportedAfter.count <= text.count }
            return Array(Set(exact + echoed)).sorted()
        }
        return echoPositions(in: text, reportedBefore: reportedBefore, reportedAfter: reportedAfter)
    }

    /// Where the report fits when its start is a block's echo ("\n "): its trusted part, after a line break.
    private static func echoPositions(in text: [Character], reportedBefore: String, reportedAfter: String) -> [Int] {
        let trusted = Array(FieldReader.trusted(before: reportedBefore))
        // The echo is the line break and one space: spaces after it are the block's own (a space typed at its start).
        let echo = reportedBefore.drop(while: \.isNewline)
        let ownSpaces = Array(echo.first == " " ? echo.dropFirst() : echo)
        if ownSpaces.count > trusted.count {
            let start = { (p: Int) in p - ownSpaces.count }
            let spaced = fits(in: text, reportedBefore: ownSpaces, reportedAfter: Array(reportedAfter)).filter { p in
                start(p) > 0 && text[start(p) - 1].isNewline
            }
            if !spaced.isEmpty { return spaced }
        }
        if trusted.isEmpty {
            // Only the boundary: the cursor is at a block's start, a line break before it. With nothing reported after
            // it, the block is empty (a line break or the end follows); otherwise the report after it must fit there.
            let after = Array(reportedAfter)
            return (1...max(1, text.count)).filter { p in
                guard p <= text.count, text[p - 1].isNewline else { return false }
                if after.isEmpty { return p == text.count || text[p].isNewline }
                let n = min(after.count, text.count - p)
                return n > 0 && text[p..<(p + n)].elementsEqual(after[..<n])
            }
        }
        return fits(in: text, reportedBefore: trusted, reportedAfter: Array(reportedAfter)).filter { p in
            let start = p - trusted.count
            return start > 0 && text[start - 1].isNewline
        }
    }

    private static func fits(in text: [Character], reportedBefore rb: [Character], reportedAfter ra: [Character]) -> [Int] {
        func beforeFits(_ p: Int) -> Bool {
            if rb.isEmpty { return p == 0 }
            if p >= rb.count { return text[(p - rb.count)..<p].elementsEqual(rb) }
            return p >= reverseMatchChars && rb[(rb.count - p)...].elementsEqual(text[..<p])
        }
        func afterFits(_ p: Int) -> Bool {
            let n = min(ra.count, text.count - p)
            return text[p..<(p + n)].elementsEqual(ra[..<n])
        }
        return (0...text.count).filter { p in
            (rb.isEmpty || (p > 0 && text[p - 1] == rb[rb.count - 1])) && beforeFits(p) && afterFits(p)
        }
    }
}
