import Foundation
import Testing
@testable import LegatoKeyboardCore

/// #299 round 4: a cleanup pass starts from the keyboard's shadow (`FieldQueue.shadow`), sent with no field read. The
/// read is marked (`markRead(mergingUser:)`); the pass's result is placed through every change since: it goes in at
/// once when the field still matches, and is merged around a difference (the user's typing, speech) otherwise.
@Suite struct ShadowCleanupTests {
    private func typed(_ take: String, before: String = "") -> QueueRig {
        var rig = QueueRig(FakeField.host(.whatsApp, before))
        rig.run(ms: 100)
        rig.queue.enqueue(snap(1, take))
        rig.drain()
        return rig
    }

    @Test func theShadowIsSentOnceTheSnapshotsWordsAreTyped() {
        var rig = typed("teh review is moved", before: "Hi Anna. ")
        guard case .ready(let before, let after, let takeStart) = rig.queue.shadow(of: "r", version: 1) else {
            Issue.record("no shadow"); return
        }
        #expect(before == "Hi Anna. teh review is moved" && after == "")
        #expect(takeStart == "Hi Anna. ".count, "where the take starts")
        // Words of a newer snapshot still on their way: not yet.
        rig.queue.enqueue(snap(2, "teh review is moved to Tuesday"))
        #expect(rig.queue.shadow(of: "r", version: 2) == .notYet)
        rig.drain()
        if case .ready(let before, _, _) = rig.queue.shadow(of: "r", version: 2) { #expect(before.hasSuffix("to Tuesday")) }
        else { Issue.record("no shadow after the words landed") }
        // A selection the user made: no text to give.
        rig.field.select(0..<2)
        rig.run(ms: 600)
        if case .refused = rig.queue.shadow(of: "r", version: 2) {} else { Issue.record("a selection refuses") }
    }

    @Test func aResultForAFieldThatStillMatchesGoesInAtOnce() {
        var rig = typed("teh review is moved to tuesday.")
        guard case .ready(let before, let after, _) = rig.queue.shadow(of: "r", version: 1) else { Issue.record("no shadow"); return }
        rig.queue.markRead("pass", mergingUser: true)
        rig.queue.enqueue(FieldQueue.Edit(id: "pass", kind: .magic, before: before, after: after,
                                          target: "The review is moved to Tuesday.", cursorAtEnd: false, readID: "pass"))
        rig.drain()
        #expect(rig.field.string == "The review is moved to Tuesday.")
        #expect(rig.applied == ["pass"])
        #expect(rig.drops.filter { $0.id == "pass" }.isEmpty)
    }

    /// The user typed meanwhile (the model was working): the result is merged around their change; its own changes land
    /// in the words the user did not touch. An instruction's read would be cancelled by the same change.
    @Test(arguments: [true, false])
    func aResultIsMergedAroundTheUsersTypingMeanwhile(cleanup: Bool) {
        var rig = typed("teh red boat sails")
        guard case .ready(let before, let after, _) = rig.queue.shadow(of: "r", version: 1) else { Issue.record("no shadow"); return }
        rig.queue.markRead("pass", mergingUser: cleanup)
        // The user changes "red" to "blue".
        rig.queue.enqueue(.move(-11))
        for _ in 0..<3 { rig.queue.enqueue(.deleteBackward) }
        rig.queue.enqueue(.insert("blue"))
        rig.drain()
        #expect(rig.field.string == "teh blue boat sails")
        rig.queue.enqueue(FieldQueue.Edit(id: "pass", kind: .magic, before: before, after: after,
                                          target: "The red boat sails.", cursorAtEnd: false, readID: "pass"))
        rig.drain()
        if cleanup {
            #expect(rig.field.string == "The blue boat sails.")
            #expect(rig.applied == ["pass"])
            #expect(rig.field.caret == rig.field.userCaret)
        } else {
            #expect(rig.field.string == "teh blue boat sails")
            #expect(rig.drops.contains { $0.id == "pass" && $0.reason == .userEdited })
        }
    }

    /// Speech typed while the model worked stays; the result lands in the text it was for.
    @Test func speechTypedMeanwhileStays() {
        var rig = typed("teh review is moved.")
        guard case .ready(let before, let after, _) = rig.queue.shadow(of: "r", version: 1) else { Issue.record("no shadow"); return }
        rig.queue.markRead("pass", mergingUser: true)
        rig.queue.enqueue(snap(2, "teh review is moved. We meet at six"))
        rig.drain()
        rig.queue.enqueue(FieldQueue.Edit(id: "pass", kind: .magic, before: before, after: after,
                                          target: "The review is moved.", cursorAtEnd: false, readID: "pass"))
        rig.drain()
        #expect(rig.field.string == "The review is moved. We meet at six")
        #expect(rig.applied == ["pass"])
    }
}
