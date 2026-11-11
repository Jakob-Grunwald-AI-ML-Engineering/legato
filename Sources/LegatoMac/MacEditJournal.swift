import Foundation

/// The Mac field queue's edit journal: what went into the queue, what it read, sent and verified, and what came of it,
/// with full text, one JSON object per line. Debug and internal builds write it to the app's Caches folder
/// (`edit-journal.jsonl`), so a session can be pulled and replayed against `MacFieldQueue`.
public enum MacEditJournal {
    public static let fileName = "edit-journal.jsonl"
    public static let previousFileName = "edit-journal.1.jsonl"
    /// The file starts over (the old one kept as `previousFileName`) past this size.
    public static let rotateBytes = 2_000_000

    public enum Kind: String, Codable, Sendable {
        /// A field became the queue's; the bound element lost focus and the queue bound the focused one (`detail`: same
        /// editor or another field).
        case field, rebound
        /// A live snapshot, an edit or a typed insert entered the queue.
        case live, edit, typed
        /// The user typed or clicked.
        case user
        /// One op went out, and its readback.
        case sent, verified, mismatch
        /// A region was found again elsewhere, or started and closed.
        case relocated, regionStarted, regionClosed
        case applied, dropped, waiting, reset
        /// Keystroke fields: a region's keys were planned; a key was refused by its guards (nothing sent).
        case planned, refused
    }

    public struct Entry: Codable, Sendable, Equatable {
        /// Monotonic milliseconds (system uptime).
        public var t: Double
        public var kind: Kind
        public var field: String?
        public var id: String?
        public var run: String?
        /// The UTF-16 range an op replaced, or a region's range.
        public var location: Int?
        public var length: Int?
        public var text: String?
        /// The field's text as read, around the work.
        public var read: String?
        public var selection: String?
        public var reason: String?
        public var detail: String?

        public init(t: Double = ProcessInfo.processInfo.systemUptime * 1000, kind: Kind, field: String? = nil) {
            self.t = t; self.kind = kind; self.field = field
        }
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
}
