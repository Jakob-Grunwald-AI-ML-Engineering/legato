import CryptoKit
import Foundation
import os

public enum CorrectionKind: String, Codable, Sendable { case vocabulary, style }
public enum CorrectionBasis: String, Sendable { case recognition, cleanup, uncertain }
public enum CorrectionReviewState: String, Codable, Sendable { case pending, approved, dismissed }

public struct CorrectionCandidate: Sendable, Identifiable, Equatable {
    public let id: String
    public let kind: CorrectionKind
    public let before: String
    public let after: String
    public let localeIdentifier: String
    public let basis: CorrectionBasis
    /// The newest supporting edit from each independent take, newest first.
    public let records: [CorrectionRecord]
    public let state: CorrectionReviewState

    /// Match whole words. Punctuation-only edits retain their neighbouring word in the captured example.
    public func matchesSourcePhrase(in text: String) -> Bool {
        CapturedChange.contains(CapturedChange.words(before), in: CapturedChange.words(text))
    }
}

public struct CorrectionReviewSnapshot: Sendable {
    public let enabled: Bool
    public let candidates: [CorrectionCandidate]
}

private struct ReviewDecision: Codable {
    let state: CorrectionReviewState
    let evidence: Set<UUID>
}

private struct CapturedChange {
    let kind: CorrectionKind
    let before: String
    let after: String
    let locale: String
    let basis: CorrectionBasis
    let record: CorrectionRecord

    var id: String {
        // Length prefixes keep distinct phrase pairs distinct even when text contains delimiters.
        let parts = [kind.rawValue, locale, before, after].map { "\($0.utf8.count):\($0)" }
        return SHA256.hash(data: Data(parts.joined().utf8)).map { String(format: "%02x", $0) }.joined()
    }

    init?(_ record: CorrectionRecord) {
        var before = record.removed.trimmingCharacters(in: .whitespacesAndNewlines)
        var after = record.replacement.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !before.isEmpty, !after.isEmpty, before != after, before.count <= 120, after.count <= 120 else { return nil }
        let originalWords = Self.words(before), correctedWords = Self.words(after)
        guard !originalWords.isEmpty, !correctedWords.isEmpty,
              max(originalWords.count, correctedWords.count) <= 8 else { return nil }
        if originalWords == correctedWords {
            kind = .style
        } else {
            // Changes of quantity, time and other numeric content do not describe a spelling preference.
            guard !(before + after).contains(where: \.isNumber) else { return nil }
            let sharesWord = !Set(originalWords).isDisjoint(with: correctedWords)
            if sharesWord {
                kind = .style
            } else {
                guard max(originalWords.count, correctedWords.count) <= 3 else { return nil }
                // A repeated but unrelated substitution (today -> tomorrow) may simply be a change of intent.
                // Require some spelling evidence before offering a recognizer term for review.
                let originalLetters = originalWords.joined(), correctedLetters = correctedWords.joined()
                let common = originalLetters.difference(from: correctedLetters)
                let retained = (originalLetters.count + correctedLetters.count - common.count) / 2
                guard retained >= 2, retained * 2 >= max(originalLetters.count, correctedLetters.count) else { return nil }
                kind = .vocabulary
                while let first = before.first, first == after.first, first.isPunctuation {
                    before.removeFirst(); after.removeFirst()
                }
                while let last = before.last, last == after.last, last.isPunctuation {
                    before.removeLast(); after.removeLast()
                }
            }
        }

        // These labels locate a change in the pipeline. Neither a host edit nor a keyboard edit proves intent.
        let raw = Self.words(record.rawText), inserted = Self.words(record.insertedText)
        if originalWords == correctedWords || originalWords.contains(where: correctedWords.contains) {
            basis = .uncertain
        } else if Self.contains(originalWords, in: inserted), Self.contains(correctedWords, in: raw),
                  !Self.contains(originalWords, in: raw) {
            basis = .cleanup
        } else if Self.contains(originalWords, in: inserted), Self.contains(originalWords, in: raw) {
            basis = .recognition
        } else {
            basis = .uncertain
        }
        self.before = before.precomposedStringWithCanonicalMapping
        self.after = after.precomposedStringWithCanonicalMapping
        locale = Locale(identifier: record.localeIdentifier).identifier
        self.record = record
    }

    fileprivate static func words(_ text: String) -> [String] {
        text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }

    fileprivate static func contains(_ phrase: [String], in words: [String]) -> Bool {
        guard !phrase.isEmpty, phrase.count <= words.count else { return false }
        return (0...(words.count - phrase.count)).contains { start in words[start...].starts(with: phrase) }
    }
}

/// Atomic file creation, replacement and removal change the parent directory's modification time.
/// Keep one device-local result per process; creating another CorrectionStore for a request reuses it.
private struct DirectoryRevision: Equatable, Sendable {
    let inode: ino_t
    let seconds: Int
    let nanoseconds: Int

    init(_ directory: URL) throws {
        var metadata = stat()
        guard stat(directory.path, &metadata) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        inode = metadata.st_ino
        seconds = metadata.st_mtimespec.tv_sec
        nanoseconds = metadata.st_mtimespec.tv_nsec
    }
}

private struct ApprovedRevision: Equatable, Sendable {
    let directory: URL
    let records: DirectoryRevision
    let decisions: DirectoryRevision
}

private struct ApprovedResult: Sendable {
    let revision: ApprovedRevision
    let candidates: [CorrectionCandidate]
}

extension CorrectionStore {
    private static let lastApproved = OSAllocatedUnfairLock(initialState: Optional<ApprovedResult>.none)
    private var reviewDirectory: URL { directory.appendingPathComponent("Review", isDirectory: true) }
    private var enabledURL: URL { reviewDirectory.appendingPathComponent("enabled") }

    private func personalizationEnabled() throws -> Bool {
        guard FileManager.default.fileExists(atPath: enabledURL.path) else { return true }
        return try JSONDecoder().decode(Bool.self, from: Data(contentsOf: enabledURL))
    }

    public func setPersonalizationEnabled(_ enabled: Bool) throws {
        try PrivateFiles.createDirectory(reviewDirectory)
        try PrivateFiles.write(JSONEncoder().encode(enabled), to: enabledURL)
    }

    /// One atomically replaced file per decision lets app/extension readers see complete writes and
    /// prevents concurrent changes to different candidates or to the switch from overwriting each other.
    public func setReview(_ state: CorrectionReviewState, for candidate: CorrectionCandidate) throws {
        try PrivateFiles.createDirectory(reviewDirectory)
        let decision = ReviewDecision(state: state, evidence: Set(candidate.records.map(\.id)))
        try PrivateFiles.write(JSONEncoder().encode(decision), to: reviewDirectory.appendingPathComponent(candidate.id + ".decision"))
    }

    public func approvedCandidates() throws -> [CorrectionCandidate] {
        guard try personalizationEnabled(), FileManager.default.fileExists(atPath: reviewDirectory.path) else { return [] }
        let revision = try approvedRevision()
        if let cached = Self.lastApproved.withLock({ $0?.revision == revision ? $0?.candidates : nil }) { return cached }
        let decisions = try loadDecisions().filter { $0.value.state == .approved }
        let result = decisions.isEmpty ? [] : try candidates(decisions: decisions).filter { $0.state == .approved }
        // A concurrent writer invalidates this read. Fail closed for this request and retry on the next one.
        guard try revision == approvedRevision(), try personalizationEnabled() else { return [] }
        Self.lastApproved.withLock { $0 = ApprovedResult(revision: revision, candidates: result) }
        return result
    }

    private func approvedRevision() throws -> ApprovedRevision {
        try ApprovedRevision(directory: directory, records: DirectoryRevision(directory), decisions: DirectoryRevision(reviewDirectory))
    }

    public func reviewSnapshot() throws -> CorrectionReviewSnapshot {
        try CorrectionReviewSnapshot(enabled: personalizationEnabled(), candidates: candidates(decisions: loadDecisions()))
    }

    private func loadDecisions() throws -> [String: ReviewDecision] {
        guard FileManager.default.fileExists(atPath: reviewDirectory.path) else { return [:] }
        let urls = try FileManager.default.contentsOfDirectory(at: reviewDirectory, includingPropertiesForKeys: nil)
        var decisions: [String: ReviewDecision] = [:]
        for url in urls where url.pathExtension == "decision" {
            decisions[url.deletingPathExtension().lastPathComponent] = try JSONDecoder().decode(ReviewDecision.self, from: Data(contentsOf: url))
        }
        return decisions
    }

    private func candidates(decisions: [String: ReviewDecision]) throws -> [CorrectionCandidate] {
        // The review list is independent of the raw observation screen's 200-record display window.
        let groups = Dictionary(grouping: try recent(limit: .max), by: \.dictationID)
        var evidence: [String: [CapturedChange]] = [:]
        for observations in groups.values {
            var seen = Set<String>()
            for record in Self.survivingEdits(observations).reversed() {
                guard let change = CapturedChange(record) else { continue }
                let id = change.id
                if seen.insert(id).inserted { evidence[id, default: []].append(change) }
            }
        }
        return evidence.compactMap { id, changes in
            guard changes.count >= 2 else { return nil }
            let ordered = changes.sorted { $0.record.date > $1.record.date }
            let first = ordered[0]
            let records = ordered.map(\.record)
            var state: CorrectionReviewState = .pending
            if let decision = decisions[id],
               decision.state == .dismissed || !decision.evidence.isDisjoint(with: records.map(\.id)) {
                state = decision.state
            }
            return CorrectionCandidate(id: id, kind: first.kind, before: first.before, after: first.after,
                                       localeIdentifier: first.locale, basis: changes.allSatisfy { $0.basis == first.basis } ? first.basis : .uncertain,
                                       records: records, state: state)
        }.sorted { lhs, rhs in
            let l = lhs.records[0].date, r = rhs.records[0].date
            return l == r ? lhs.id < rhs.id : l > r
        }
    }

    /// Collapse settled undo/redo loops within each take, including an undo of several changes at once.
    private static func survivingEdits(_ observations: [CorrectionRecord]) -> [CorrectionRecord] {
        let chronological = observations.sorted {
            $0.date == $1.date ? $0.id.uuidString < $1.id.uuidString : $0.date < $1.date
        }
        var edits: [CorrectionRecord] = []
        for record in chronological {
            if record.afterText == record.insertedText {
                edits.removeAll()
            } else if let index = edits.lastIndex(where: { $0.beforeText == record.afterText }) {
                edits.removeSubrange(index...)
            } else if let reversed = edits.lastIndex(where: {
                $0.removed == record.replacement && $0.replacement == record.removed
                    && !record.afterText.contains($0.replacement)
            }) {
                // Undoing one word while keeping later changes elsewhere does not restore a previous field snapshot.
                edits.remove(at: reversed)
            } else {
                edits.append(record)
            }
        }
        guard let final = chronological.last?.afterText else { return [] }
        return edits.filter { final.contains($0.replacement) }
    }
}
