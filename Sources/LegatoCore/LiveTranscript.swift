import Foundation

/// The text of a run as it is being spoken: what is committed plus the tentative tail, with a
/// publish throttle. Feeds a size-limited surface such as a Live Activity.
///
/// Revision-capable: live cleanup's newest revision (`TranscriptEdit.revise`) replaces the run's text from
/// its start, followed by the raw text committed after it. `committed` stays the raw text as committed
/// (revision positions count in it); `revisedCommitted` and `text` show the revision.
public struct LiveTranscript: Sendable, Equatable {
    /// At most one publish per this interval (unless forced).
    public static let minPublishInterval: TimeInterval = 1

    private static let ellipsis = "…"

    public private(set) var committed = ""
    public private(set) var volatile = ""
    /// The newest revision applied, if any.
    public private(set) var revision: TranscriptRevision?
    private var lastPublished: Date?

    /// The revised committed text plus the tentative tail.
    public var text: String { revisedCommitted + volatile }

    /// `committed` with the newest revision applied.
    public var revisedCommitted: String {
        guard let revision else { return committed }
        return String(committed.prefix(revision.start)) + revision.text + String(committed.dropFirst(revision.end))
    }

    public init() {}

    public mutating func apply(_ edit: TranscriptEdit) {
        switch edit {
        case .commit(let delta): committed += delta
        case .replaceVolatile(let text): volatile = text
        case .revise(let new):
            // Only a newer revision of raw text that is there applies.
            guard new.n > (revision?.n ?? 0), new.start >= 0, new.end <= committed.count,
                  String(committed.dropFirst(new.start).prefix(new.raw.count)) == new.raw
            else { return }
            revision = new
        }
    }

    /// The end of `text`, for a surface with a character and a byte budget. Trimmed of surrounding
    /// whitespace. When it doesn't fit, the result starts with "…", is cut at a word boundary (a
    /// single overlong word is cut hard) and never splits a grapheme cluster. The result, "…"
    /// included, has at most `maxCharacters` characters and `maxBytes` UTF-8 bytes.
    public func tail(maxCharacters: Int = 120, maxBytes: Int = 1024) -> String {
        Self.tail(of: text, maxCharacters: maxCharacters, maxBytes: maxBytes)
    }

    public static func tail(of text: String, maxCharacters: Int = 120, maxBytes: Int = 1024) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count <= maxCharacters && trimmed.utf8.count <= maxBytes { return trimmed }

        let chars = Array(trimmed)
        let charBudget = max(maxCharacters - ellipsis.count, 0)
        var byteBudget = max(maxBytes - ellipsis.utf8.count, 0)
        var start = chars.endIndex
        while start > chars.startIndex, chars.endIndex - start < charBudget {
            let bytes = String(chars[start - 1]).utf8.count
            guard bytes <= byteBudget else { break }
            byteBudget -= bytes
            start -= 1
        }
        // Landed inside a word: drop its fragment, unless the slice is that one word.
        if start > chars.startIndex, start < chars.endIndex,
           !chars[start - 1].isWhitespace, !chars[start].isWhitespace,
           let gap = chars[start...].firstIndex(where: \.isWhitespace) {
            start = gap
        }
        while start < chars.endIndex, chars[start].isWhitespace { start += 1 }
        return ellipsis + String(chars[start...])
    }

    /// The tail to publish now, or nil when the last publish was less than `minPublishInterval` ago.
    /// `force` publishes regardless (a final state); either way a publish restarts the window.
    public mutating func publish(now: Date, force: Bool = false) -> String? {
        if !force, let last = lastPublished, now.timeIntervalSince(last) < Self.minPublishInterval {
            return nil
        }
        lastPublished = now
        return tail()
    }
}
