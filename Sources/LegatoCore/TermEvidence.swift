import CryptoKit
import Foundation

/// One observation of a spelling. A suggestion only becomes a selection when its edit lands.
public struct TermEvidence: Sendable, Equatable, Identifiable, Codable {
    public enum Origin: String, Sendable, Codable { case typed, selection, recognition }
    public let id: UUID
    public let term: String
    public let original: String?
    public let takeID: String?
    public let date: Date
    public let localeIdentifier: String
    public let origin: Origin
    public let previousWord: String?
    public var promotionCount: Int?
    public var isTyped: Bool { origin == .typed }
    public var isRecognition: Bool { origin == .recognition }

    /// Decisions cite observation IDs. A retried or revised history write must retain the same source identity.
    public static func recognized(takeID: UUID, term: String, date: Date, localeIdentifier: String, promotionCount: Int) -> Self {
        let source = takeID.uuidString + ":" + term.precomposedStringWithCanonicalMapping.lowercased()
        let digest = SHA256.hash(data: Data(source.utf8))
        let id = digest.withUnsafeBytes { UUID(uuid: $0.loadUnaligned(as: uuid_t.self)) }
        return Self(id: id, term: term, takeID: takeID.uuidString, date: date, localeIdentifier: localeIdentifier,
                    origin: .recognition, promotionCount: promotionCount)
    }

    public init(id: UUID = UUID(), term: String, original: String? = nil, takeID: String? = nil, date: Date,
                localeIdentifier: String, origin: Origin, previousWord: String? = nil, promotionCount: Int? = nil) {
        self.id = id
        self.term = term
        self.original = original
        self.takeID = takeID
        self.date = date
        self.localeIdentifier = localeIdentifier
        self.origin = origin
        self.previousWord = previousWord
        self.promotionCount = promotionCount
    }
}

extension CorrectionStore {
    public nonisolated var termEvidenceDirectory: URL { directory.appendingPathComponent("Terms", isDirectory: true) }

    public func termEvidence() throws -> [TermEvidence] {
        guard FileManager.default.fileExists(atPath: termEvidenceDirectory.path) else { return [] }
        let files = try FileManager.default.contentsOfDirectory(at: termEvidenceDirectory, includingPropertiesForKeys: nil)
        let decoder = JSONDecoder()
        return files.filter { $0.pathExtension == "json" }.flatMap { url -> [TermEvidence] in
            guard let data = try? Data(contentsOf: url) else { return [] }
            return (try? decoder.decode([TermEvidence].self, from: data)) ?? []
        }
    }

    /// Each action owns its own atomically replaced file. Retried writes and undo/redo reuse the action ID.
    public func recordTermEvidence(_ observation: TermEvidence) throws {
        try writeTerms([observation], at: termEvidenceDirectory.appendingPathComponent(observation.id.uuidString + ".json"))
    }

    public func deleteTermEvidence(id: UUID) throws {
        try writeTerms([], at: termEvidenceDirectory.appendingPathComponent(id.uuidString + ".json"))
    }

    /// The history owner revises all recognized terms of a take together, including an empty set on delete.
    public func replaceRecognizedEvidence(takeID: String, with observations: [TermEvidence]) throws {
        let digest = SHA256.hash(data: Data(takeID.utf8)).map { String(format: "%02x", $0) }.joined()
        try writeTerms(observations, at: termEvidenceDirectory.appendingPathComponent("take-" + digest + ".json"))
    }

    private func writeTerms(_ observations: [TermEvidence], at url: URL) throws {
        if observations.isEmpty {
            do { try FileManager.default.removeItem(at: url) }
            catch let error as CocoaError where error.code == .fileNoSuchFile {}
        } else {
            try PrivateFiles.createDirectory(termEvidenceDirectory)
            try PrivateFiles.write(JSONEncoder().encode(observations), to: url)
        }
    }
}
