import Foundation
import Testing
@testable import LegatoKeyboardCore

/// Recorded on an iPhone (Safari textarea, real cleanup provider, synthetic text, 2026-11-16, `fresh-phone-uat`): a
/// cleanup turned "bread" into "Bread" 219 characters before the caret. The old queue sent one op at a time; Safari's
/// report went back to the state before the delete and the queue reverted onto it, so the "B" never went in ("read").
/// The chunk model sends hop, delete, insert and the hop back together and checks once.
@Suite struct FieldQueueJournalReplayTests {
    static let source = "A👩🏽\u{200D}🚀 B🇩🇪 Today we're preparing the boat for a short trip along the coast. The weather report says the wind will stay gentle until the evening. Please put the blue notebook beside the chart table and check that the cabin lights are working. We will bring fresh water, bread, fruit, warm jackets, a small repair kit, and enough rope for the next harbor. Before we leave, walk around the deck and close every open hatch. Now I am speaking again while the earlier passage is being corrected. C é Z"
    static let target = source.replacingOccurrences(of: "bread", with: "Bread")

    /// The journal's own input against fields that behave like the measured hosts.
    @Test(arguments: [FakeField.Host.safari, .notes, .whatsApp])
    func theBreadCleanupLandsAsOneChunk(host: FakeField.Host) throws {
        let entries = EditJournal.entries(Self.journal)
        let rig = JournalReplay.simulate(entries) { field in
            let caret = field.caret
            field = FakeField.host(host, field.string, caret: caret)
        }
        #expect(rig.field.string == Self.target, "\(rig.queue.debugState)")
        #expect(rig.queue.isIdle)
        let ops = rig.sent.map(\.op)
        // One delete of the one changed letter and one insert, never a zero-offset nudge.
        #expect(ops.filter { if case .deleteBackward = $0 { true } else { false } } == [.deleteBackward(1)])
        #expect(ops.filter { if case .insert = $0 { true } else { false } } == [.insert("B")])
        #expect(!ops.contains(.move(0)))
        // The caret is back where the user left it.
        #expect(rig.field.caret == rig.field.text.count - Array(" C é Z").count)
        #expect(rig.applied.count == 1 && rig.drops.isEmpty)
    }

    // MARK: #299 recheck (2026-11-17, `uat-299-recheck`, synthetic text)

    /// Right after a move the proxy's own view shows nothing on the side the caret moved toward (WhatsApp journal at
    /// 18273.18 s: the hop back of a cleanup chunk landed and reported `after: ""`; Safari textarea and contenteditable
    /// alike). The chunk took that for a seam, reseeded the model from the half window (the text after the caret gone
    /// from it) and garbled what came next: a stray move put the caret into "fi|ve." and the next words went in there.
    /// The hop waits for the report that shows the way instead.
    @Test(arguments: [FakeField.Host.whatsApp, .safari])
    func aHopBackAcrossAShortWindowWaitsForTheReportThatShowsTheWay(host: FakeField.Host) {
        let text = "The review is moved to Wednesday. We meet At the Bahnhof, so um sechs Uhr, and then walk over together. "
            + "Please send the draft to Anna, cc Lina. Actually, no, cc Tom. Um, and bring the printed slides and the budget "
            + "sheet if you can. And, um, I think the room is booked until five."
        let target = text.replacingOccurrences(of: "meet At", with: "meet at")
        var field = FakeField.host(host, text)
        // WhatsApp's windows on the device were 110–175 characters (cut at its own lines): the way back takes hops.
        field.window = 110
        var rig = QueueRig(field)
        rig.queue.enqueue(FieldQueue.Edit(kind: .magic, before: text, target: target, cursorAtEnd: false))
        let drained = rig.drain()
        #expect(drained)
        #expect(rig.field.string == target, "\(rig.queue.debugState)")
        #expect(rig.field.caret == rig.field.text.count, "the caret is back at the end")
        #expect(rig.queue.modelText == target, "the model still holds the whole text")
        let resyncs = rig.events.compactMap { if case .resync(let kind) = $0.event { kind } else { nil } }
        #expect(!resyncs.contains(.reseeded) && !resyncs.contains(.checkFailed), "\(resyncs)")
        #expect(rig.applied.count == 1 && rig.drops.isEmpty)
    }

    /// Safari contenteditable, fragments replay (journal 18835.9–18837.7 s): Soniox revised "whether" to "weather" while
    /// the take ran; in a pause the revision of the open piece was planned with the next words it carried, and speech typed
    /// those same words at the caret. Merging the two typed them twice ("holds. Yeah. Yeah."). The take's snapshots as
    /// recorded, in a pause throughout.
    @Test func aRevisionInAPauseNeverTypesSpeechTwice() {
        func snapshot(_ version: Int, _ last: [(String, Bool)]) -> LiveDictationSnapshot {
            var segments: [LiveSegment] = [.init(id: 0, text: "Um.", final: true), .init(id: 1, text: "so, uh, the plan", final: true),
                                           .init(id: 2, text: "is to repaint the fence on Saturday", final: true)]
            for (i, (text, final)) in last.enumerated() { segments.append(.init(id: 3 + i, text: text, final: final)) }
            return .init(runID: "r", version: version, segments: segments, complete: false)
        }
        let versions = [snapshot(16, [("if", false)]), snapshot(17, [("if the", false)]), snapshot(18, [("if the whether", false)]),
                        snapshot(19, [("if the weather holds.", false)]), snapshot(20, [("if the weather holds.", true)]),
                        snapshot(21, [("if the weather holds.", true), ("Yeah.", false)])]
        var rig = QueueRig(FakeField.host(.safari), config: .init(prioritizeSpeech: true))
        for version in versions {
            rig.queue.enqueue(version)
            rig.queue.setSpeaking(false, runID: "r")
            rig.run(ms: 300)
        }
        rig.run(ms: 1_000)
        #expect(rig.field.string == "Um. so, uh, the plan is to repaint the fence on Saturday if the weather holds. Yeah.", "\(rig.queue.debugState)")
    }

    /// Notes, fragments replay (journal 18563.8–18567.5 s): the user pressed "Q" right after speech ended, while the stop's
    /// cleanup was landing in chunks on the line above. The key waited 3.2 s: a chunk's hop back failed on the half window
    /// and asked for a read across the seam, and the key waited for that walk. The key goes behind the running chunk; the
    /// cleanup lands whole around it.
    @Test(arguments: [false, true])
    func aKeyRightAfterSpeechGoesBehindTheRunningChunk(canReadAround: Bool) {
        let text = "If the weather Holds, we should be done By late afternoon. Then it is coffee and cake on the terrace. "
            + "So the plan is to repaint the fence on Saturday if the weather holds. Yeah.\nAnd I think we need two more cans of paint."
        let target = text.replacingOccurrences(of: "Holds,", with: "holds,").replacingOccurrences(of: "By late", with: "by late")
        var rig = QueueRig(FakeField.host(.notes, text), config: .init(canReadAround: canReadAround))
        rig.queue.enqueue(FieldQueue.Edit(kind: .magic, before: text, target: target, cursorAtEnd: false))
        rig.tick(); rig.tick()
        let pressed = rig.clockMs
        rig.queue.enqueue(.insert("Q"))
        let drained = rig.drain()
        #expect(drained)
        #expect(rig.field.string == target + "Q", "\(rig.queue.debugState)")
        let landed = rig.sent.first { $0.op == .insert("Q") }?.ms
        #expect(landed.map { $0 - pressed < FieldQueue.checkDeadlineMs } == true, "the key waits for the running chunk only")
        #expect(rig.applied.count == 1 && rig.drops.isEmpty)
    }

    static let journal = #"""
{"action":"idle","kind":"step","report":{"after":" C é Z","before":"A👩🏽‍🚀 B🇩🇪 Today we're preparing the boat for a short trip along the coast. The weather report says the wind will stay gentle until the evening. Please put the blue notebook beside the chart table and check that the cabin lights are working. We will bring fresh water, bread, fruit, warm jackets, a small repair kit, and enough rope for the next harbor. Before we leave, walk around the deck and close every open hatch. Now I am speaking again while the earlier passage is being corrected."},"t":503354913.9532084}
{"id":"250DB018-2DD9-413E-8860-18B25434867F","kind":"read","t":503356675.5577917}
{"edit":{"after":" C é Z","atCursor":false,"before":"A👩🏽‍🚀 B🇩🇪 Today we're preparing the boat for a short trip along the coast. The weather report says the wind will stay gentle until the evening. Please put the blue notebook beside the chart table and check that the cabin lights are working. We will bring fresh water, bread, fruit, warm jackets, a small repair kit, and enough rope for the next harbor. Before we leave, walk around the deck and close every open hatch. Now I am speaking again while the earlier passage is being corrected.","cursorAtEnd":false,"id":"3AD140DA-8A92-4F36-AD20-1F68068EDA4A","kind":"magic","paced":true,"readID":"250DB018-2DD9-413E-8860-18B25434867F","target":"A👩🏽‍🚀 B🇩🇪 Today we're preparing the boat for a short trip along the coast. The weather report says the wind will stay gentle until the evening. Please put the blue notebook beside the chart table and check that the cabin lights are working. We will bring fresh water, Bread, fruit, warm jackets, a small repair kit, and enough rope for the next harbor. Before we leave, walk around the deck and close every open hatch. Now I am speaking again while the earlier passage is being corrected. C é Z"},"kind":"edit","t":503356703.054375,"user":false}
{"action":"send","kind":"step","report":{"after":" C é Z","before":"A👩🏽‍🚀 B🇩🇪 Today we're preparing the boat for a short trip along the coast. The weather report says the wind will stay gentle until the evening. Please put the blue notebook beside the chart table and check that the cabin lights are working. We will bring fresh water, bread, fruit, warm jackets, a small repair kit, and enough rope for the next harbor. Before we leave, walk around the deck and close every open hatch. Now I am speaking again while the earlier passage is being corrected."},"t":503356707.2674584}
{"kind":"sent","lane":"edit","op":{"move":-219},"t":503356707.3455834}
{"action":"wait","kind":"step","report":{"after":"read, fruit, warm jackets, a small repair kit, and enough rope for the next harbor. Before we leave, walk around the deck and close every open hatch. Now I am speaking again while the earlier passage is being corrected. C é Z","before":"A👩🏽‍🚀 B🇩🇪 Today we're preparing the boat for a short trip along the coast. The weather report says the wind will stay gentle until the evening. Please put the blue notebook beside the chart table and check that the cabin lights are working. We will bring fresh water, b"},"t":503356709.0836251}
{"action":"send","kind":"step","report":{"after":"read, fruit, warm jackets, a small repair kit, and enough rope for the next harbor. Before we leave, walk around the deck and close every open hatch. Now I am speaking again while the earlier passage is being corrected. C é Z","before":"A👩🏽‍🚀 B🇩🇪 Today we're preparing the boat for a short trip along the coast. The weather report says the wind will stay gentle until the evening. Please put the blue notebook beside the chart table and check that the cabin lights are working. We will bring fresh water, b"},"t":503356759.9948334}
{"kind":"sent","lane":"edit","op":{"delete":1},"t":503356760.271125}
{"action":"wait","kind":"step","report":{"after":"read, fruit, warm jackets, a small repair kit, and enough rope for the next harbor. Before we leave, walk around the deck and close every open hatch. Now I am speaking again while the earlier passage is being corrected. C é Z","before":"A👩🏽‍🚀 B🇩🇪 Today we're preparing the boat for a short trip along the coast. The weather report says the wind will stay gentle until the evening. Please put the blue notebook beside the chart table and check that the cabin lights are working. We will bring fresh water, "},"t":503356762.1300833}
{"action":"wait","kind":"step","report":{"after":" C é Z","before":"A👩🏽‍🚀 B🇩🇪 Today we're preparing the boat for a short trip along the coast. The weather report says the wind will stay gentle until the evening. Please put the blue notebook beside the chart table and check that the cabin lights are working. We will bring fresh water, bread, fruit, warm jackets, a small repair kit, and enough rope for the next harbor. Before we leave, walk around the deck and close every open hatch. Now I am speaking again while the earlier passage is being corrected."},"t":503356784.18837506}
{"action":"send","kind":"step","report":{"after":" C é Z","before":"A👩🏽‍🚀 B🇩🇪 Today we're preparing the boat for a short trip along the coast. The weather report says the wind will stay gentle until the evening. Please put the blue notebook beside the chart table and check that the cabin lights are working. We will bring fresh water, bread, fruit, warm jackets, a small repair kit, and enough rope for the next harbor. Before we leave, walk around the deck and close every open hatch. Now I am speaking again while the earlier passage is being corrected."},"t":503356887.5995834}
{"kind":"sent","lane":"edit","op":{"move":0},"t":503356887.67795837}
{"action":"wait","kind":"step","report":{"after":"read, fruit, warm jackets, a small repair kit, and enough rope for the next harbor. ","before":"cabin lights are working. We will bring fresh water, b"},"t":503356899.23320836}
{"action":"send","kind":"step","report":{"after":"read, fruit, warm jackets, a small repair kit, and enough rope for the next harbor. ","before":"cabin lights are working. We will bring fresh water, b"},"t":503357495.43037504}
{"kind":"sent","lane":"edit","op":{"move":219},"t":503357495.6315834}
{"action":"wait","kind":"step","report":{"after":"","before":"cabin lights are working. We will bring fresh water, bread, fruit, warm jackets, a small repair kit, and enough rope for the next harbor. "},"t":503357497.64520836}
{"action":"wait","kind":"step","report":{"after":"read, fruit, warm jackets, a small repair kit, and enough rope for the next harbor. ","before":"cabin lights are working. We will bring fresh water, "},"t":503357551.9572084}
{"action":"send","kind":"step","report":{"after":" C é Z","before":"Now I am speaking again while the earlier passage is being corrected."},"t":503357578.65825003}
"""#
}
