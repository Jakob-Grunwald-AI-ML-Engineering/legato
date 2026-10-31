import Foundation

/// Types the app's cleaned dictation lines into the field, one line at a time and in order, with the typewriter's
/// pace (`TypewriterDrain`). Pure: the keyboard feeds it the publications and the text before the cursor, and
/// carries out the inserts it returns.
///
/// - A line starts against the cursor as it is then: it gets a separating space and the sentence capital the
///   text before the cursor calls for (`AutoCapitalizer`), so lines after a cursor move land correctly.
/// - A user edit (`interrupt`) or a context that is not the echo of the typist's own inserts (`OwnEditEcho`, given
///   `TypewriterReveal.settleLimitMs` to catch up) stops the rest of the current line; what is typed stays and the
///   following lines go in at the new cursor.
/// - A line is acknowledged once typed or stopped, never typed twice: lines at or below `typedThrough` are ignored.
public struct DictationTypist: Sendable, Equatable {
    public struct Step: Sendable, Equatable {
        public var inserts: [String] = []
        /// The highest line now typed or dropped, when it advanced in this step.
        public var acknowledged: Int?
    }
    private struct Active: Equatable {
        var seq: Int
        var text: [Character]
        var revealed = 0
        var expected: String
        var waitedMs = 0.0
    }

    public private(set) var sessionID: String?
    public private(set) var typedThrough = -1
    private var queue: [DictationLine] = []
    private var active: Active?

    public init() {}

    /// More steps are needed: a line is being typed or waits.
    public var needsTicks: Bool { active != nil || !queue.isEmpty }
    public var pendingCount: Int { queue.count + (active == nil ? 0 : 1) }

    /// `acknowledged`: the ack this keyboard wrote earlier (a restarted keyboard continues after it).
    public mutating func accept(_ publication: DictationPublication, acknowledged: DictationAck?) {
        if publication.sessionID != sessionID {
            sessionID = publication.sessionID
            queue = []; active = nil
            typedThrough = acknowledged?.sessionID == publication.sessionID ? acknowledged?.upTo ?? -1 : -1
        }
        for line in publication.lines.sorted(by: { $0.seq < $1.seq })
        where line.seq > typedThrough && line.seq != active?.seq && !queue.contains(where: { $0.seq == line.seq }) {
            queue.append(line)
        }
        queue.sort { $0.seq < $1.seq }
    }

    /// The user typed, deleted or moved the cursor: the rest of the current line is not typed.
    @discardableResult
    public mutating func interrupt() -> Int? {
        guard let current = active else { return nil }
        active = nil
        typedThrough = max(typedThrough, current.seq)
        return typedThrough
    }

    /// Everything still queued goes in now (the keyboard is going away).
    public mutating func flush(contextBefore: String, capitalization: AutoCapitalizationType) -> Step {
        var context = contextBefore, result = Step()
        while needsTicks {
            let step = step(contextBefore: context, elapsedMs: 0, capitalization: capitalization, animated: false)
            result.inserts += step.inserts; result.acknowledged = step.acknowledged ?? result.acknowledged
            context += step.inserts.joined()
            if step.inserts.isEmpty && step.acknowledged == nil { break }
        }
        return result
    }

    public mutating func step(
        contextBefore: String, elapsedMs: Double, capitalization: AutoCapitalizationType, animated: Bool = true
    ) -> Step {
        var step = Step()
        // What the field shows as this call goes on: its own inserts are in it.
        var contextBefore = contextBefore
        while true {
            if active == nil {
                guard !queue.isEmpty else { break }
                let line = queue.removeFirst()
                let text = Self.prepare(line.text, contextBefore: contextBefore, capitalization: capitalization)
                guard !text.isEmpty else { typedThrough = max(typedThrough, line.seq); step.acknowledged = typedThrough; continue }
                active = Active(seq: line.seq, text: Array(text), expected: contextBefore)
            }
            guard var current = active else { break }
            if !OwnEditEcho.isSame(expected: current.expected, reported: contextBefore) {
                current.waitedMs += elapsedMs
                if current.waitedMs < TypewriterReveal.settleLimitMs { active = current; return step }
                // Not the echo of our own inserts: the user moved on. The rest of this line is dropped.
                active = nil
                typedThrough = max(typedThrough, current.seq); step.acknowledged = typedThrough
                continue
            }
            current.waitedMs = 0
            let total = current.text.count
            let next = animated ? TypewriterDrain.step(revealed: current.revealed, target: total, dtMs: elapsedMs) : total
            if next > current.revealed {
                let slice = String(current.text[current.revealed..<next])
                step.inserts.append(slice)
                current.expected += slice
                contextBefore += slice
                current.revealed = next
            }
            if current.revealed >= total {
                active = nil
                typedThrough = max(typedThrough, current.seq); step.acknowledged = typedThrough
                if animated { break }
                continue
            }
            active = current
            break
        }
        return step
    }

    /// The text to type for `line` at this cursor: separated from what precedes it, capitalised after a sentence end.
    static func prepare(_ line: String, contextBefore: String, capitalization: AutoCapitalizationType) -> String {
        var text = line.trimmingCharacters(in: .whitespaces)
        guard let first = text.first else { return "" }
        var separator = ""
        if let last = contextBefore.last, !last.isWhitespace, !"([{“„‘‚".contains(last),
           !first.isNewline, !",.;:!?)]}%…’”".contains(first) {
            separator = " "
        }
        // The capital is judged where the line really starts: after the separator.
        if capitalization != .none, first.isLowercase,
           AutoCapitalizer.shouldCapitalize(capitalization, context: TextContext(documentContextBeforeInput: contextBefore + separator)) {
            text = first.uppercased() + text.dropFirst()
        }
        return separator + text
    }
}
