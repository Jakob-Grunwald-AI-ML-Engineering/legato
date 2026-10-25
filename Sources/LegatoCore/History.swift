import Foundation

public struct DictationEntry: Sendable, Equatable, Codable, Identifiable {
    public var id: UUID
    public var date: Date
    public var text: String
    public var localeIdentifier: String
    public var engineID: String
    public var duration: TimeInterval

    public init(id: UUID = UUID(), date: Date, text: String, localeIdentifier: String, engineID: String, duration: TimeInterval) {
        self.id = id
        self.date = date
        self.text = text
        self.localeIdentifier = localeIdentifier
        self.engineID = engineID
        self.duration = duration
    }
}

public protocol HistoryStore: Sendable {
    func append(_ entry: DictationEntry) async throws
    /// Newest first.
    func recent(limit: Int) async throws -> [DictationEntry]
    func delete(id: UUID) async throws
}

/// One JSON object per line. Single writer (the app); extensions only read.
///
/// Share exactly one instance per file: the actor serializes access only within an instance, so a
/// second instance (or process) writing the same file can interleave appends with `delete`'s
/// read-modify-write and lose entries. There is no file locking.
public actor JSONLHistoryStore: HistoryStore {
    public let fileURL: URL

    public init(fileURL: URL) { self.fileURL = fileURL }

    private static let newline = UInt8(ascii: "\n")

    private static func makeEncoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .millisecondsSince1970
        return e
    }

    private static func makeDecoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .millisecondsSince1970
        return d
    }

    public func append(_ entry: DictationEntry) async throws {
        let fm = FileManager.default
        try fm.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fm.fileExists(atPath: fileURL.path) {
            guard fm.createFile(atPath: fileURL.path, contents: nil) else {
                throw CocoaError(.fileWriteUnknown)
            }
        }
        var line = try Self.makeEncoder().encode(entry)
        line.append(Self.newline)

        let handle = try FileHandle(forUpdating: fileURL)
        defer { try? handle.close() }
        let end = try handle.seekToEnd()
        if end > 0 {
            // A crashed writer may have left a partial line; start ours on a fresh line.
            try handle.seek(toOffset: end - 1)
            if try handle.read(upToCount: 1)?.first != Self.newline {
                try handle.seekToEnd()
                try handle.write(contentsOf: Data([Self.newline]))
            }
        }
        try handle.seekToEnd()
        try handle.write(contentsOf: line)
    }

    public func recent(limit: Int) async throws -> [DictationEntry] {
        guard limit > 0 else { return [] }
        let decoder = Self.makeDecoder()
        let entries = try rawLines().compactMap { try? decoder.decode(DictationEntry.self, from: $0) }
        return Array(entries.suffix(limit).reversed())
    }

    public func delete(id: UUID) async throws {
        let decoder = Self.makeDecoder()
        let lines = try rawLines()
        // Corrupt lines are preserved: delete never destroys data it cannot read.
        let kept = lines.filter { (try? decoder.decode(DictationEntry.self, from: $0))?.id != id }
        guard kept.count != lines.count else { return }
        var out = Data()
        for line in kept {
            out.append(line)
            out.append(Self.newline)
        }
        try out.write(to: fileURL, options: .atomic)
    }

    private func rawLines() throws -> [Data] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        let data = try Data(contentsOf: fileURL)
        return data.split(separator: Self.newline, omittingEmptySubsequences: true).map { Data($0) }
    }
}
