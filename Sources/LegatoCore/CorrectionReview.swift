import CryptoKit
import Foundation
import LegatoVocabulary
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
    public let keyboardEvidence: [TermEvidence]
    public let sources: [String]
    public let supportCount: Int
    public let lastSeen: Date
    public let isAutomatic: Bool
    public let approvedSource: String?
    fileprivate let originalTarget: String
    fileprivate var visibleInReview: Bool { supportCount >= 2 || !keyboardEvidence.allSatisfy(\.isRecognition) }
    public var isKeyboardOnly: Bool { !isAutomatic && state == .pending && keyboardEvidence.contains { !$0.isRecognition } }

    /// Match whole words. Punctuation-only edits retain their neighbouring word in the captured example.
    public func matchesTargetPhrase(in text: String) -> Bool {
        CapturedChange.contains(CapturedChange.words(after), in: CapturedChange.words(text))
    }

    public func matchesSourcePhrase(in text: String) -> Bool {
        CapturedChange.contains(CapturedChange.words(before), in: CapturedChange.words(text))
    }
}

public struct CorrectionReviewSnapshot: Sendable {
    public let enabled: Bool
    public let candidates: [CorrectionCandidate]
}

private struct ReviewDecision: Codable, Sendable {
    let state: CorrectionReviewState
    let evidence: Set<UUID>
    var originalTarget: String?
    var spelling: String?
    var approvedSource: String?
}

private struct CapturedChange {
    let kind: CorrectionKind
    let before: String
    let after: String
    let locale: String
    let basis: CorrectionBasis
    let record: CorrectionRecord

    var id: String {
        decisionID([kind.rawValue, locale, before, after])
    }

    /// A pause can settle an unfinished spelling. Join consecutive edits only while the complete
    /// intervening snapshot and the boundaries of the changed span agree. Keep the final real record
    /// as evidence, so removing either link breaks the inferred correction.
    static func extract(from records: [CorrectionRecord]) -> [Self] {
        var changes = [Self]()
        var start = records.startIndex
        while start < records.endIndex {
            let first = records[start]
            var end = start
            while end + 1 < records.endIndex && continues(records[end], with: records[end + 1]) { end += 1 }
            let last = records[end]
            if first.eligibleForLearning != false {
                changes += extract(last, from: first.removed, to: last.replacement)
            }
            start = end + 1
        }
        return changes
    }

    private static func continues(_ earlier: CorrectionRecord, with later: CorrectionRecord) -> Bool {
        earlier.eligibleForLearning != false && later.eligibleForLearning != false
            && earlier.endedAtBoundary != true && earlier.insertedText == later.insertedText
            && earlier.rawText == later.rawText && earlier.afterText == later.beforeText
            && earlier.replacement == later.removed && earlier.contextBefore == later.contextBefore
            && earlier.contextAfter == later.contextAfter
    }

    /// Work only on captured changed spans. Reject long rewrites before the quadratic word alignment.
    private static func extract(_ record: CorrectionRecord, from old: String, to new: String) -> [Self] {
        guard old.utf8.count <= 2048, new.utf8.count <= 2048 else { return [] }
        let blocks = WordAlignment.substitutions(from: old, to: new)
        let substitutions = blocks.compactMap { Self(record, from: $0.rawText, to: $0.targetText) }
        if !substitutions.isEmpty { return substitutions }
        return Self(record, from: old, to: new).map { [$0] } ?? []
    }

    init?(_ record: CorrectionRecord, from source: String, to target: String) {
        var before = source.trimmingCharacters(in: .whitespacesAndNewlines)
        var after = target.trimmingCharacters(in: .whitespacesAndNewlines)
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
                guard after.first?.isUppercase == true || (retained >= 2 && retained * 2 >= max(originalLetters.count, correctedLetters.count)) else { return nil }
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

private func decisionID(_ parts: [String]) -> String {
    let key = parts.map { "\($0.utf8.count):\($0)" }.joined()
    return SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
}

private struct EvidenceGroup {
    var changes: [CapturedChange] = []
    var terms: [TermEvidence] = []

    static func key(target: String, locale: String) -> String {
        decisionID(["term", Locale(identifier: locale).identifier, VocabularyEntry.key(for: target)])
    }

    func candidate(id: String, decisions: [String: ReviewDecision]) -> CorrectionCandidate? {
        let edits = changes.sorted { $0.record.date > $1.record.date }
        let events = terms.sorted { $0.date > $1.date }
        guard let target = edits.first?.after ?? events.first?.term,
              let locale = edits.first?.locale ?? events.first?.localeIdentifier else { return nil }
        let kind = edits.first?.kind ?? .vocabulary
        var seen = Set<String>()
        let records = edits.compactMap { seen.insert($0.record.dictationID.lowercased()).inserted ? $0.record : nil }
        let independentEvents = events.filter { seen.insert(($0.takeID ?? $0.id.uuidString).lowercased()).inserted }
        let supportCount = records.count + independentEvents.count
        let legacySources = Dictionary(grouping: edits, by: \.id)
        let sourceIDs = Set(edits.map(\.record.id) + events.map(\.id))
        // A legacy approval applied only to its spelling pair, with surviving supporting records.
        let legacy = edits.compactMap { change -> (ReviewDecision, String)? in
            guard let decision = decisions[change.id],
                  decision.state == .dismissed || decision.evidence.contains(change.record.id) else { return nil }
            return (decision, change.before)
        }
        let legacyDecision = legacy.first { $0.0.state == .dismissed } ?? legacy.first
        let decision = decisions[id] ?? legacyDecision?.0
        let state: CorrectionReviewState
        if let decision, decision.state == .dismissed || !decision.evidence.isDisjoint(with: sourceIDs) && (supportCount >= 2 || decision.evidence.count == 1) {
            state = decision.state
        } else {
            state = .pending
        }
        let targetSpelling = state == .pending && decision?.state != .pending ? target : decision?.spelling ?? target
        let approvedSource: String?
        if decisions[id] != nil {
            approvedSource = state == .approved ? decision?.approvedSource : nil
        } else if let legacySource = legacyDecision?.1, state == .approved, legacySources.values.contains(where: {
            $0.first?.before == legacySource && Set($0.map(\.record.dictationID)).count >= 2
        }) {
            approvedSource = legacySource
        } else {
            approvedSource = nil
        }
        let before = approvedSource ?? edits.first?.before ?? events.first?.original ?? target
        let hasEdit = edits.contains { $0.basis != .uncertain } || events.contains { !$0.isTyped && !$0.isRecognition && $0.promotionCount != nil }
        let threshold = hasEdit ? 2 : events.compactMap(\.promotionCount).min()
        let qualified = kind == .vocabulary && threshold.map { supportCount >= $0 } == true
        let sources = Set(edits.map(\.before) + events.compactMap(\.original))
        let basis = edits.first?.basis ?? .uncertain
        return CorrectionCandidate(id: id, kind: kind, before: before, after: targetSpelling,
            localeIdentifier: locale, basis: edits.allSatisfy { $0.basis == basis } ? basis : .uncertain,
            records: records, state: state, keyboardEvidence: events, sources: sources.sorted(),
            supportCount: supportCount, lastSeen: max(records.first?.date ?? .distantPast, events.first?.date ?? .distantPast),
            isAutomatic: state == .pending && qualified, approvedSource: approvedSource, originalTarget: target)
    }
}

private struct FileRevision: Equatable, Sendable {
    let inode: ino_t
    let seconds: Int
    let nanoseconds: Int

    init?(_ url: URL) throws {
        var metadata = stat()
        guard stat(url.path, &metadata) == 0 else {
            if errno == ENOENT { return nil }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        inode = metadata.st_ino
        seconds = metadata.st_mtimespec.tv_sec
        nanoseconds = metadata.st_mtimespec.tv_nsec
    }
}

private struct EvidenceRevision: Equatable, Sendable {
    let directory: URL
    let files: [FileRevision?]
}

private struct CachedEvidence: Sendable {
    let revision: EvidenceRevision
    let candidates: [CorrectionCandidate]
}

private struct CachedDecisions: Sendable {
    let directory: URL
    let revision: FileRevision
    let decisions: [String: ReviewDecision]
}

extension CorrectionStore {
    private static let decisionCache = OSAllocatedUnfairLock(initialState: Optional<CachedDecisions>.none)
    private static let cache = OSAllocatedUnfairLock(initialState: Optional<CachedEvidence>.none)
    private nonisolated var reviewDirectory: URL { directory.appendingPathComponent("Review", isDirectory: true) }
    private var enabledURL: URL { reviewDirectory.appendingPathComponent("enabled") }

    public func personalizationEnabled() throws -> Bool {
        guard FileManager.default.fileExists(atPath: enabledURL.path) else { return true }
        return try JSONDecoder().decode(Bool.self, from: Data(contentsOf: enabledURL))
    }

    /// The current uninterrupted personalization window. The existing toggle file is written
    /// atomically on transitions and survives restart. Before the first toggle learning is on.
    public func personalizationEnabledSince() throws -> Date? {
        guard FileManager.default.fileExists(atPath: enabledURL.path) else { return .distantPast }
        guard try personalizationEnabled() else { return nil }
        return try enabledURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }

    public func setPersonalizationEnabled(_ enabled: Bool) throws {
        guard (try? personalizationEnabled()) != enabled else { return }
        try PrivateFiles.createDirectory(reviewDirectory)
        try PrivateFiles.write(JSONEncoder().encode(enabled), to: enabledURL)
    }

    public func setReview(_ state: CorrectionReviewState, for candidate: CorrectionCandidate) throws {
        try writeDecision(state, for: candidate, spelling: candidate.after,
                          approvedSource: state == .approved && candidate.sources.count == 1 ? candidate.sources.first : nil)
    }

    public func editSpelling(_ spelling: String, for candidate: CorrectionCandidate) throws {
        let text = spelling.trimmingCharacters(in: .whitespacesAndNewlines)
        guard candidate.kind == .vocabulary, !text.isEmpty, text.utf8.count <= 256,
              !text.contains(where: \.isNewline) else { throw CocoaError(.fileWriteInvalidFileName) }
        try writeDecision(.approved, for: candidate, spelling: text, approvedSource: nil)
    }

    private func writeDecision(_ state: CorrectionReviewState, for candidate: CorrectionCandidate, spelling: String, approvedSource: String?) throws {
        try PrivateFiles.createDirectory(reviewDirectory)
        let decision = ReviewDecision(state: state, evidence: Set(candidate.records.map(\.id) + candidate.keyboardEvidence.map(\.id)),
                                      originalTarget: candidate.kind == .vocabulary ? candidate.originalTarget : nil, spelling: candidate.kind == .vocabulary ? spelling : nil,
                                      approvedSource: approvedSource)
        try PrivateFiles.write(JSONEncoder().encode(decision), to: reviewDirectory.appendingPathComponent(candidate.id + ".decision"))
    }

    /// Suppression also applies to previously learned (non-manual) entries already on this device.
    public func suppressedSpellings() throws -> Set<String> {
        var spellings = Set<String>()
        for decision in try loadDecisions().values where decision.state == .dismissed {
            if let target = decision.originalTarget { spellings.insert(VocabularyEntry.key(for: target)) }
            if let spelling = decision.spelling { spellings.insert(VocabularyEntry.key(for: spelling)) }
        }
        return spellings
    }

    public func invalidateVocabularyEvidence(takeID: String) throws {
        try PrivateFiles.createDirectory(reviewDirectory)
        let key = decisionID([takeID.lowercased()])
        try PrivateFiles.write(Data(), to: reviewDirectory.appendingPathComponent(key + ".deleted"))
    }

    private func deletedTakeKeys() throws -> Set<String> {
        guard FileManager.default.fileExists(atPath: reviewDirectory.path) else { return [] }
        let files = try FileManager.default.contentsOfDirectory(at: reviewDirectory, includingPropertiesForKeys: nil)
        return Set(files.filter { $0.pathExtension == "deleted" }.map { $0.deletingPathExtension().lastPathComponent })
    }

    public func revisionToken() throws -> String {
        try revision().files.map { file in
            file.map { "\($0.inode)-\($0.seconds)-\($0.nanoseconds)" } ?? "-"
        }.joined(separator: "/")
    }

    public func activeCandidates() throws -> [CorrectionCandidate] {
        guard try personalizationEnabled() else { return [] }
        return try allCandidates().filter { $0.state == .approved || $0.isAutomatic }
    }

    public func approvedCandidates() throws -> [CorrectionCandidate] {
        try activeCandidates().filter { $0.state == .approved }
    }

    public func keyboardCandidates() throws -> [CorrectionCandidate] {
        guard try personalizationEnabled() else { return [] }
        return try allCandidates().filter {
            $0.kind == .vocabulary && $0.state != .dismissed && ($0.state == .approved || $0.isAutomatic || $0.isKeyboardOnly)
        }
    }

    public func reviewSnapshot() throws -> CorrectionReviewSnapshot {
        try CorrectionReviewSnapshot(enabled: personalizationEnabled(), candidates: allCandidates().filter(\.visibleInReview))
    }

    private func revision() throws -> EvidenceRevision {
        try EvidenceRevision(directory: directory, files: [directory, reviewDirectory, termEvidenceDirectory].map { try FileRevision($0) })
    }

    private func allCandidates() throws -> [CorrectionCandidate] {
        let initial = try revision()
        if let hit = Self.cache.withLock({ $0?.revision == initial ? $0?.candidates : nil }) { return hit }
        var groups = [String: EvidenceGroup]()
        var correctedSources = [String: Set<String>]()
        let deleted = try deletedTakeKeys()
        func eligible(_ take: String) -> Bool { deleted.isEmpty || !deleted.contains(decisionID([take.lowercased()])) }
        let byTake = Dictionary(grouping: try recent(limit: .max), by: \.dictationID)
        for (take, observations) in byTake where eligible(take) {
            // Older recorders could save a newline-only host clear as an edit. Retain the preceding spelling.
            let ordinary = observations.filter { !$0.afterText.allSatisfy(\.isWhitespace) }
            let ordered = ordinary.sorted { $0.date == $1.date ? $0.id.uuidString < $1.id.uuidString : $0.date < $1.date }
            guard let latest = ordered.last, latest.afterText != latest.insertedText else { continue }
            let finalWords = CapturedChange.words(latest.afterText)
            for change in CapturedChange.extract(from: ordered) {
                guard change.kind == .style ? latest.afterText.contains(change.after) :
                        CapturedChange.contains(CapturedChange.words(change.after), in: finalWords) else { continue }
                // An undone replacement restoring a word originally inserted by Legato is not new user evidence.
                if change.kind == .vocabulary && change.basis == .uncertain { continue }
                if change.basis == .recognition && !CapturedChange.contains(CapturedChange.words(change.before), in: finalWords) {
                    correctedSources[take.lowercased(), default: []].insert(VocabularyEntry.key(for: change.before))
                }
                let id = change.kind == .style ? change.id : EvidenceGroup.key(target: change.after, locale: change.locale)
                groups[id, default: EvidenceGroup()].changes.append(change)
            }
        }
        for event in try termEvidence() where event.takeID.map(eligible) ?? true {
            if event.isRecognition, let take = event.takeID,
               correctedSources[take.lowercased()]?.contains(VocabularyEntry.key(for: event.term)) == true { continue }
            let id = EvidenceGroup.key(target: event.term, locale: event.localeIdentifier)
            groups[id, default: EvidenceGroup()].terms.append(event)
        }
        let decisions = try loadDecisions()
        let result = groups.compactMap { $0.value.candidate(id: $0.key, decisions: decisions) }
            .sorted { $0.lastSeen == $1.lastSeen ? $0.id < $1.id : $0.lastSeen > $1.lastSeen }
        guard try revision() == initial else { return [] }
        Self.cache.withLock { $0 = CachedEvidence(revision: initial, candidates: result) }
        return result
    }

    private func loadDecisions() throws -> [String: ReviewDecision] {
        guard let revision = try FileRevision(reviewDirectory) else { return [:] }
        if let hit = Self.decisionCache.withLock({ state in
            state?.directory == reviewDirectory && state?.revision == revision ? state?.decisions : nil
        }) { return hit }
        var result = [String: ReviewDecision]()
        for url in try FileManager.default.contentsOfDirectory(at: reviewDirectory, includingPropertiesForKeys: nil)
            where url.pathExtension == "decision" {
            result[url.deletingPathExtension().lastPathComponent] = try JSONDecoder().decode(ReviewDecision.self, from: Data(contentsOf: url))
        }
        if try FileRevision(reviewDirectory) == revision {
            let entry = CachedDecisions(directory: reviewDirectory, revision: revision, decisions: result)
            Self.decisionCache.withLock { $0 = entry }
        }
        return result
    }
}
