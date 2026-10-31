import LegatoComposerDoc

/// A native Text layout stays small even when one canonical paragraph has thousands of words.
/// These are visual wrapping blocks, never document paragraphs or additional edit transactions.
struct ParagraphRenderBlock: Identifiable {
    var id: String
    var line: Line
    var ordinal: Int
    var continuation: Bool
    var animateInsertion: Bool
    var edit: WordEditPresentation
}

enum ParagraphRenderBlocks {
    static let maximumWords = 96
    static func make(_ paragraphs: [PresentedParagraph], previous: [PresentedParagraph]) -> [ParagraphRenderBlock] {
        let oldWords = Dictionary(uniqueKeysWithValues: previous.map { ($0.id, $0.line.words) })
        return paragraphs.flatMap { paragraph in
            let line = paragraph.line
            let edit = WordEditPresentation(old: oldWords[paragraph.id] ?? [], new: line.words)
            // Empty paragraphs still own one stable layout/scroll anchor.
            return stride(from: 0, to: max(1, line.words.count), by: maximumWords).map { start in
                let words = Array(line.words[start..<min(start + maximumWords, line.words.count)])
                return ParagraphRenderBlock(id: start == 0 ? paragraph.id : "\(paragraph.id)-block-\(start / maximumWords)",
                    line: Line(id: line.id, kind: line.kind, version: line.version, words: words),
                    ordinal: paragraph.ordinal, continuation: start > 0,
                    animateInsertion: paragraph.animateInsertion, edit: edit)
            }
        }
    }
}
