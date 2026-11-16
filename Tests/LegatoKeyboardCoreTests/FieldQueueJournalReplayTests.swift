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
