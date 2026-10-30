import Testing
import LegatoComposerDoc
@testable import LegatoKeyboardCore

struct ComposerLinkTests {
    @Test func cumulativePublicationAndGapSnapshot() {
        var host = ComposerLinkHistory()
        let a = DocumentSnapshot(revision: 1, lines: [Line(id: "L1", words: [Word(text: "Hello")])])
        let b = DocumentSnapshot(revision: 2, lines: [Line(id: "L1", words: [Word(text: "Hello world")])])
        host.record(a, hunks: [.lineInserted(line: a.lines[0], index: 0)])
        host.record(b, hunks: [.wordsReplaced(lineID: "L1", old: a.lines[0].words, new: b.lines[0].words)])
        #expect(host.publication(acknowledged: 0).hunks.count == 2)
        #expect(host.publication(acknowledged: 1).hunks.count == 1)
        #expect(host.publication(acknowledged: -1).requiresSnapshot)
        #expect(host.publication(acknowledged: 2).snapshot == b)
    }
    @Test func intentsHaveIndependentInboxKeys() {
        let store = LinkStore(MemoryLinkStore())
        let link = ComposerLink(store: store)
        link.send(.init(action: "undo")); link.send(.init(action: "cancel"))
        #expect(link.drainIntents().count == 2)
        #expect(link.drainIntents().isEmpty)
    }
}
