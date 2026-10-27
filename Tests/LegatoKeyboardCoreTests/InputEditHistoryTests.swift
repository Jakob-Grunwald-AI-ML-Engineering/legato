import Foundation
import Testing
@testable import LegatoKeyboardCore

@Suite struct InputEditHistoryTests {
    private let t = Date(timeIntervalSince1970: 5_000)
    private func at(_ s: TimeInterval) -> Date { t.addingTimeInterval(s) }

    private func type(_ h: inout EditHistory, _ text: String, start: TimeInterval = 0, step: TimeInterval = 0.1) {
        var now = start
        for ch in text {
            h.typed(String(ch), at: at(now))
            now += step
        }
    }

    // MARK: typing groups

    @Test func typingAWordIsOneEntryClosedBySpace() {
        var h = EditHistory()
        type(&h, "hello world")
        #expect(h.entries.map(\.inserted) == ["hello ", "world"])
        #expect(h.entries.allSatisfy { $0.removed.isEmpty })
    }

    @Test func punctuationClosesTheGroupToo() {
        var h = EditHistory()
        type(&h, "hi, you")
        #expect(h.entries.map(\.inserted) == ["hi,", " ", "you"])
    }

    @Test func aCursorMoveClosesTheGroup() {
        var h = EditHistory()
        type(&h, "ab")
        h.cursorMoved()
        type(&h, "cd", start: 0.5)
        #expect(h.entries.map(\.inserted) == ["ab", "cd"])
    }

    @Test func idleLongerThanOneAndAHalfSecondsClosesTheGroup() {
        var h = EditHistory()
        h.typed("a", at: at(0))
        h.typed("b", at: at(1.4))
        h.typed("c", at: at(1.4 + 1.6))
        #expect(h.entries.map(\.inserted) == ["ab", "c"])
    }

    @Test func aBackspaceInsideTheOpenGroupShortensIt() {
        var h = EditHistory()
        type(&h, "abc")
        h.deleted("c", at: at(1))
        #expect(h.entries.map(\.inserted) == ["ab"])
        h.deleted("b", at: at(1.1))
        h.deleted("a", at: at(1.2))
        #expect(h.entries.isEmpty)
    }

    @Test func aDeletionOutsideAGroupIsItsOwnEntryThatUndoesByTypingItBack() {
        var h = EditHistory()
        h.deleted("x", at: at(0))
        #expect(h.entries == [EditHistory.Entry(removed: "x", inserted: "", kind: .text)])
        #expect(h.undo(contextBefore: "ab") == .edit(WordEdit(forward: 0, deleteCount: 0, insert: "x")))
    }

    // MARK: undo / redo

    @Test func undoingATypedGroupDeletesItsText() {
        var h = EditHistory()
        type(&h, "world")
        #expect(h.undo(contextBefore: "hello world") == .edit(WordEdit(forward: 0, deleteCount: 5, insert: "")))
        #expect(h.canRedo)
        #expect(!h.canUndo)
    }

    @Test func redoReappliesTheEntry() {
        var h = EditHistory()
        h.record(removed: "wind", inserted: "wand", at: at(0))
        _ = h.undo(contextBefore: "a wand")
        #expect(h.redo(contextBefore: "a wind") == .edit(WordEdit(forward: 0, deleteCount: 4, insert: "wand")))
        #expect(h.canUndo)
        #expect(!h.canRedo)
    }

    @Test func undoOfAReplacementRestoresTheRemovedText() {
        var h = EditHistory()
        h.record(removed: "wind", inserted: "wand", at: at(0))
        #expect(h.undo(contextBefore: "a wand") == .edit(WordEdit(forward: 0, deleteCount: 4, insert: "wind")))
    }

    @Test func aNewEditClearsTheRedoStack() {
        var h = EditHistory()
        h.record(removed: "a", inserted: "b", at: at(0))
        _ = h.undo(contextBefore: "b")
        #expect(h.canRedo)
        h.record(removed: "", inserted: "z", at: at(1))
        #expect(!h.canRedo)
        var g = EditHistory()
        g.record(removed: "a", inserted: "b", at: at(0))
        _ = g.undo(contextBefore: "b")
        g.typed("q", at: at(2))
        #expect(!g.canRedo)
    }

    @Test func undoingAClosesTheOpenTypingGroupSoLaterTypingStartsFresh() {
        var h = EditHistory()
        h.typed("a", at: at(0))
        _ = h.undo(contextBefore: "a")
        h.typed("b", at: at(0.1))
        #expect(h.entries.map(\.inserted) == ["b"])
    }

    // MARK: guard

    @Test func undoRequiresTheContextToEndWithTheInsertedText() {
        var h = EditHistory()
        h.record(removed: "wind", inserted: "wand", at: at(0))
        h.record(removed: "", inserted: "x", at: at(1))
        #expect(h.undo(contextBefore: "something else") == nil)
        #expect(!h.canUndo)
        #expect(!h.canRedo)
        #expect(h.entries.isEmpty)
    }

    @Test func aFailedGuardAlsoClearsTheRedoStack() {
        var h = EditHistory()
        h.record(removed: "a", inserted: "b", at: at(0))
        h.record(removed: "c", inserted: "d", at: at(1))
        _ = h.undo(contextBefore: "d")
        #expect(h.canRedo)
        _ = h.undo(contextBefore: "zzz")
        #expect(!h.canRedo)
    }

    @Test func redoRequiresTheContextToEndWithTheRemovedText() {
        var h = EditHistory()
        h.record(removed: "wind", inserted: "wand", at: at(0))
        _ = h.undo(contextBefore: "a wand")
        #expect(h.redo(contextBefore: "unrelated") == nil)
        #expect(!h.canRedo)
        #expect(!h.canUndo)
    }

    @Test func undoWithNothingToUndoIsNil() {
        var h = EditHistory()
        #expect(h.undo(contextBefore: "x") == nil)
        #expect(h.redo(contextBefore: "x") == nil)
    }

    // MARK: versions

    @Test func aVersionEntryUndoesToItsFromIndexAndRedoesToItsTo() {
        var h = EditHistory()
        h.recordVersion(from: 2, to: 1, at: at(0))
        #expect(h.undo(contextBefore: "whatever the field holds") == .version(2))
        #expect(h.redo(contextBefore: "") == .version(1))
    }

    @Test func repeatedUndoStepsBackThroughVersionsThenTyping() {
        var h = EditHistory()
        type(&h, "hi")
        h.recordVersion(from: 0, to: 1, at: at(1))
        h.recordVersion(from: 1, to: 2, at: at(2))
        #expect(h.undo(contextBefore: "hi Refined") == .version(1))
        #expect(h.undo(contextBefore: "hi Cleaned") == .version(0))
        #expect(h.undo(contextBefore: "hi") == .edit(WordEdit(forward: 0, deleteCount: 2, insert: "")))
    }

    @Test func aVersionEntryClosesTheTypingGroup() {
        var h = EditHistory()
        h.typed("a", at: at(0))
        h.recordVersion(from: 0, to: 1, at: at(0.1))
        h.typed("b", at: at(0.2))
        #expect(h.entries.map(\.inserted) == ["a", "", "b"])
    }

    // MARK: cap and clear

    @Test func theHistoryKeepsAtMostFiftyEntriesDroppingTheOldest() {
        var h = EditHistory()
        for i in 0..<60 { h.record(removed: "", inserted: "\(i)", at: at(Double(i))) }
        #expect(h.entries.count == 50)
        #expect(EditHistory.capacity == 50)
        #expect(h.entries.first?.inserted == "10")
        #expect(h.entries.last?.inserted == "59")
    }

    @Test func clearEmptiesBothStacks() {
        var h = EditHistory()
        h.record(removed: "a", inserted: "b", at: at(0))
        h.record(removed: "c", inserted: "d", at: at(1))
        _ = h.undo(contextBefore: "d")
        h.clear()
        #expect(!h.canUndo)
        #expect(!h.canRedo)
    }
}
