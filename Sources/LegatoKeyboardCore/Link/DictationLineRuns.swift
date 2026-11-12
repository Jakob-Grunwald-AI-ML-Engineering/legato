import Foundation

/// The typed-line modes (on stop, after a pause, line by line): each line the app publishes is a take of its own, typed
/// through the field queue as a run (`LiveDictationSnapshot`), one line at a time and in order. So a line gets what a live
/// take gets: it starts at the caret; the user's key lands at once and the rest of the line finishes in the line's own
/// text; a field the user moved to never gets any of it (the rest drops to History). Pure: the keyboard feeds it the
/// publications and the queue's outcomes, and enqueues the snapshots it returns.
///
/// - A line may still be growing (a streaming take: the same `seq`, more text, `final` once complete): each change is a
///   new version of its run.
/// - A `retracted` line (its streamed text was taken back) wants no text: what it typed is erased.
/// - A line is acknowledged once its final version landed, or it dropped; lines at or below `typedThrough` are never
///   typed again. A line that typed nothing when its field went away starts over in the next one.
public struct DictationLineRuns: Sendable, Equatable {
    private struct Active: Sendable, Equatable {
        var line: DictationLine
        var version: Int
        var started = false
    }

    public private(set) var sessionID: String?
    public private(set) var typedThrough = -1
    private var queue: [DictationLine] = []
    private var active: Active?

    public init() {}

    public static func runID(session: String, seq: Int) -> String { "line:\(session):\(seq)" }
    public static func isLineRun(_ runID: String) -> Bool { runID.hasPrefix("line:") }

    /// A line is on its way (typing, or waiting for its next version).
    public var isBusy: Bool { active != nil || !queue.isEmpty }

    /// A new publication: the snapshot to enqueue now (the active line's new version, or the next line's first), if any.
    /// `acknowledged`: the ack this keyboard wrote earlier (a restarted keyboard continues after it).
    public mutating func accept(_ publication: DictationPublication, acknowledged: DictationAck?) -> LiveDictationSnapshot? {
        if publication.sessionID != sessionID {
            sessionID = publication.sessionID
            queue = []; active = nil
            typedThrough = acknowledged?.sessionID == publication.sessionID ? acknowledged?.upTo ?? -1 : -1
        }
        var changed = false
        for line in publication.lines.sorted(by: { $0.seq < $1.seq }) where line.seq > typedThrough {
            if var current = active, current.line.seq == line.seq {
                guard line != current.line else { continue }
                current.line = line; current.version += 1
                active = current
                changed = true
            } else if let index = queue.firstIndex(where: { $0.seq == line.seq }) {
                queue[index] = line
            } else {
                queue.append(line)
            }
        }
        queue.sort { $0.seq < $1.seq }
        if active == nil { return startNext() }
        return changed ? snapshot() : nil
    }

    /// The run began typing in the field.
    public mutating func started(runID: String) {
        guard let current = active, runID == self.runID(current) else { return }
        active?.started = true
    }

    /// The queue shows the run's version: when that is the line's final version, the line is acknowledged (`ack`) and the
    /// next line's first snapshot comes (`next`).
    public mutating func applied(runID: String, version: Int) -> (ack: Int?, next: LiveDictationSnapshot?) {
        guard let current = active, runID == self.runID(current), version == current.version,
              current.line.final || current.line.retracted else { return (nil, nil) }
        return finish()
    }

    /// The run dropped (its field went away, or what it had to type could not land): the line is done, unless it typed
    /// nothing and its field went away (`reset`), when it starts over in the field the user is in now.
    public mutating func dropped(runID: String, reset: Bool) -> (ack: Int?, next: LiveDictationSnapshot?) {
        guard let current = active, runID == self.runID(current) else { return (nil, nil) }
        if reset, !current.started {
            active?.version += 1
            return (nil, snapshot())
        }
        return finish()
    }

    // MARK: Private

    private func runID(_ active: Active) -> String { Self.runID(session: sessionID ?? "", seq: active.line.seq) }

    private mutating func finish() -> (ack: Int?, next: LiveDictationSnapshot?) {
        guard let current = active else { return (nil, nil) }
        typedThrough = max(typedThrough, current.line.seq)
        active = nil
        return (typedThrough, startNext())
    }

    private mutating func startNext() -> LiveDictationSnapshot? {
        while !queue.isEmpty {
            let line = queue.removeFirst()
            guard line.seq > typedThrough else { continue }
            active = Active(line: line, version: 1)
            return snapshot()
        }
        return nil
    }

    private func snapshot() -> LiveDictationSnapshot? {
        guard let current = active else { return nil }
        let text = current.line.retracted ? "" : current.line.text
        let done = current.line.final || current.line.retracted
        return LiveDictationSnapshot(runID: runID(current), version: current.version,
                                     segments: [LiveSegment(id: 0, text: text, cleaned: true, final: done)], complete: done)
    }
}
