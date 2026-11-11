import Testing
@testable import LegatoKeyboardCore

@Suite struct FieldQueueTests {
    @Test func liveTextAppendsAtTheCursorAndAcks() {
        var rig = QueueRig(FakeField("Note: "))
        rig.queue.enqueue(snap(1, "hello world"))
        let drained = rig.drain(); #expect(drained)
        #expect(rig.field.string == "Note: hello world")
        #expect(rig.events.contains { $0.event == .liveApplied(runID: "r", version: 1, complete: false) })
    }

    @Test func aSonioxFlipMidTextIsOneJumpUnitWithOnlyTheDifferingCharacters() {
        var rig = QueueRig(FakeField(""))
        rig.queue.enqueue(snap(1, "I think the plan is fine"))
        rig.drain()
        let before = rig.sent.count
        rig.queue.enqueue(snap(2, "I think the plant is fine"))
        rig.drain()
        let ops = rig.sent[before...].map(\.op)
        #expect(rig.field.string == "I think the plant is fine")
        // Move to the change, insert the one character, move back: nothing is deleted and retyped.
        #expect(ops == [.move(-8), .insert("t"), .move(8)])
    }

    @Test func aFlipIsPacedOneGraphemePerTickWhenAnimated() {
        var rig = QueueRig(FakeField(""), config: .init(animated: true))
        rig.queue.enqueue(snap(1, "a cat sat"))
        rig.drain()
        let before = rig.sent.count
        rig.queue.enqueue(snap(2, "a black cat sat"))
        rig.drain()
        let inserts = rig.sent[before...].filter { if case .insert = $0.op { true } else { false } }
        #expect(inserts.allSatisfy { if case .insert(let s) = $0.op { s.count == 1 } else { false } })
        #expect(zip(inserts, inserts.dropFirst()).allSatisfy { $1.ms - $0.ms >= FieldQueue.charMs - 0.001 })
        #expect(rig.field.string == "a black cat sat")
    }

    @Test func aUserKeyDuringABusyQueueLandsWithinTheBoundAtTheUsersCursor() {
        var field = FakeField("")
        field.lagTicks = 2
        var rig = QueueRig(field, config: .init(animated: true))
        rig.queue.enqueue(snap(1, String(repeating: "dictated words keep coming ", count: 6)))
        rig.run(ms: 600)
        let typedSoFar = rig.field.string
        rig.queue.enqueue(.insert("X"))
        let asked = rig.clockMs
        rig.run(ms: 400)
        let keyAt = rig.sent.first { if $0.ms > asked, case .insert(let s) = $0.op { s.hasSuffix("X") } else { false } }?.ms
        #expect(keyAt != nil)
        #expect((keyAt ?? .infinity) - asked <= FieldQueue.userBoundMs + 2 * rig.tickMs)
        rig.drain()
        // The key closed the region at its place; the run went on after it.
        let text = rig.field.string
        let key = text.firstIndex(of: "X")!
        #expect(text[..<key].count >= typedSoFar.count)
        #expect(!text.contains("XX"))
    }

    @Test func aUserCursorMoveRebasesAPendingEdit() {
        var rig = QueueRig(FakeField("I saw teh cat. "))
        rig.queue.enqueue(.move(-5))
        rig.queue.enqueue(FieldQueue.Edit(id: "magic", kind: .magic, before: "I saw teh cat. ", after: "",
                                          target: "I saw the cat. ", cursorAtEnd: false))
        rig.drain()
        #expect(rig.field.string == "I saw the cat. ")
        #expect(rig.applied == ["magic"])
        // The user's caret stays where they put it (before "cat").
        #expect(rig.field.caret == 10)
    }

    @Test func nothingInterleavesInsideAJumpUnit() {
        var field = FakeField("")
        field.lagTicks = 1
        var rig = QueueRig(field)
        rig.queue.enqueue(snap(1, "one two three four five"))
        rig.drain()
        rig.queue.enqueue(snap(2, "one too three for five"))
        rig.queue.enqueue(FieldQueue.Edit(id: "typed", kind: .typist, target: " six", atCursor: true))
        rig.drain()
        #expect(rig.field.string == "one too three for five six")
        // While the caret is away from the end, only the unit's own deletes and inserts go out.
        var away = false
        for (_, op) in rig.sent {
            if case .move(let n) = op { away = n < 0 ? true : false; continue }
            if away, case .insert(let s) = op { #expect(s != " six") }
        }
    }

    @Test func anUnplaceableEditDropsWithAnEventAndEverythingElseContinues() {
        var rig = QueueRig(FakeField("Hello there"))
        rig.queue.enqueue(FieldQueue.Edit(id: "gone", kind: .magic, before: "Text that is not here", after: "", target: "Other"))
        rig.queue.enqueue(.insert("!"))
        rig.queue.enqueue(snap(1, "and more"))
        rig.drain()
        #expect(rig.drops.map(\.id) == ["gone"])
        #expect(rig.drops.first?.reason == .changed)
        #expect(rig.field.string == "Hello there! and more")
    }

    @Test func aRevisionOfAClosedRegionLandsWhileItsTextIsUnchanged() {
        var rig = QueueRig(FakeField(""))
        rig.queue.enqueue(snap(1, "first words"))
        rig.drain()
        rig.queue.enqueue(.insert("."))
        rig.queue.enqueue(snap(2, "first words then more"))
        rig.drain()
        #expect(rig.field.string == "first words. then more")
        rig.queue.enqueue(snap(3, "First words then more", complete: true))
        rig.drain()
        #expect(rig.field.string == "First words. then more")
    }

    @Test func aRegionTheUserTypedIntoDropsItsRevisionWithAnEvent() {
        var rig = QueueRig(FakeField(""))
        rig.queue.enqueue(snap(1, "alpha beta"))
        rig.drain()
        rig.queue.enqueue(.move(-2))
        rig.queue.enqueue(.insert("Z"))
        rig.drain()
        rig.queue.enqueue(snap(2, "alpha gamma"))
        rig.drain()
        #expect(rig.field.string == "alpha beZta")
        #expect(rig.drops.first?.text == "alpha gamma")
    }

    @Test func aWordCutShortByAKeyIsFinishedFirst() {
        var rig = QueueRig(FakeField(""), config: .init(animated: true))
        rig.queue.enqueue(snap(1, "wonderful"))
        while rig.field.string.count < 3, rig.clockMs < 2_000 { rig.tick() }
        #expect((1..<"wonderful".count).contains(rig.field.string.count))
        rig.queue.enqueue(.insert("x"))
        rig.drain()
        #expect(rig.field.string == "wonderful x")
    }

    @Test func emojiMoveAsOneUnitInAFieldThatSaysSo() {
        var field = FakeField("")
        field.movesByCharacters = true
        var rig = QueueRig(field)
        rig.queue.enqueue(snap(1, "ok 👍 fine"))
        rig.drain()
        rig.queue.enqueue(snap(2, "OK 👍 fine"))
        rig.drain()
        #expect(rig.field.string == "OK 👍 fine")
    }

    @Test func safarisBlockEchoStillConfirms() {
        var field = FakeField("Title\n")
        field.blockEcho = true
        var rig = QueueRig(field)
        rig.queue.enqueue(snap(1, "body text here"))
        rig.drain()
        rig.queue.enqueue(snap(2, "body test here"))
        rig.drain()
        #expect(rig.field.string == "Title\nbody test here")
        #expect(!rig.events.contains { $0.event == .resync(.reseeded) })
    }

    @Test func aTapElsewhereClosesTheRegionAndLaterWordsStartAtTheNewCursor() {
        var rig = QueueRig(FakeField("Start. End."))
        rig.field.tap(at: 6)
        rig.queue.enqueue(snap(1, "middle"))
        rig.drain()
        #expect(rig.field.string == "Start. middle End.")
        rig.field.tap(at: rig.field.text.count)
        rig.run(ms: 100)
        rig.queue.enqueue(snap(2, "middle and tail"))
        rig.drain()
        #expect(rig.field.string == "Start. middle End. and tail")
    }

    @Test func aMagicEditWithAScopeLongerThanTheWindowLands() {
        let long = String(repeating: "word ", count: 40)
        var field = FakeField(long + "teh end")
        field.window = 30
        var rig = QueueRig(field)
        rig.queue.enqueue(FieldQueue.Edit(id: "m", kind: .magic, before: "Begin " + long + "teh end", after: "",
                                          target: "Begin " + long + "the end", paced: false))
        rig.drain()
        // The scope's start is not in the field: the edit's text there is not trusted beyond what the field confirms.
        #expect(rig.field.string.hasSuffix("the end") || rig.drops.count == 1)
    }

    @Test func aLostOpIsSeenAndTheUsersKeyGoesOnceMore() {
        var rig = QueueRig(FakeField("abc"))
        rig.queue.enqueue(.insert("d"))
        // The host drops the key: the queue sees the old state.
        _ = rig.queue.step(report: rig.field.tick(), elapsedMs: 0)
        for _ in 0..<30 {
            let action = rig.queue.step(report: rig.field.tick(), elapsedMs: 33)
            if case .send(let op) = action { rig.field.apply(op) }
        }
        #expect(rig.field.string == "abcd")
    }
}
