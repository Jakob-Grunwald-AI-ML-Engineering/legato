import Foundation

/// Synchronously mutated by its owning Room actor. Every batch commits atomically.
public struct ComposerDocument: Sendable {
    public private(set) var lines: [Line] = []
    public private(set) var revision = 0
    public private(set) var rawTranscript = RawTranscript()
    public private(set) var transactions: [Transaction] = []
    private var history: [HistoryEntry] = []
    private var stamps: [String: Int] = [:]
    public init() {}
    public var snapshot: DocumentSnapshot { .init(revision: revision, lines: lines) }
    public var snapshotPublication: DocumentPublication { .init(event: .snapshot(snapshot)) }
    public func publication(for transaction: Transaction) -> DocumentPublication? {
        guard transactions.contains(transaction) else { return nil }
        return .init(event: .ops(transaction))
    }
    @discardableResult public mutating func appendSegment(words: [Word]) throws -> Transaction {
        let txn = try apply([.insertLines(after: lines.last?.id, lines: [Line(words: words)])], origin: .asr, versions: [:])
        rawTranscript.append(words)
        return txn
    }
    @discardableResult public mutating func apply(_ ops: [DocOp], origin: TransactionOrigin, versions: [String: Int], groupID: String? = nil) throws -> Transaction {
        var draft = self
        let initial = Dictionary(uniqueKeysWithValues: lines.map { ($0.id, $0.version) })
        var touched = Set<String>(), inverse: [DocOp] = [], hunks: [AnimationHunk] = []
        for op in ops {
            let ids = op.touchedIDs
            for id in ids {
                guard draft.lines.contains(where: { $0.id == id }) else { throw DocumentError.unknownLine(id) }
                if let version = initial[id], versions[id] != version { throw DocumentError.versionConflict(id) }
            }
            let before = draft.lines
            let undo = try draft.perform(op, origin: origin, hunks: &hunks)
            if origin == .agent {
                let surviving = draft.lines.flatMap(\.words)
                for word in before.flatMap(\.words) where word.pinned {
                    guard surviving.contains(where: { $0.id == word.id && $0.text == word.text && $0.pinned }) else { throw DocumentError.pinnedWord(word.id) }
                }
            }
            inverse = undo + inverse
            touched.formUnion(ids)
            touched.formUnion(Set(draft.lines.map(\.id)).subtracting(before.map(\.id)))
            try draft.validateIDs()
        }
        // A line is versioned once per transaction, including position and metadata changes.
        for id in touched {
            let next = (stamps[id] ?? -1) + 1
            draft.stamps[id] = next
            if let index = draft.lines.firstIndex(where: { $0.id == id }) { draft.lines[index].version = next }
        }
        draft.revision += 1
        let txn = Transaction(txnId: UUID().uuidString, origin: origin, ops: ops, inverse: inverse, groupID: groupID, revision: draft.revision, hunks: hunks)
        draft.transactions.append(txn)
        draft.history.append(HistoryEntry(transaction: txn, touched: touched, stamps: Dictionary(uniqueKeysWithValues: touched.map { ($0, draft.stamps[$0]!) })))
        self = draft
        return txn
    }
    public func canUndo(transactionID: String) -> Bool {
        guard let entry = history.first(where: { $0.transaction.id == transactionID }) else { return false }
        return entry.touched.allSatisfy { stamps[$0] == entry.stamps[$0] }
    }
    @discardableResult public mutating func undo(transactionID: String) throws -> Transaction {
        guard canUndo(transactionID: transactionID), let entry = history.first(where: { $0.transaction.id == transactionID }) else { throw DocumentError.undoUnavailable }
        let versions = Dictionary(uniqueKeysWithValues: lines.filter { entry.touched.contains($0.id) }.map { ($0.id, $0.version) })
        return try apply(entry.transaction.inverse, origin: .undo, versions: versions, groupID: entry.transaction.groupID)
    }

    private func index(_ id: String) throws -> Int {
        guard let index = lines.firstIndex(where: { $0.id == id }) else { throw DocumentError.unknownLine(id) }; return index
    }
    private func insertionIndex(after: String?) throws -> Int { try after.map { try index($0) + 1 } ?? 0 }
    private mutating func validateIDs() throws {
        var ids = Set<String>()
        for line in lines {
            guard ids.insert(line.id).inserted else { throw DocumentError.duplicateID(line.id) }
            for word in line.words { guard ids.insert(word.id).inserted else { throw DocumentError.duplicateID(word.id) } }
        }
    }
    private mutating func perform(_ op: DocOp, origin: TransactionOrigin, hunks: inout [AnimationHunk]) throws -> [DocOp] {
        switch op {
        case let .insertLines(after, proposed):
            let added = proposed.map { line -> Line in
                guard origin != .asr && origin != .undo else { return line }
                var clean = line
                clean.words = line.words.map { Word(id: $0.id, text: $0.text, language: $0.language, pinned: origin == .user && $0.pinned) }
                return clean
            }
            let start = try insertionIndex(after: after)
            for (offset, line) in added.enumerated() { lines.insert(line, at: start + offset); hunks.append(.lineInserted(line: line, index: start + offset)) }
            return added.isEmpty ? [] : [.deleteLines(ids: added.map(\.id))]
        case let .deleteLines(ids):
            guard !ids.isEmpty, Set(ids).count == ids.count else { throw DocumentError.invalidOperation }
            var inverse: [DocOp] = []
            for id in ids {
                let i = try index(id), old = lines[i], previous = i > 0 ? lines[i - 1].id : nil
                lines.remove(at: i); hunks.append(.lineDeleted(line: old, index: i))
                inverse.insert(.insertLines(after: previous, lines: [old]), at: 0)
            }
            return inverse
        case let .replaceLines(ids, proposed):
            guard !ids.isEmpty, Set(ids).count == ids.count else { throw DocumentError.invalidOperation }
            let indices = try ids.map { try index($0) }
            guard indices == Array(indices[0]..<(indices[0] + indices.count)) else { throw DocumentError.invalidOperation }
            let originals = indices.map { lines[$0] }, start = indices[0]
            let previous = start > 0 ? lines[start - 1].id : nil
            let reconciled = WordDiff.reconcile(old: originals.flatMap(\.words), proposed: proposed.flatMap(\.words), origin: origin)
            var cursor = 0
            let replacements = proposed.map { line -> Line in
                var copy = line; copy.words = Array(reconciled[cursor..<(cursor + line.words.count)]); cursor += line.words.count; return copy
            }
            lines.replaceSubrange(start..<(start + ids.count), with: replacements)
            for (i, line) in originals.enumerated() { hunks.append(.lineDeleted(line: line, index: start + i)) }
            for (i, line) in replacements.enumerated() { hunks.append(.lineInserted(line: line, index: start + i)) }
            if replacements.isEmpty { return [.insertLines(after: previous, lines: originals)] }
            return [.replaceLines(ids: replacements.map(\.id), lines: originals)]
        case let .replaceInLine(id, old, new):
            guard !old.isEmpty else { throw DocumentError.ambiguousText }
            let i = try index(id), original = lines[i]
            let matches = original.text.ranges(of: old)
            guard matches.count == 1, let range = matches.first else { throw DocumentError.ambiguousText }
            let text = original.text.replacingCharacters(in: range, with: new)
            lines[i].words = WordDiff.reconcile(old: original.words, proposed: WordDiff.words(text), origin: origin)
            hunks.append(.wordsReplaced(lineID: id, old: original.words, new: lines[i].words))
            return [.replaceLines(ids: [id], lines: [original])]
        case let .moveLines(ids, after):
            guard !ids.isEmpty, Set(ids).count == ids.count, after.map({ !ids.contains($0) }) ?? true else { throw DocumentError.invalidOperation }
            let oldIndices = try ids.map { try index($0) }
            guard oldIndices == Array(oldIndices[0]..<(oldIndices[0] + ids.count)) else { throw DocumentError.invalidOperation }
            let oldPrevious = oldIndices[0] > 0 ? lines[oldIndices[0] - 1].id : nil
            let moved = oldIndices.map { lines[$0] }
            lines.removeAll { ids.contains($0.id) }
            let start = try insertionIndex(after: after)
            lines.insert(contentsOf: moved, at: start)
            for (offset, line) in moved.enumerated() { hunks.append(.lineMoved(lineID: line.id, from: oldIndices[offset], to: start + offset)) }
            return [.moveLines(ids: ids, after: oldPrevious)]
        case let .setKind(ids, kind):
            var inverse: [DocOp] = []
            for id in ids { let i = try index(id); inverse.append(.setKind(ids: [id], kind: lines[i].kind)); lines[i].kind = kind }
            return inverse
        case let .pinWord(id, wordID, text):
            guard origin == .user else { throw DocumentError.invalidOperation }
            let i = try index(id), original = lines[i]
            guard let j = lines[i].words.firstIndex(where: { $0.id == wordID }) else { throw DocumentError.invalidOperation }
            let pieces = WordDiff.words(text)
            guard !pieces.isEmpty else { throw DocumentError.invalidOperation }
            var replacement = pieces
            replacement[0] = Word(id: wordID, text: pieces[0].text, language: original.words[j].language, pinned: true)
            for k in replacement.indices { replacement[k].pinned = true }
            lines[i].words.replaceSubrange(j...j, with: replacement)
            hunks.append(.wordsReplaced(lineID: id, old: original.words, new: lines[i].words))
            return [.replaceLines(ids: [id], lines: [original])]
        case let .setAlternatives(id, wordID, alternatives):
            let i = try index(id), original = lines[i]
            guard let j = lines[i].words.firstIndex(where: { $0.id == wordID }) else { throw DocumentError.invalidOperation }
            lines[i].words[j].alternatives = alternatives
            return [.replaceLines(ids: [id], lines: [original])]
        }
    }
}

private extension DocOp {
    var touchedIDs: [String] {
        switch self {
        case .insertLines: []
        case let .deleteLines(ids), let .replaceLines(ids, _), let .moveLines(ids, _), let .setKind(ids, _): ids
        case let .replaceInLine(id, _, _), let .pinWord(id, _, _), let .setAlternatives(id, _, _): [id]
        }
    }
}

private extension String {
    func ranges(of text: String) -> [Range<String.Index>] {
        var result: [Range<String.Index>] = [], start = startIndex
        while start < endIndex, let range = range(of: text, range: start..<endIndex) {
            result.append(range); start = index(after: range.lowerBound)
        }
        return result
    }
}
