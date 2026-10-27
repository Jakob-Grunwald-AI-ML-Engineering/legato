import Foundation

public struct DictationEntry: Sendable, Equatable, Codable, Identifiable {
    public var id: UUID
    public var date: Date
    public var text: String
    /// The engine's text when post-processing changed it (`text` is then the processed text), else nil.
    public var rawText: String?
    public var localeIdentifier: String
    public var engineID: String
    public var duration: TimeInterval

    public init(
        id: UUID = UUID(), date: Date, text: String, rawText: String? = nil, localeIdentifier: String, engineID: String,
        duration: TimeInterval
    ) {
        self.id = id
        self.date = date
        self.text = text
        self.rawText = rawText
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

/// One JSON object per line, on top of ``JSONLFile`` (which documents the file conventions and the
/// one-instance-per-file rule).
public actor JSONLHistoryStore: HistoryStore {
    public let fileURL: URL
    private let file: JSONLFile<DictationEntry>

    public init(fileURL: URL) {
        self.fileURL = fileURL
        self.file = JSONLFile(fileURL: fileURL)
    }

    public func append(_ entry: DictationEntry) async throws {
        try await file.append(entry)
    }

    public func recent(limit: Int) async throws -> [DictationEntry] {
        guard limit > 0 else { return [] }
        return Array(try await file.elements().suffix(limit).reversed())
    }

    public func delete(id: UUID) async throws {
        try await file.remove { $0.id == id }
    }
}
