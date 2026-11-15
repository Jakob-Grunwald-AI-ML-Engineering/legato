import Testing
@testable import LegatoKeyboardCore

@Suite struct ScopedEditHistoryTests {
    @Test func magicAndTypingShareOneUndoOrder() {
        var history = EditHistory()
        history.record(removed: "", inserted: "typed", at: .distantPast)
        let forward = FieldQueue.Edit(kind: .magic, before: "old", target: "new")
        let inverse = FieldQueue.Edit(kind: .undo, before: "new", target: "old")
        history.recordScoped(forward: forward, inverse: inverse)
        guard case .scoped(let edit) = history.undo(contextBefore: "elsewhere") else {
            Issue.record("Magic must be undone through its scoped queue operation"); return
        }
        #expect(edit.before == "new" && edit.target == "old")
        #expect(edit.id != inverse.id)
        #expect(history.entries.count == 1)
        history.revertUndo()
        #expect(history.entries.count == 2)
        #expect(!history.canRedo)
    }

    @Test func magicInverseUsesTheSameLedger() {
        var history = EditHistory()
        let forward = FieldQueue.Edit(kind: .magic, before: "old", target: "new")
        let inverse = FieldQueue.Edit(kind: .undo, before: "new", target: "old")
        history.recordScoped(forward: forward, inverse: inverse)
        history.recordScoped(forward: inverse, inverse: forward)
        #expect(!history.canUndo && history.canRedo)
        guard case .scoped(let edit) = history.redo(contextBefore: "elsewhere") else {
            Issue.record("Magic inverse must leave its original edit available for redo"); return
        }
        #expect(edit.before == "old" && edit.target == "new")
    }
}
