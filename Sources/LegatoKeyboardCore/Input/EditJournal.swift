import Foundation

/// The keyboard's edit journal: what went into the field queue, what it sent, what the field reported and what came of
/// it, with full text, one JSON object per line. Internal builds write it to the App Group
/// (`Library/Caches/edit-journal.jsonl`, the keyboard's `EditJournalFile`) so a device report can be pulled and replayed
/// against `FieldQueue` as a regression test.
public enum EditJournal {
    public static let fileName = "edit-journal.jsonl"
    public static let previousFileName = "edit-journal.1.jsonl"
    /// The file starts over (the old one kept as `previousFileName`) past this size.
    public static let rotateBytes = 2_000_000

    public enum Kind: String, Codable, Sendable {
        /// A field became the queue's (or the keyboard appeared).
        case field
        /// The user's key, delete or cursor move.
        case input
        /// An edit (word row, undo, version, Magic, typed line, host text).
        case edit
        /// A live dictation snapshot.
        case live
        /// The field was read for an instruction (`FieldQueue.markRead`; `id`: the instruction).
        case read
        /// The field's report, when it changed, and the step's outcome.
        case step
        case sent, confirmed, resync, nudged, applied, dropped, liveApplied, regionStarted, regionClosed
        /// The queue was reset (field change, keyboard gone).
        case reset
        /// The host's text or selection callback (`detail`: which, and the field's traits), with the report then.
        case callback
    }

    /// A `ShadowOp` as the journal writes it.
    public struct Op: Codable, Sendable, Equatable {
        public var move: Int?
        public var delete: Int?
        public var insert: String?
        public init(_ op: ShadowOp) {
            switch op {
            case .move(let units): move = units
            case .deleteBackward(let count): delete = count
            case .insert(let text): insert = text
            }
        }
        public var op: ShadowOp? {
            if let move { return .move(move) }
            if let delete { return .deleteBackward(delete) }
            return insert.map { .insert($0) }
        }
    }

    public struct Entry: Codable, Sendable, Equatable {
        /// Monotonic milliseconds (system uptime).
        public var t: Double
        public var kind: Kind
        public var field: String?
        public var run: String?
        public var id: String?
        public var input: FieldQueue.Input?
        public var edit: FieldQueue.Edit?
        public var user: Bool?
        public var snapshot: LiveDictationSnapshot?
        public var report: FieldQueue.Report?
        /// `send`, `wait` or `idle` for a step.
        public var action: String?
        public var op: Op?
        public var lane: FieldQueue.Lane?
        public var reason: String?
        public var text: String?
        public var partial: String?
        public var version: Int?
        /// Free-form detail (queue state, waited ms).
        public var detail: String?

        public init(t: Double, kind: Kind, field: String? = nil) { self.t = t; self.kind = kind; self.field = field }
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    /// One line of the journal (ends in a line break).
    public static func line(_ entry: Entry) -> Data {
        var data = (try? encoder.encode(entry)) ?? Data()
        data.append(0x0A)
        return data
    }

    /// The entries of a journal's text (lines that do not parse are skipped).
    public static func entries(_ text: String) -> [Entry] {
        let decoder = JSONDecoder()
        return text.split(whereSeparator: \.isNewline).compactMap { try? decoder.decode(Entry.self, from: Data($0.utf8)) }
    }

    /// The journal entries for what a step's queue events say.
    public static func entries(for events: [FieldQueue.Event], t: Double, field: String?) -> [Entry] {
        events.map { event in
            var entry = Entry(t: t, kind: .step, field: field)
            switch event {
            case .sent(let op, let lane): entry.kind = .sent; entry.op = Op(op); entry.lane = lane
            case .confirmed(let waited): entry.kind = .confirmed; entry.detail = "\(Int(waited))"
            case .resync(let kind): entry.kind = .resync; entry.reason = kind.rawValue
            case .nudged: entry.kind = .nudged
            case .insertedBehind: entry.kind = .sent; entry.detail = "behind"
            case .applied(let id, let cursor): entry.kind = .applied; entry.id = id; entry.detail = "\(cursor)"
            case .dropped(let drop):
                entry.kind = .dropped; entry.id = drop.id; entry.run = drop.runID; entry.reason = drop.reason.rawValue
                entry.text = drop.text; entry.partial = drop.partial
            case .liveApplied(let run, let version, _): entry.kind = .liveApplied; entry.run = run; entry.version = version
            case .regionStarted(let run, let anchor): entry.kind = .regionStarted; entry.run = run; entry.detail = "\(anchor)"
            case .regionClosed(let run, let cause): entry.kind = .regionClosed; entry.run = run; entry.reason = cause.rawValue
            }
            return entry
        }
    }
}
