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
        guard case .ready(let before, let after, let take) = rig.queue.shadow(of: "r", version: 1) else {
            Issue.record("no shadow"); return
        }
        #expect(before == "Hi Anna. teh review is moved" && after == "")
        #expect(take == "Hi Anna. ".count..<before.count, "where the take stands")
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

    /// Device run 4 (Notes): a take dictated into the middle of the user's text. The shadow tells where the take's own
    /// text stands, so a pass edits neither the user's words before it nor the ones after it.
    @Test func theShadowTellsWhereATakeInsideTheUsersTextStands() {
        let before = "Bring the slides and ", after = "the budget sheet if you can. "
        var rig = QueueRig(FakeField.host(.notes, before + after, caret: before.count))
        rig.run(ms: 100)
        rig.queue.enqueue(snap(1, "So the plan is pretty simple."))
        rig.drain()
        guard case .ready(let above, let below, let take) = rig.queue.shadow(of: "r", version: 1), let take else {
            Issue.record("no shadow, or no take in it"); return
        }
        let text = Array(above + below)
        #expect(String(text).hasPrefix(before) && String(text).hasSuffix(after))
        #expect(take.lowerBound == before.count, "the take starts at the caret it began at")
        #expect(take.upperBound <= text.count - after.count, "the user's text after the take is not the take's")
        #expect(String(text[take]).trimmingCharacters(in: .whitespaces) == "So the plan is pretty simple.")
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

    /// Device run 4 (Notes, 2026-11-17): a take dictated in front of the field's own ". " ends "terrace.|. ". The sentence's
    /// cleanup drops one of the two periods; it must be the one after the caret, so the take's end stays in front of the
    /// caret and a key pressed right after speech lands behind "terrace." (it went in before the period: "terracez.").
    @Test func aDoubledPeriodAtTheCaretGoesAfterIt() {
        var rig = QueueRig(FakeField.host(.notes, "We should be done by late afternoon. I think the room is booked.", caret: 35))
        rig.run(ms: 100)
        rig.queue.enqueue(snap(1, "Then it is coffee and cake on the terrace."))
        rig.drain()
        #expect(rig.field.string == "We should be done by late afternoon Then it is coffee and cake on the terrace.. I think the room is booked.")
        guard case .ready(let before, let after, _) = rig.queue.shadow(of: "r", version: 1) else { Issue.record("no shadow"); return }
        rig.queue.markRead("pass", mergingUser: true)
        rig.queue.enqueue(FieldQueue.Edit(id: "pass", kind: .magic, before: before, after: after,
                                          target: "We should be done by late afternoon. Then it is coffee and cake on the terrace. I think the room is booked.",
                                          cursorAtEnd: false, readID: "pass"))
        rig.drain()
        #expect(rig.applied == ["pass"])
        rig.queue.enqueue(.insert("z"))
        rig.drain()
        #expect(rig.field.string == "We should be done by late afternoon. Then it is coffee and cake on the terrace.z I think the room is booked.")
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
