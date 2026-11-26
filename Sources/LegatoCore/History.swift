import Foundation

/// Field confirmation, independent of whether the cleanup provider returned an answer.
public enum CleanupFieldStatus: String, Sendable, Equatable, Codable {
    case cleaned, keptAsTyped, undelivered
    public var label: String {
        switch self {
        case .cleaned: "Cleaned"
        case .keptAsTyped: "Cleanup left text unchanged"
        case .undelivered: "Cleanup unconfirmed · check the field"
        }
    }

    public var notice: String? {
        switch self {
        case .cleaned: nil
        case .keptAsTyped: nil
        case .undelivered: "Cleanup couldn't be confirmed. Check the field and Legato's History."
        }
    }
}

/// One confirmed field-cleanup outcome, shared by History and the keyboard's presentation.
public struct CleanupFieldOutcome: Sendable, Equatable, Codable {
    public var runID: String
    public var revision: Int
    public var status: CleanupFieldStatus
    public var at: Date
    public init(runID: String, revision: Int, status: CleanupFieldStatus, at: Date = Date()) {
        self.runID = runID; self.revision = revision; self.status = status; self.at = at
    }
}

/// A rewrite is saved before its first host mutation, so an uncertain field never loses either version.
public enum InstructionHistoryStatus: String, Sendable, Equatable, Codable {
    case saved, applied, notApplied, uncertain

    public var label: String {
        switch self {
        case .saved: "Rewrite saved · check the field"
        case .applied: "Rewrite applied"
        case .notApplied: "Rewrite not applied"
        case .uncertain: "Rewrite stopped · check the field"
        }
    }
}

public struct DictationEntry: Sendable, Equatable, Codable, Identifiable {
    public var id: UUID
    public var date: Date
    public var text: String
    /// The engine's text when post-processing changed it (`text` is then the processed text), else nil.
    public var rawText: String?
    /// Request cue words that also occurred in recognition. Present only on a finalized take with known request provenance.
    public var recognitionHints: [String]?
    /// A newly recorded draft that may still be discarded. Nil on legacy entries.
    public var provisional: Bool?
    /// When part of the raw take was discarded, only the retained speech may teach.
    public var retainedRecognition: String?
    public var spokenEvidence: String? {
        guard instructionStatus == nil, engineID != "instruction", provisional != true else { return nil }
        return retainedRecognition ?? rawText ?? text
    }
    public var localeIdentifier: String
    public var engineID: String
    public var duration: TimeInterval
    /// Cleanup failed or was rejected, so `text` is the raw text as heard. Nil on older entries and when cleanup
    /// never ran (no key).
    public var cleanupFallback: Bool?
    public var cleanupFieldStatus: CleanupFieldStatus?
    /// Field cleanup compares these snapshots, never the surrounding typed text against raw speech.
    public var cleanupSourceText: String?
    public var cleanupResultText: String?
    /// The accepted cleanup when the host could no longer be safely synchronized.
    public var cleanupRecoveryText: String?
    public var displayText: String { cleanupRecoveryText ?? cleanupResultText ?? text }
    /// For Magic entries, `rawText` is the original and `text` is the generated result, even if application failed.
    public var instructionStatus: InstructionHistoryStatus?

    public init(
        id: UUID = UUID(), date: Date, text: String, rawText: String? = nil, localeIdentifier: String, engineID: String,
        duration: TimeInterval, cleanupFallback: Bool? = nil, instructionStatus: InstructionHistoryStatus? = nil,
        cleanupFieldStatus: CleanupFieldStatus? = nil
    ) {
        self.id = id
        self.date = date
        self.text = text
        self.rawText = rawText
        self.localeIdentifier = localeIdentifier
        self.engineID = engineID
        self.duration = duration
        self.cleanupFallback = cleanupFallback
        self.cleanupFieldStatus = cleanupFieldStatus
        self.instructionStatus = instructionStatus
    }
}

public protocol HistoryStore: Sendable {
    func append(_ entry: DictationEntry) async throws
    /// Update one composition without creating a second visible entry.
    func upsert(_ entry: DictationEntry) async throws
    /// Newest first.
    func recent(limit: Int) async throws -> [DictationEntry]
    func delete(id: UUID) async throws
}

public extension HistoryStore {
    func upsert(_ entry: DictationEntry) async throws {
        try await delete(id: entry.id)
        try await append(entry)
    }
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

    /// Replaces the entry with the same id, keeping the date it was first stored with.
    public func upsert(_ entry: DictationEntry) async throws {
        var entry = entry
        if let stored = try await file.elements().first(where: { $0.id == entry.id }) { entry.date = stored.date }
        try await file.upsert(entry, matching: { $0.id == entry.id })
    }

    /// Newest by entry date; equal dates keep file order, so appended dictations read as before and an
    /// older recovered composition does not jump above newer ones.
    public func recent(limit: Int) async throws -> [DictationEntry] {
        guard limit > 0 else { return [] }
        let ordered = try await file.elements().enumerated().sorted { ($0.element.date, $0.offset) > ($1.element.date, $1.offset) }
        return ordered.prefix(limit).map(\.element)
    }

    public func delete(id: UUID) async throws {
        try await file.remove { $0.id == id }
    }
}
