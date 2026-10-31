import Foundation
import Testing
@testable import LegatoComposerDoc

struct LargeRewriteTests {
    @Test func largeReorderPreservesExactLCSAndCompleteWordRecords() {
        let old = (0..<5_000).map { Word(id: "w\($0)", text: "token\($0)", confidence: 0.8, alternatives: ["alt\($0)"]) }
        let proposed = old.reversed().map { Word(text: $0.text) }
        let result = WordDiff.reconcile(old: old, proposed: proposed, origin: .agent)
        #expect(result.map(\.text) == proposed.map(\.text))
        let oldIDs = Set(old.map(\.id))
        let surviving = result.filter { oldIDs.contains($0.id) }
        // Reversing unique words has an LCS of exactly one, whichever valid tie is chosen.
        #expect(surviving.count == 1)
        #expect(surviving.first.map { word in old.contains(word) } == true)
        #expect(result.filter { !oldIDs.contains($0.id) }.allSatisfy { $0.confidence == nil && $0.alternatives == nil })
    }

    @Test func largeParagraphEditKeepsPinsAndUndoRestoresEveryRecord() throws {
        var doc = ComposerDocument()
        let words = (0..<5_000).map { Word(id: "w\($0)", text: "token\($0)", confidence: 0.7, pinned: $0 == 3_000) }
        try doc.appendSegment(words: words)
        let line = doc.lines[0]
        let txn = try doc.apply([.replaceInLine(lineID: line.id, old: "token2500", new: "corrected")], origin: .agent, versions: [line.id: line.version])
        #expect(doc.lines[0].words[3_000] == words[3_000])
        #expect(doc.lines[0].words[4_999] == words[4_999])
        #expect(doc.lines[0].words[2_500].text == "corrected")
        try doc.undo(transactionID: txn.id)
        #expect(doc.lines[0].words == words)
    }

    @Test func repeatedWordsKeepOriginalSmallEditTieBreaking() {
        let first = Word(id: "first", text: "same", confidence: 0.8)
        let last = Word(id: "last", text: "same", pinned: true)
        let result = WordDiff.reconcile(old: [first, last], proposed: [Word(text: "new"), Word(text: "same")], origin: .agent)
        #expect(result[1] == last)
    }
}
