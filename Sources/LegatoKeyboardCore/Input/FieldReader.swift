import Foundation

/// The text field as the keyboard sees it: two small windows around the cursor that the host updates asynchronously
/// after a move. `UITextDocumentProxy` in the extension, a fake in tests.
@MainActor public protocol FieldWindowProxy: AnyObject {
    /// `documentContextBeforeInput` (empty when none).
    var windowBefore: String { get }
    /// `documentContextAfterInput` (empty when none).
    var windowAfter: String { get }
    /// `adjustTextPosition(byCharacterOffset:)`, in UTF-16 units.
    func move(by units: Int)
    /// Gives the host time to update the windows.
    func pause(milliseconds: Int) async
}

/// Reads the field upward from the cursor, a window at a time, and returns the cursor where it was.
///
/// Walking is rare (it visibly moves the cursor) and self-verifying: a window pair counts only after two identical
/// consecutive reads that also stitch onto the text read so far (the window after the new position must start with
/// it). Some hosts return windows that do not tile at some boundaries (long Messages fields): re-reading does not fix
/// that, so a pair that never stitches ends the read with an error, never with partial or wrong text.
///
/// The read stops at the nearest structural stop above the cursor (the field's start, a quote header, quoted lines,
/// a signature delimiter), at `cap` characters, or after one block for `read_more`.
@MainActor public struct FieldReader {
    public enum Limit: Sendable, Equatable {
        /// One block (`read_more`): a paragraph group of at most `blockLimit` new characters.
        case block
        /// Up to `cap` characters in all.
        case cap
    }

    public struct Result: Sendable, Equatable {
        /// Verified text above the cursor: what was known plus what was read, from the stop down to the cursor.
        public var text: String
        /// Characters newly read.
        public var added: Int
        public var stop: FieldStop
        /// Text continues above `text`.
        public var moreRemains: Bool
        /// Windows accepted, and reads beyond the first of each.
        public var steps = 0
        public var rereads = 0
    }

    public enum Failure: Error, Sendable, Equatable {
        /// The field around the cursor no longer shows what was read before.
        case changed
        /// Two consecutive reads never agreed (`offset`: UTF-16 units above the cursor).
        case unstable(offset: Int)
        /// The windows did not tile with what was read (`offset`: UTF-16 units above the cursor).
        case stitch(offset: Int)
        /// After the walk the cursor is not back where it was.
        case cursorLost

        public var message: String {
            switch self {
            case .changed: "The text changed while it was read."
            case .unstable, .stitch: "This app's text could not be read reliably."
            case .cursorLost: "The cursor moved while the text was read."
            }
        }
    }

    public static let defaultCap = 3000
    public static let blockLimit = 1000
    /// A block ends early at a paragraph break once it holds at least this many new characters.
    public static let blockMinimum = 200

    public var cap: Int
    public var blockLimit: Int
    public var maxRereads: Int
    public var settleMilliseconds: Int

    public init(cap: Int = FieldReader.defaultCap, blockLimit: Int = FieldReader.blockLimit, maxRereads: Int = 10, settleMilliseconds: Int = 15) {
        self.cap = cap; self.blockLimit = blockLimit; self.maxRereads = maxRereads; self.settleMilliseconds = settleMilliseconds
    }

    /// Extends `known` (verified text that ends at the cursor; empty for a first read) upward.
    public func readUp(_ proxy: any FieldWindowProxy, known: String, limit: Limit) async -> Swift.Result<Result, Failure> {
        // What was read before must still be what the field shows before the cursor.
        guard known.isEmpty || OwnEditEcho.isSame(expected: known, reported: proxy.windowBefore) else { return .failure(.changed) }
        var text = known
        var added = ""
        var moved = 0
        var result = Result(text: known, added: 0, stop: .start, moreRemains: false)
        if !known.isEmpty {
            // The text already read is jumped over in one move: no reads in between.
            moved = known.utf16.count
            proxy.move(by: -moved)
        }
        var failure: Failure?
        while true {
            let pair: (before: String, after: String)
            switch await stablePair(proxy, stitching: text, offset: moved, result: &result) {
            case .failure(let reason): failure = reason
            case .success(let value): pair = value; result.steps += 1
                var window = pair.before
                if window.isEmpty { result.stop = .start; result.moreRemains = false; break }
                let room = limit == .cap ? cap - text.count : blockLimit - added.count
                let clipped = window.count >= room
                if clipped { window = String(window.suffix(max(0, room))) }
                text = window + text
                added = window + added
                if let stop = Self.structuralStop(in: text, atFieldStart: false) {
                    text = String(text[stop.index...])
                    added = String(added.suffix(max(0, text.count - known.count)))
                    result.stop = stop.kind; result.moreRemains = true
                    break
                }
                if clipped || text.count >= cap {
                    (text, added) = Self.trimToLineStart(text: text, added: added)
                    result.stop = limit == .block && text.count < cap ? .block : .cap
                    result.moreRemains = true
                    break
                }
                if limit == .block, let cut = Self.blockStart(in: added) {
                    let dropped = added.distance(from: added.startIndex, to: cut)
                    text = String(text.dropFirst(dropped)); added = String(added[cut...])
                    result.stop = .block; result.moreRemains = true
                    break
                }
                let units = window.utf16.count
                proxy.move(by: -units)
                moved += units
                continue
            }
            break
        }
        // Back to the cursor in one move, then make sure it is there.
        if moved > 0 { proxy.move(by: moved) }
        if let failure { return .failure(failure) }
        // The host reports the cursor's return late as well: two reads that agree.
        var back: String?
        var last: String?
        for _ in 0...(maxRereads + 1) {
            await proxy.pause(milliseconds: settleMilliseconds)
            let window = proxy.windowBefore
            if window == last { back = window; break }
            last = window
        }
        guard let back, text.isEmpty ? back.isEmpty : OwnEditEcho.isSame(expected: text, reported: back) else { return .failure(.cursorLost) }
        result.text = text
        result.added = added.count
        return .success(result)
    }

    /// Two identical consecutive reads that stitch onto `text` (the window after the position starts with it).
    private func stablePair(_ proxy: any FieldWindowProxy, stitching text: String, offset: Int,
                            result: inout Result) async -> Swift.Result<(before: String, after: String), Failure> {
        var last: (String, String)?
        var failure = Failure.unstable(offset: offset)
        for attempt in 0...(maxRereads + 1) {
            await proxy.pause(milliseconds: settleMilliseconds)
            let pair = (proxy.windowBefore, proxy.windowAfter)
            if attempt > 1 { result.rereads += 1 }
            if let previous = last, previous == pair {
                if Self.stitches(after: pair.1, onto: text) { return .success((pair.0, pair.1)) }
                failure = .stitch(offset: offset)
            }
            last = pair
        }
        return .failure(failure)
    }

    /// The window after a position must start with the text read below it (each side may be cut short).
    public static func stitches(after window: String, onto text: String) -> Bool {
        if text.isEmpty { return true }
        if window.isEmpty { return false }
        return text.hasPrefix(window) || window.hasPrefix(text)
    }

    // MARK: Structural stops

    public struct Stop: Equatable, Sendable {
        /// Where the text below the stop begins.
        public var index: String.Index
        public var kind: FieldStop
    }

    /// The nearest structural stop above the end of `text`: a quote header line, quoted (`>`) lines, an Outlook
    /// separator or a signature delimiter. Returns where the text below it begins. The first line counts only when
    /// `atFieldStart` (otherwise it may be the cut-off end of a longer line).
    public static func structuralStop(in text: String, atFieldStart: Bool) -> Stop? {
        var lines: [(range: Range<String.Index>, next: String.Index)] = []
        var start = text.startIndex
        while start < text.endIndex {
            let end = text[start...].firstIndex(where: \.isNewline) ?? text.endIndex
            let next = end < text.endIndex ? text.index(after: end) : end
            lines.append((start..<end, next))
            start = next
        }
        // The last line is the cursor's own (it may be unfinished): a stop there would leave nothing to edit.
        guard lines.count > 1 else { return nil }
        for i in stride(from: lines.count - 2, through: atFieldStart ? 0 : 1, by: -1) {
            let line = text[lines[i].range]
            if let kind = stopKind(of: line) { return Stop(index: lines[i].next, kind: kind) }
        }
        return nil
    }

    static func stopKind(of line: Substring) -> FieldStop? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if line == "-- " || trimmed == "--" { return .signature }
        if trimmed.hasPrefix(">") { return .quote }
        let lower = trimmed.lowercased()
        let separators = ["-----original message-----", "----- original message -----", "-----ursprüngliche nachricht-----",
                          "----- ursprüngliche nachricht -----", "-----forwarded message-----", "---------- forwarded message ---------"]
        if separators.contains(lower) { return .quote }
        if trimmed.count >= 10, trimmed.allSatisfy({ $0 == "_" }) { return .quote }
        // "On Mon, 3 Nov 2026 at 10:12, Anna <anna@example.com> wrote:" / "Am 03.11.2026 um 10:12 schrieb Anna:"
        if lower.hasSuffix(":"), trimmed.count <= 300 {
            let header = (lower.hasPrefix("on ") && lower.contains(" wrote"))
                || (lower.hasPrefix("am ") && lower.contains("schrieb"))
                || (lower.hasPrefix("le ") && lower.contains("a écrit"))
            if header { return .quote }
        }
        return nil
    }

    // MARK: Trimming

    /// Where a block that read `added` (newest text first) may begin: the first line start, when at least
    /// `blockMinimum` characters were read below it. The partial first line is left for the next block.
    static func blockStart(in added: String) -> String.Index? {
        guard added.count >= blockMinimum, let newline = added.firstIndex(where: \.isNewline) else { return nil }
        let start = added.index(after: newline)
        return added.distance(from: start, to: added.endIndex) >= blockMinimum ? start : nil
    }

    /// A read that was cut by a limit starts at a line start when the newly read part has one, else at a word start.
    static func trimToLineStart(text: String, added: String) -> (String, String) {
        var cut: String.Index?
        // A line start close to the top (a long line is not dropped whole for it), else a word start.
        if let newline = added.prefix(300).firstIndex(where: \.isNewline) { cut = added.index(after: newline) }
        else if let space = added.firstIndex(where: \.isWhitespace) { cut = added.index(after: space) }
        guard let cut, cut < added.endIndex else { return (text, added) }
        let dropped = added.distance(from: added.startIndex, to: cut)
        return (String(text.dropFirst(dropped)), String(added[cut...]))
    }
}
