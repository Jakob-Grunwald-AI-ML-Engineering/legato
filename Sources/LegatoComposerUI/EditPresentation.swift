import Foundation
import LegatoComposerDoc

/// Presentation identity is separate from document identity: replace_lines may mint a new line ID
/// while surviving word IDs still identify the same paragraph. No document/tool state is changed.
struct PresentedParagraph: Identifiable, Equatable {
    var id: String
    var line: Line
    var ordinal: Int
    var animateInsertion = false
}

enum ParagraphPresentation {
    static func reconcile(previous: [PresentedParagraph], lines: [Line], animateInsertions: Bool = false) -> [PresentedParagraph] {
        let exact = Dictionary(uniqueKeysWithValues: previous.enumerated().map { ($0.element.line.id, $0.offset) })
        var matches: [Int: Int] = [:], used = Set<Int>()
        // Reserve every exact match before considering overlaps or positional replacements.
        for (index, line) in lines.enumerated() {
            if let old = exact[line.id] { matches[index] = old; used.insert(old) }
        }
        var wordOwners: [String: Int] = [:]
        for (index, paragraph) in previous.enumerated() where !used.contains(index) {
            for word in paragraph.line.words { wordOwners[word.id] = index }
        }
        for (index, line) in lines.enumerated() where matches[index] == nil {
            var overlaps: [Int: Int] = [:]
            for word in line.words {
                if let owner = wordOwners[word.id], !used.contains(owner) { overlaps[owner, default: 0] += 1 }
            }
            if let best = overlaps.keys.sorted(by: { overlaps[$0] == overlaps[$1] ? $0 < $1 : overlaps[$0]! > overlaps[$1]! }).first {
                matches[index] = best; used.insert(best)
            }
        }
        // A complete same-position rewrite has no surviving words, but should still retain
        // its row rather than vanish and recreate the entire paragraph.
        for index in lines.indices where matches[index] == nil && previous.indices.contains(index) && !used.contains(index) {
            matches[index] = index; used.insert(index)
        }
        return lines.enumerated().map { index, line in
            .init(id: matches[index].map { previous[$0].id } ?? line.id, line: line, ordinal: index + 1,
                  animateInsertion: matches[index].map { previous[$0].animateInsertion } ?? animateInsertions)
        }
    }
}

/// One bounded renderer animation for an atomic document update, never one task/layer per word.
struct WordEditPresentation: Equatable {
    static let maximumAnimatedWords = 32
    static let duration = 0.58
    var ranks: [String: Int] = [:]
    var deletionBoundary: Set<String> = []

    init(old: [Word], new: [Word]) {
        let oldText = Dictionary(uniqueKeysWithValues: old.map { ($0.id, $0.text) })
        for word in new where oldText[word.id] != word.text {
            guard ranks.count < Self.maximumAnimatedWords else { break }
            ranks[word.id] = ranks.count
        }
        let surviving = Set(new.map(\.id))
        if ranks.isEmpty, let removed = old.firstIndex(where: { !surviving.contains($0.id) }) {
            let next = old.dropFirst(removed + 1).first { surviving.contains($0.id) }
            let prior = old.prefix(removed).last { surviving.contains($0.id) }
            if let boundary = next ?? prior { deletionBoundary.insert(boundary.id) }
        }
    }
    var isEmpty: Bool { ranks.isEmpty && deletionBoundary.isEmpty }
    func progress(for id: String, overall: Double) -> Double {
        guard let rank = ranks[id] else { return 1 }
        let delay = min(0.30, Double(rank) * 0.018)
        return min(1, max(0, (overall * Self.duration - delay) / 0.25))
    }
}
