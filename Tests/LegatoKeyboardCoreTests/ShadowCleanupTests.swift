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

    @Test func pendingTypedAndDictatedTextIsVisibleBeforeHostDelivery() {
        var rig = typed("the boat sails")
        rig.queue.enqueue(snap(2, "the boat sails tonight"))
        #expect(rig.queue.projectedBefore == "the boat sails tonight")
        #expect(rig.field.string == "the boat sails")
        rig.drain()
        rig.queue.enqueue(.insert("."))
        #expect(rig.queue.projectedBefore == "the boat sails tonight.")
        #expect(rig.field.string == "the boat sails tonight")
        rig.drain()
        #expect(rig.field.string == "the boat sails tonight.")
    }

    @Test func aPartialHostMutationSynchronizesTheCommittedTarget() {
        var field = FakeField("Please move the review to Thuursday.")
        var queue = FieldQueue()
        let original = field.string
        let target = "Please move the review to Friday."
        _ = queue.step(report: field.tick(), elapsedMs: 50)
        queue.markRead("pass", mergingUser: true)
        queue.enqueue(.init(id: "pass", kind: .magic, before: original, target: target, cursorAtEnd: false, readID: "pass"))

        var droppedPartOfDelete = false
        var events: [FieldQueue.Event] = []
        for _ in 0..<200 {
            let action = queue.step(report: field.tick(), elapsedMs: 50)
            events += queue.drainEvents()
            if case .send(let op) = action {
                if case .deleteBackward(let count) = op, count > 1, !droppedPartOfDelete {
                    field.apply(.deleteBackward(1))
                    droppedPartOfDelete = true
                    #expect(queue.projectedBefore == target)
                } else {
                    field.apply(op)
                }
                queue.operationDispatched()
            } else if queue.isIdle { break }
        }

        #expect(droppedPartOfDelete)
        #expect(events.contains(.resync(.recoveryReplanned)))
        #expect(events.contains { if case .applied("pass", _) = $0 { true } else { false } })
        #expect(field.string == target)
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

    /// Device run 5 (Notes, `dictation-replay-neutral.json`): the recognizer heard "move too", "move too big", then revised
    /// it to "move two big pots" while the take went on. The revision was held for a pause the route had not reported
    /// yet, the sentence pass was answered from the shadow with "too big pots", and the model made it "the too-big pots".
    /// A pass waits for the revision: the field and the pass's text both say "two big pots". At the sentence end
    /// (nothing heard after it), and with the next sentence already being spoken.
    @Test(arguments: [false, true])
    func aPassIsNeverBuiltOnRevisedWords(speechGoesOn: Bool) {
        let first = "So the plan for the garden this weekend is pretty simple."
        func live(_ version: Int, _ head: String, closed: String? = nil, ask: String? = nil) -> LiveDictationSnapshot {
            var segments = [LiveSegment(id: 0, text: first, final: true)]
            if let closed { segments.append(.init(id: 1, text: closed, final: true)) }
            if !head.isEmpty { segments.append(.init(id: segments.count, text: head, final: false)) }
            return .init(runID: "r", version: version, segments: segments, shadowAsk: ask)
        }
        var rig = QueueRig(FakeField.host(.notes), config: .init(prioritizeSpeech: true))
        rig.run(ms: 100)
        // The route reports speech throughout: its pause comes later than the pass's ask.
        rig.queue.enqueue(live(1, "First we need to move too")); rig.drain()
        rig.queue.enqueue(live(2, "First we need to move too big")); rig.drain()
        rig.queue.enqueue(live(3, "First we need to move two big pots")); rig.drain()
        let sentence = "First we need to move two big pots away from the fence, and then we can finally fix the broken gate."
        rig.queue.enqueue(live(4, sentence)); rig.drain()
        let next = speechGoesOn ? "I think" : ""
        rig.queue.enqueue(live(5, next, closed: sentence)); rig.drain()
        rig.queue.enqueue(live(6, next, closed: sentence, ask: "pass"))
        var answer = rig.queue.shadow(of: "r", version: 6)
        for _ in 0..<200 where answer == .notYet { rig.tick(); answer = rig.queue.shadow(of: "r", version: 6) }
        guard case .ready(let before, let after, _) = answer else { Issue.record("no shadow: \(answer)"); return }
        #expect(before.contains("move two big pots away"), "the pass's text: \(before)")
        #expect(rig.field.string.contains("move two big pots away"), "the field: \(rig.field.string)")
        rig.queue.markRead("pass", mergingUser: true)
        // The sentence pass: the model's tidy-up of the text it was sent.
        rig.queue.enqueue(FieldQueue.Edit(id: "pass", kind: .magic, before: before, after: after,
                                          target: before.replacingOccurrences(of: "fence, and", with: "fence and"),
                                          cursorAtEnd: false, readID: "pass"))
        rig.queue.setSpeaking(false, runID: "r")
        rig.drain()
        #expect(rig.applied == ["pass"])
        #expect(rig.field.string.contains("First we need to move two big pots away from the fence and then"), "the field: \(rig.field.string)")
        #expect(!rig.field.string.contains("too"))
    }

    /// A piece revised at one pass's ask grows, then is revised again at the next: the words typed in between are the
    /// keyboard's own, so the second revision lands too (it read them as the user's and kept "old").
    @Test func aPieceRevisedOnceIsRevisedAgainAfterItGrew() {
        var rig = QueueRig(FakeField.host(.notes), config: .init(prioritizeSpeech: true))
        rig.run(ms: 100)
        func live(_ version: Int, _ text: String, ask: String? = nil) -> LiveDictationSnapshot {
            .init(runID: "r", version: version, segments: [.init(id: 0, text: text, final: false)], shadowAsk: ask)
        }
        rig.queue.enqueue(live(1, "the cat waits")); rig.drain()
        rig.queue.enqueue(live(2, "the dog waits by", ask: "a")); rig.drain()
        if case .ready(let before, _, _) = rig.queue.shadow(of: "r", version: 2) { #expect(before == "the dog waits by") }
        else { Issue.record("no shadow for the first pass") }
        rig.queue.enqueue(live(3, "the dog waits by the old boat")); rig.drain()
        rig.queue.enqueue(live(4, "the dog waits by the gold boat", ask: "b")); rig.drain()
        if case .ready(let before, _, _) = rig.queue.shadow(of: "r", version: 4) { #expect(before == "the dog waits by the gold boat") }
        else { Issue.record("no shadow for the second pass") }
        #expect(rig.field.string == "the dog waits by the gold boat")
    }

    /// A take dictated after a line in Notes, cleaned from the shadow the way `FieldCleanupSession` makes a pass.
    private struct TakeRig {
        var rig: QueueRig
        let line: String
        var version = 0

        init(after line: String) {
            self.line = line
            rig = QueueRig(FakeField.host(.notes, line, caret: line.count))
            rig.run(ms: 100)
        }

        mutating func say(_ segments: [String], ask: String) {
            version += 1
            rig.queue.enqueue(.init(runID: "r", version: version,
                                    segments: segments.enumerated().map { .init(id: $0.offset, text: $0.element, final: true) },
                                    shadowAsk: ask))
            rig.drain()
        }

        /// One pass: the take's text goes to the model, which answers `cleaned` whatever part of the take it was sent.
        /// Returns the take's text as sent.
        @discardableResult mutating func pass(_ id: String, cleaned: String) -> String {
            var answer = rig.queue.shadow(of: "r", version: version)
            for _ in 0..<200 where answer == .notYet { rig.tick(); answer = rig.queue.shadow(of: "r", version: version) }
            guard case .ready(let before, let after, let take?) = answer else { Issue.record("no shadow: \(answer)"); return "" }
            let text = Array(before + after)
            #expect(line.hasSuffix(String(text[..<take.lowerBound])), "pass \(id): the take starts after the line")
            rig.queue.markRead(id, mergingUser: true)
            let target = String(text[..<take.lowerBound]) + cleaned + String(text[take.upperBound...])
            rig.queue.enqueue(FieldQueue.Edit(id: id, kind: .magic, before: before, after: after, target: target,
                                              cursorAtEnd: false, readID: id))
            rig.drain()
            #expect(rig.applied.last == id)
            return String(text[take])
        }
    }

    /// Device run 6 (Notes, `dictation-replay-fragments.json`): the first sentence pass made "Um. so, uh, the plan" "So the
    /// plan", deleting the take's opening and typing "S" where it began. The take's start then stood after that "S": the
    /// next pass and the stop's sent "o the plan …", the model answered "So the plan …", and each put another "S" in front
    /// ("SSSo the plan"). What a pass wrote at the take's start is the take's: every later pass starts in front of it, and
    /// a cleanup applied once is not applied again.
    @Test func aPassAtTheTakesStartIsNeverAppliedTwice() {
        let line = "Then it is coffee and cake on the terrace.\n"
        var take = TakeRig(after: line)
        let first = ["Um.", "so, uh, the plan", "is to repaint the fence on Saturday", "if the weather holds."]
        let cleanFirst = "So the plan is to repaint the fence on Saturday if the weather holds."
        let all = first + ["Yeah.", "And, um, I think", "we need two more cans of paint."]
        let cleanAll = cleanFirst + " Yeah. And I think we need two more cans of paint."
        take.say(first, ask: "sentence")
        #expect(take.pass("sentence", cleaned: cleanFirst).hasPrefix("Um. so"))
        #expect(take.rig.field.string == line + cleanFirst)
        take.say(all, ask: "later")
        #expect(take.pass("later", cleaned: cleanAll).hasPrefix("So the plan"))
        #expect(take.rig.field.string == line + cleanAll)
        take.say(all + ["Um."], ask: "stop")
        #expect(take.pass("stop", cleaned: cleanAll).hasPrefix("So the plan"))
        #expect(take.rig.field.string == line + cleanAll)
    }

    /// A pass that only adds text at the take's edge (the period after its last word, a word in front of its first) adds
    /// the take's text: a later pass and the stop's send it with the take and get the same sentence back, so they change
    /// nothing ("paint..", "So, So, the plan" before).
    @Test(arguments: [
        ("we need two more cans of paint", "We need two more cans of paint."),
        ("the plan is to repaint the fence.", "So, the plan is to repaint the fence."),
    ])
    func aPassThatOnlyAddsAtTheTakesEdgeIsNeverAppliedTwice(said: String, cleaned: String) {
        let line = "Then it is coffee and cake on the terrace.\n"
        var take = TakeRig(after: line)
        take.say([said], ask: "sentence")
        #expect(take.pass("sentence", cleaned: cleaned) == said)
        #expect(take.rig.field.string == line + cleaned)
        take.say([said], ask: "later")
        #expect(take.pass("later", cleaned: cleaned) == cleaned, "the pass sends what the first one made")
        take.say([said], ask: "stop")
        #expect(take.pass("stop", cleaned: cleaned) == cleaned)
        #expect(take.rig.field.string == line + cleaned)
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
