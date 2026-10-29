import Foundation
import LegatoFieldEdit
import Testing
@testable import LegatoKeyboardCore

/// Continuous dictation keeps an ASR write queued behind every one that awaits its read; the cleanup lane must
/// still get its turn between them, or a Live run's edits wait until the speaker pauses.
@MainActor
struct FieldEditCoordinatorFairnessTests {
    let timers = ManualTimers()

    func edit(_ c: FieldEditCoordinator, _ location: Int, _ expect: String, _ text: String, origin: EditOrigin) -> EditTransaction {
        EditTransaction(
            origin: origin, owner: "run", base: c.predicted.version,
            steps: [EditStep(span: Span(location: location, length: expect.utf16.count), text: text, expect: expect)])
    }

    @Test func aCleanupEditRunsBetweenTwoASRWritesWhileTheStreamGoesOn() {
        let document = ManualDocument("teh cat")
        let c = FieldEditCoordinator(document: document, settleTimeout: .milliseconds(250), schedule: timers.schedule)
        var outcomes: [String: [FieldEditCoordinator.Outcome]] = [:]
        c.submit(edit(c, 7, "", " sat", origin: .asr)) { outcomes["chunk1", default: []].append($0) }
        #expect(outcomes["chunk1"] == [.executed])
        // While chunk 1 awaits its read, the agent's fix and the stream's next chunk are both queued.
        c.submit(edit(c, 0, "teh", "the", origin: .agent)) { outcomes["cleanup", default: []].append($0) }
        c.submit(edit(c, 11, "", " down", origin: .asr)) { outcomes["chunk2", default: []].append($0) }
        #expect(outcomes["cleanup"] == nil && outcomes["chunk2"] == nil)

        document.report()  // chunk 1 confirmed
        c.sync()
        #expect(outcomes["chunk1"] == [.executed, .applied])
        #expect(outcomes["cleanup"] == [.executed])  // its turn now, not after the stream stops
        #expect(outcomes["chunk2"] == nil)

        document.report()
        c.sync()
        #expect(outcomes["chunk2"] == [.executed])
        document.report()
        c.sync()
        #expect(document.field.text == "the cat sat down")
        #expect(outcomes["cleanup"] == [.executed, .applied] && outcomes["chunk2"] == [.executed, .applied])
    }

    /// The user lane still comes first: a key queued with both goes before the cleanup edit.
    @Test func theUserLaneStillGoesFirst() {
        let document = ManualDocument("teh cat")
        let c = FieldEditCoordinator(document: document, settleTimeout: .milliseconds(250), schedule: timers.schedule)
        var order: [String] = []
        c.submit(edit(c, 7, "", " sat", origin: .asr)) { if $0 == .executed { order.append("asr") } }
        c.submit(edit(c, 0, "teh", "the", origin: .agent)) { if $0 == .executed { order.append("cleanup") } }
        _ = c.type("!")
        order.append("key")
        document.report()
        c.sync()
        #expect(order.first == "asr")
        #expect(order.firstIndex(of: "key")! < order.firstIndex(of: "cleanup")!)
    }
}
