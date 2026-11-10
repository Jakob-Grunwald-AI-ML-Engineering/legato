import Foundation

/// The text field as the keyboard sees it: two small windows around the cursor that the host updates asynchronously
/// after a move. `UITextDocumentProxy` in the extension, a fake in tests.
@MainActor public protocol FieldWindowProxy: AnyObject {
    /// `documentContextBeforeInput` (empty when none).
    var windowBefore: String { get }
    /// `documentContextAfterInput` (empty when none).
    var windowAfter: String { get }
    /// Stop exploration, then restore and verify the original position before reporting cancellation.
    var isCancelled: Bool { get }
    /// `adjustTextPosition(byCharacterOffset:)`, in UTF-16 units.
    func move(by units: Int)
    /// Gives the host time to update the windows.
    func pause(milliseconds: Int) async
}

public extension FieldWindowProxy {
    var isCancelled: Bool { false }
}

/// Reads the field upward (`readUp`) or downward (`readDown`) from the cursor, a window at a time, and returns the
/// cursor where it was.
///
/// Walking is rare (it visibly moves the cursor) and self-verifying: a window pair counts only after two identical
/// consecutive reads that also stitch onto the text read so far (the window after the new position must start with
/// it). Some hosts return windows that do not tile at some boundaries (long Messages fields): re-reading does not fix
/// that, so a pair that never stitches ends the read with an error, never with partial or wrong text.
///
/// Block-based hosts (Safari's `contenteditable`, WebKit text areas) stop their windows at a block: the window after the
/// cursor ends at its block's end, and a window before that starts right at a block's start begins with the boundary
/// as "\n " (a space the text does not hold; moving across the boundary counts one unit, as "\n"). So a window that
/// starts with a line break is trusted only after that break and its blanks (`trusted(before:)`): the rest is read again
/// from further up, and the boundary itself is crossed one unit at a time. An empty window after a position counts as
/// the end of a block when the text read below it starts with a line break.
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
        /// Whether the field shows a paragraph break as "\n\n" while it moves over it as one unit (Safari's
        /// `contenteditable` with `<p>` paragraphs): then `text` holds one "\n" per break, as the field counts it. Nil:
        /// no doubled break was seen.
        public var collapsesBreaks: Bool?
        /// Whether the field moves the cursor one unit per character (Safari: an emoji is one unit) rather than per
        /// UTF-16 unit (UIKit: an emoji is two). Nil: no character of more than one unit was moved over.
        public var movesByCharacters: Bool?
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
        /// The caller cancelled and the original cursor position was verified after restoration.
        case cancelled
        /// The first move up did not land where the windows said: the host shows windows for a cursor that is not where
        /// a move starts from. Safari does this with a selection it does not report (`selectedText` nil after Select All):
        /// the move collapses the selection at its end.
        case firstMove

        /// The host's windows never agreed: reading again cannot help.
        public var isLasting: Bool {
            switch self { case .unstable, .stitch, .firstMove: true; case .changed, .cursorLost, .cancelled: false }
        }

        public var message: String {
            switch self {
            case .cancelled: "Reading cancelled. The cursor is back where it started."
            case .changed: "The text changed while it was read."
            case .unstable, .stitch: "Can't read this app's text reliably. Instructions still work on text you dictate with Legato."
            case .cursorLost: "This app did not confirm the cursor returned after reading."
            case .firstMove: "Can't read this app's text from here. If text was selected, put the cursor in the paragraph instead."
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

    /// Known from an earlier read of this field (`Result.collapsesBreaks`); nil: found out on the way.
    public var collapsesBreaks: Bool?
    /// Known from an earlier read of this field (`Result.movesByCharacters`); nil: found out on the way.
    public var movesByCharacters: Bool?

    public init(cap: Int = FieldReader.defaultCap, blockLimit: Int = FieldReader.blockLimit, maxRereads: Int = 10, settleMilliseconds: Int = 15,
                collapsesBreaks: Bool? = nil, movesByCharacters: Bool? = nil) {
        self.cap = cap; self.blockLimit = blockLimit; self.maxRereads = maxRereads; self.settleMilliseconds = settleMilliseconds
        self.collapsesBreaks = collapsesBreaks; self.movesByCharacters = movesByCharacters
    }

    /// The cursor movement over `text`, in the field's units.
    static func units(_ text: some StringProtocol, byCharacters: Bool) -> Int { byCharacters ? text.count : text.utf16.count }

    /// Whether the field moves the cursor one unit per character (an emoji is one unit) rather than per UTF-16 unit: the
    /// cursor goes back over the last such character in `text` (which ends at the cursor) by its UTF-16 length. A UTF-16
    /// field lands right before it; a character field one character further. The cursor comes back. Nil: nothing to tell by.
    static func movesOneUnitPerCharacter(_ proxy: any FieldWindowProxy, before text: String, settle: Int) async -> Bool? {
        guard let wide = text.lastIndex(where: { $0.utf16.count > 1 }), text.distance(from: text.startIndex, to: wide) > 6 else { return nil }
        let distance = text[wide...].utf16.count
        proxy.move(by: -distance)
        var window: String?, previous: String?
        for _ in 0..<12 {
            await proxy.pause(milliseconds: settle)
            let now = proxy.windowBefore
            if now == previous { window = now; break }
            previous = now
        }
        let shown = window ?? previous ?? ""
        let preceding = text[..<wide]
        let byUnits = shown.hasSuffix(preceding.suffix(6))
        let byCharacters = !byUnits && shown.hasSuffix(preceding.dropLast(text[wide].utf16.count - 1).suffix(6))
        // Back by the same count, as this field moves.
        proxy.move(by: distance)
        await proxy.pause(milliseconds: settle)
        return byUnits ? false : (byCharacters ? true : nil)
    }

    /// `window` with each doubled line break ("\n\n", one paragraph break in a `<p>` field) as one.
    public static func collapsed(_ window: String) -> String { window.replacingOccurrences(of: "\n\n", with: "\n") }

    /// Whether a doubled line break in the windows is one unit of cursor movement (a `<p>` boundary) rather than two line
    /// breaks: the cursor goes to just past the break (`behind` units back) or just before it (`ahead` units on), steps
    /// one unit over it, and the window there shows whether a line break is left. The cursor comes back.
    static func breakIsOneUnit(_ proxy: any FieldWindowProxy, behind: Int = 0, ahead: Int = 0, settle: Int) async -> Bool {
        let back = behind > 0 || ahead == 0
        let distance = (back ? behind : ahead) + 1
        proxy.move(by: back ? -distance : distance)
        var window: String?, previous: String?
        for _ in 0..<12 {
            await proxy.pause(milliseconds: settle)
            let now = back ? proxy.windowBefore : proxy.windowAfter
            if now == previous { window = now; break }
            previous = now
        }
        proxy.move(by: back ? distance : -distance)
        await proxy.pause(milliseconds: settle)
        let shown = window ?? previous ?? ""
        // Two real line breaks leave one next to the cursor; a paragraph boundary leaves the paragraph's text.
        return back ? shown.last?.isNewline != true : shown.first?.isNewline != true
    }

    /// Extends `known` (verified text that ends at the cursor; empty for a first read) upward.
    public func readUp(_ proxy: any FieldWindowProxy, known: String, limit: Limit) async -> Swift.Result<Result, Failure> {
        guard !proxy.isCancelled else { return .failure(.cancelled) }
        // What was read before must still be what the field shows before the cursor.
        let originAfter = proxy.windowAfter
        let originBefore = proxy.windowBefore
        let reported = collapsesBreaks == true ? Self.collapsed(originBefore) : originBefore
        guard known.isEmpty || OwnEditEcho.isSame(expected: known, reported: reported) else { return .failure(.changed) }
        var text = known
        var added = ""
        var moved = 0
        var result = Result(text: known, added: 0, stop: .start, moreRemains: false)
        var byCharacters = movesByCharacters ?? false, unitsKnown = movesByCharacters != nil
        if !unitsKnown, let probed = await Self.movesOneUnitPerCharacter(proxy, before: reported, settle: settleMilliseconds) {
            byCharacters = probed; unitsKnown = true
        }
        if !known.isEmpty {
            // The text already read is jumped over in one move: no reads in between.
            moved = Self.units(known, byCharacters: byCharacters)
            proxy.move(by: -moved)
            if !unitsKnown, known.utf16.count != known.count {
                // A wide character beyond the window: whichever count lands where the text read shows after the cursor.
                let landed = await stablePair(proxy, offset: moved, result: &result) { Self.stitches(after: $0.after, onto: known) }
                if case .failure = landed {
                    let other = known.count
                    proxy.move(by: moved - other); moved = other
                    byCharacters = true
                }
                unitsKnown = true
            }
        }
        var failure: Failure?
        // Doubled breaks: taken as they show until a move over one shows otherwise (then one unit each, for good).
        var collapse = collapsesBreaks ?? false, decided = collapsesBreaks != nil
        while true {
            if proxy.isCancelled { failure = .cancelled; break }
            let pair: (before: String, after: String)
            let read = text
            switch await stablePair(proxy, offset: moved, result: &result, stitches: {
                Self.stitches(after: collapse ? Self.collapsed($0.after) : $0.after, onto: read)
            }) {
            case .failure(let reason):
                // Nothing above the cursor was accepted after a move: the move itself went elsewhere.
                if case .stitch = reason, result.steps == 1, known.isEmpty { failure = .firstMove } else { failure = reason }
            case .success(let value): pair = value; result.steps += 1
                if pair.before.isEmpty { result.stop = .start; result.moreRemains = false; break }
                if !unitsKnown, let probed = await Self.movesOneUnitPerCharacter(proxy, before: String(Self.trusted(before: pair.before)), settle: settleMilliseconds) {
                    byCharacters = probed; unitsKnown = true
                }
                if !decided, let shown = Optional(Self.trusted(before: pair.before)), let cut = shown.range(of: "\n\n", options: .backwards) {
                    // How many units is a doubled break? Two moves next to the last one tell (and come back).
                    collapse = await Self.breakIsOneUnit(proxy, behind: shown[cut.upperBound...].utf16.count, settle: settleMilliseconds)
                    decided = true
                }
                var window = String(Self.trusted(before: collapse ? Self.collapsed(pair.before) : pair.before))
                // Only a block boundary in view: it is crossed on its own, as the one unit it moves.
                if window.isEmpty { window = "\n" }
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
                let units = Self.units(window, byCharacters: byCharacters)
                proxy.move(by: -units)
                moved += units
                continue
            }
            break
        }
        if decided { result.collapsesBreaks = collapse }
        if unitsKnown { result.movesByCharacters = byCharacters }
        // Back to the cursor in one move, then make sure it is there.
        if moved > 0 { proxy.move(by: moved) }
        // A stable but wrong pair may be a stale report. Keep waiting for the original position, not merely any
        // repeated window; validate both sides so repeated text cannot masquerade as restoration.
        var previous: (String, String)?
        var restored = false
        for _ in 0...(maxRereads + 1) {
            await proxy.pause(milliseconds: settleMilliseconds)
            let pair = (collapse ? Self.collapsed(proxy.windowBefore) : proxy.windowBefore,
                        collapse ? Self.collapsed(proxy.windowAfter) : proxy.windowAfter)
            let expectedBefore = collapse ? Self.collapsed(originBefore) : originBefore
            let expectedAfter = collapse ? Self.collapsed(originAfter) : originAfter
            let beforeMatches = expectedBefore.isEmpty ? pair.0.isEmpty : Self.stitches(before: pair.0, onto: expectedBefore)
            let afterMatches = expectedAfter.isEmpty ? pair.1.isEmpty : Self.stitches(after: pair.1, onto: expectedAfter)
            if let previous, previous == pair, beforeMatches, afterMatches { restored = true; break }
            previous = pair
        }
        guard restored else { return .failure(.cursorLost) }
        if let failure { return .failure(failure) }
        result.text = text
        result.added = added.count
        return .success(result)
    }

    /// Extends `known` (text that starts at the cursor, as the host's window after it showed it; empty for none)
    /// downward, the same self-verifying way as `readUp`: a window counts after two identical reads whose window
    /// before the new position ends with the text read so far. `room` caps the characters below the cursor. Stops at
    /// the field's end (`.start` stands for it here: nothing more), at a structural stop below (a quote header, quoted
    /// lines, a signature: the text from that line on is not the user's), or at `room`. The cursor goes back where it was.
    public func readDown(_ proxy: any FieldWindowProxy, known: String, room: Int) async -> Swift.Result<Result, Failure> {
        guard !proxy.isCancelled else { return .failure(.cancelled) }
        var collapse = collapsesBreaks ?? false, decided = collapsesBreaks != nil
        func shown(_ window: String) -> String { collapse ? Self.collapsed(window) : window }
        guard known.isEmpty || Self.stitches(after: shown(proxy.windowAfter), onto: known) else { return .failure(.changed) }
        let originWindow = proxy.windowBefore
        var text = known
        var moved = 0
        var result = Result(text: known, added: 0, stop: .start, moreRemains: false)
        let byCharacters = movesByCharacters ?? false
        if !known.isEmpty {
            // The text already known is jumped over in one move.
            moved = Self.units(known, byCharacters: byCharacters)
            proxy.move(by: moved)
        }
        var failure: Failure?
        while true {
            if proxy.isCancelled { failure = .cancelled; break }
            let read = text
            switch await stablePair(proxy, offset: moved, result: &result, stitches: { Self.stitches(before: shown($0.before), onto: read) }) {
            case .failure(let reason): failure = reason
            case .success(let pair):
                result.steps += 1
                if !decided, let cut = pair.after.range(of: "\n\n") {
                    collapse = await Self.breakIsOneUnit(proxy, ahead: pair.after[..<cut.lowerBound].utf16.count, settle: settleMilliseconds)
                    decided = true
                }
                var window = shown(pair.after)
                if window.isEmpty {
                    // The end of the field, or of a block (the host's window stops there): one unit on tells them apart.
                    guard let crossed = await crossBlockEnd(proxy, before: pair.before, offset: moved, result: &result) else {
                        result.stop = .start; result.moreRemains = false; break
                    }
                    switch crossed {
                    case .failure(let reason): failure = reason
                    case .success:
                        text += "\n"; moved += 1
                        guard text.count < room else { result.stop = .cap; result.moreRemains = true; break }
                        continue
                    }
                    break
                }
                let left = room - text.count
                let clipped = window.count >= left
                if clipped { window = String(window.prefix(max(0, left))) }
                text += window
                if let stop = Self.structuralStopBelow(in: text) {
                    text = String(text[..<stop.index])
                    result.stop = stop.kind; result.moreRemains = true
                    break
                }
                if clipped {
                    text = Self.trimToLineEnd(text: text, keeping: known.count)
                    result.stop = .cap; result.moreRemains = true
                    break
                }
                let units = Self.units(window, byCharacters: byCharacters)
                proxy.move(by: units)
                moved += units
                continue
            }
            break
        }
        if decided { result.collapsesBreaks = collapse }
        if moved > 0 { proxy.move(by: -moved) }
        // Back at the cursor: two reads that agree, the window after starting with what was read, the one before as it was.
        var back: (before: String, after: String)?
        var previous: (String, String)?
        for _ in 0...(maxRereads + 1) {
            await proxy.pause(milliseconds: settleMilliseconds)
            let pair = (shown(proxy.windowBefore), shown(proxy.windowAfter))
            let afterMatches = known.isEmpty ? Self.stitches(after: pair.1, onto: text) : Self.stitches(after: pair.1, onto: known)
            let beforeMatches = shown(originWindow).isEmpty ? pair.0.isEmpty : Self.stitches(before: pair.0, onto: shown(originWindow))
            if let previous, previous == pair, afterMatches, beforeMatches { back = pair; break }
            previous = pair
        }
        guard back != nil else { return .failure(.cursorLost) }
        if let failure { return .failure(failure) }
        result.text = text
        result.added = max(0, text.count - known.count)
        return .success(result)
    }

    /// At an empty window after the cursor: moves one unit on. Nil when the cursor did not move (the field's end); else
    /// success when the window before now ends with a line break (a block boundary was crossed), a failure otherwise.
    private func crossBlockEnd(_ proxy: any FieldWindowProxy, before: String, offset: Int,
                               result: inout Result) async -> Swift.Result<Void, Failure>? {
        proxy.move(by: 1)
        switch await stablePair(proxy, offset: offset + 1, result: &result, stitches: { _ in true }) {
        case .failure(let reason): proxy.move(by: -1); return .failure(reason)
        case .success(let pair):
            if pair.before == before { return nil }
            guard pair.before.last?.isNewline == true else { proxy.move(by: -1); return .failure(.stitch(offset: offset)) }
            return .success(())
        }
    }

    /// Two identical consecutive reads that stitch onto `text` (the window after the position starts with it).
    private func stablePair(_ proxy: any FieldWindowProxy, stitching text: String, offset: Int,
                            result: inout Result) async -> Swift.Result<(before: String, after: String), Failure> {
        await stablePair(proxy, offset: offset, result: &result) { Self.stitches(after: $0.after, onto: text) }
    }

    private func stablePair(_ proxy: any FieldWindowProxy, offset: Int, result: inout Result,
                            stitches: ((before: String, after: String)) -> Bool) async -> Swift.Result<(before: String, after: String), Failure> {
        var last: (String, String)?
        var failure = Failure.unstable(offset: offset)
        for attempt in 0...(maxRereads + 1) {
            await proxy.pause(milliseconds: settleMilliseconds)
            let pair = (proxy.windowBefore, proxy.windowAfter)
            if attempt > 1 { result.rereads += 1 }
            if let previous = last, previous == pair {
                if stitches((pair.0, pair.1)) { return .success((pair.0, pair.1)) }
                failure = .stitch(offset: offset)
            }
            last = pair
        }
        return .failure(failure)
    }

    /// The window after a position must start with the text read below it (each side may be cut short). An empty
    /// window right before a line break is a block's end (block-based hosts stop the window there).
    public static func stitches(after window: String, onto text: String) -> Bool {
        if text.isEmpty { return true }
        if window.isEmpty { return text.first?.isNewline == true }
        return text.hasPrefix(window) || window.hasPrefix(text)
    }

    /// The window before a position must end with the text read above it (each side may be cut short).
    public static func stitches(before window: String, onto text: String) -> Bool {
        if text.isEmpty { return true }
        if window.isEmpty { return false }
        if text.hasSuffix(window) || window.hasSuffix(text) { return true }
        // A window that starts at its block ("\n "): its block is the end of the text, after a line break there.
        let trusted = trusted(before: window)
        guard !trusted.isEmpty, trusted.count < window.count, text.hasSuffix(trusted) else { return false }
        return text.dropLast(trusted.count).last?.isNewline == true
    }

    /// The part of a window before the cursor that is the field's text: all of it, unless it starts with a line break
    /// (a block-based host's boundary, "\n " in WebKit): then what follows the break and its blanks.
    nonisolated public static func trusted(before window: String) -> Substring {
        guard window.first?.isNewline == true else { return Substring(window) }
        return window.drop { $0.isNewline || $0 == " " || $0 == "\t" }
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

    /// The nearest structural stop below the start of `text` (read downward from the cursor): where its line begins.
    /// The cursor's own line and a last line that may be cut off (no line break after it yet) never count.
    public static func structuralStopBelow(in text: String) -> Stop? {
        guard var start = text.firstIndex(where: \.isNewline).map({ text.index(after: $0) }) else { return nil }
        while start < text.endIndex {
            guard let end = text[start...].firstIndex(where: \.isNewline) else { return nil }
            if let kind = stopKind(of: text[start..<end]) { return Stop(index: start, kind: kind) }
            start = text.index(after: end)
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

    /// A downward read cut by its room ends at a line end close to the cut, else at a word end; the first `keeping`
    /// characters (known before the read) always stay.
    static func trimToLineEnd(text: String, keeping: Int) -> String {
        let floor = text.index(text.startIndex, offsetBy: min(keeping, text.count))
        let tail = text[floor...]
        if let newline = tail.suffix(300).lastIndex(where: \.isNewline) { return String(text[..<newline]) }
        if let space = tail.lastIndex(where: \.isWhitespace) { return String(text[..<space]) }
        return text
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
