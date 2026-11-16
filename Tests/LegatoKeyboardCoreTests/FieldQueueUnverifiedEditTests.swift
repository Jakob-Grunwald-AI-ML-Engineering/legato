import Foundation
import Testing
@testable import LegatoKeyboardCore

/// An edit's insert or delete that a report stopped showing is not thereby lost. Recorded on an iPhone (Safari
/// textarea, real cleanup provider, synthetic text, 2026-11-16): a cleanup turned "bread" into "Bread"; its delete of
/// "b" showed, then the proxy went back to the report from before it and kept it through the stale check's nudge. The
/// delete had landed. The queue went back to the text with "b" and planned the rest one character off, so the "B" never
/// went in and the edit dropped: "read".
@Suite struct FieldQueueUnverifiedEditTests {
    /// The keyboard's configuration on the device.
    static let config = FieldQueue.Config(animated: true, canReadAround: true, prioritizeSpeech: true,
                                          deleteConfirmationMs: FieldQueue.transitMs)
    static let source = "A👩🏽\u{200D}🚀 B🇩🇪 Today we're preparing the boat for a short trip along the coast. The weather report says the wind will stay gentle until the evening. Please put the blue notebook beside the chart table and check that the cabin lights are working. We will bring fresh water, bread, fruit, warm jackets, a small repair kit, and enough rope for the next harbor. Before we leave, walk around the deck and close every open hatch. Now I am speaking again while the earlier passage is being corrected. C é Z"
    static let target = source.replacingOccurrences(of: "bread", with: "Bread")
    /// The field once the delete had landed.
    static let landed = source.replacingOccurrences(of: "bread", with: "read")

    /// The journal up to the caret's way home after the queue gave the delete up.
    private func replayed() throws -> (queue: FieldQueue, request: FieldRecovery.Request) {
        let replay = JournalReplay.run(EditJournal.entries(Self.journal), config: Self.config)
        #expect(replay.events.contains(.resync(.stale)) && replay.events.contains(.resync(.reverted)))
        // The device's ops so far, and no jump on a text nobody verified.
        #expect(replay.sent == [.move(-219), .deleteBackward(1), .move(0), .move(219)])
        #expect(replay.sent == replay.recorded)
        let request = try #require(replay.queue.recoveryRequest, "\(replay.queue.debugState)")
        #expect(replay.events.last == .resync(.recoveryRequested))
        return (replay.queue, request)
    }

    /// The field at `text` with the caret before " C é Z", read whole.
    private func read(_ text: String) -> FieldQueue.Report {
        .init(before: String(text.dropLast(6)), after: String(text.suffix(6)))
    }

    /// Carries the queue's ops out on `text` until it is idle.
    private func finish(_ queue: inout FieldQueue, in text: inout String) -> [ShadowOp] {
        var caret = String(text.dropLast(6)).utf16.count, sent: [ShadowOp] = []
        for _ in 0..<400 {
            let before = String(decoding: Array(text.utf16.prefix(caret)), as: UTF16.self)
            let after = String(decoding: Array(text.utf16.dropFirst(caret)), as: UTF16.self)
            if case .send(let op) = queue.step(report: .init(before: before, after: after), elapsedMs: 33) {
                let result = ShadowEditPlanner.simulate(ops: [op], shadow: text, cursor: caret)
                text = result.text; caret = result.cursor; sent.append(op)
            }
            if queue.isIdle { break }
        }
        return sent
    }

    @Test func aDeleteTheReportStoppedShowingIsVerifiedByAReadAndTheEditGoesOn() throws {
        var (queue, request) = try replayed()
        let scope = try #require(request.targets.first)
        #expect(request.targets.count == 1 && request.needsRead)
        #expect(scope.expected == Self.source && scope.landed == Self.landed)
        _ = queue.drainEvents()

        var field = Self.landed
        queue.completeRecovery(request, report: read(field), restored: true, completeDocument: true)
        #expect(queue.modelText == field, "The model is the field as read")
        #expect(queue.drainEvents().contains(.resync(.recoveryReplanned)))
        let sent = finish(&queue, in: &field)
        #expect(sent == [.move(-219), .insert("B"), .move(219)], "Only what the field still lacks")
        #expect(field == Self.target)
        #expect(queue.modelText == field && queue.isIdle)
        #expect(queue.drainEvents().contains { if case .applied = $0 { true } else { false } })
    }

    @Test func aDeleteTheHostDidLoseIsMadeAgainAfterTheRead() throws {
        var (queue, request) = try replayed()
        var field = Self.source
        queue.completeRecovery(request, report: read(field), restored: true, completeDocument: true)
        #expect(queue.modelText == field)
        let sent = finish(&queue, in: &field)
        #expect(sent == [.move(-219), .deleteBackward(1), .insert("B"), .move(219)])
        #expect(field == Self.target && queue.modelText == field && queue.isIdle)
    }

    @Test func aScopeTheReadShowsNeitherWayDropsTheEditAndTouchesNothing() throws {
        var (queue, request) = try replayed()
        _ = queue.drainEvents()
        // The user changed a word meanwhile: neither text is there.
        var field = Self.landed.replacingOccurrences(of: "fruit", with: "apples")
        queue.completeRecovery(request, report: read(field), restored: true, completeDocument: true)
        #expect(queue.modelText == field, "The model is the field as read")
        let events = queue.drainEvents()
        #expect(events.contains { if case .dropped(let drop) = $0 { drop.reason == .unplaceable } else { false } })
        let kept = field
        #expect(finish(&queue, in: &field).isEmpty)
        #expect(field == kept && queue.isIdle)
    }

    @Test func theUsersKeyGoesBeforeTheReadAndCancelsItsEvidence() throws {
        var (queue, request) = try replayed()
        queue.enqueue(.insert("!"))
        #expect(queue.recoveryRequest == nil)
        // The proxy's window at the caret, as the device showed it there.
        let window = FieldQueue.Report(before: "Now I am speaking again while the earlier passage is being corrected.", after: " C é Z")
        #expect(queue.step(report: window, elapsedMs: 33) == .send(.insert("!")))
        let model = queue.modelText
        queue.completeRecovery(request, report: read(Self.landed), restored: true, completeDocument: true)
        #expect(queue.modelText == model, "A read from before the key never replaces the model")
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
