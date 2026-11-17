import Foundation
import Testing
@testable import LegatoKeyboardCore

@Suite struct KeptTextTests {
    @Test func keepsOneItemAndReplacesIt() {
        let store = KeptTextStore(LinkStore(MemoryLinkStore()))
        store.keep("  first take \n", draftID: "d")
        #expect(store.read()?.text == "first take")
        store.keep("second take", draftID: "d")
        #expect(store.read()?.text == "second take")
        store.keep("   ", draftID: "d")
        #expect(store.read()?.text == "second take")
        store.clear()
        #expect(store.read() == nil)
    }

    /// #299 round 4: the row showed an empty "Kept" chip from an item an older build stored. An item without its draft,
    /// with blank text, or in a format that no longer decodes is never shown, and leaves the store.
    @Test func neverAnEmptyOrStaleItem() {
        let backing = MemoryLinkStore(), link = LinkStore(backing)
        let store = KeptTextStore(link)
        link.write(KeptText(text: "older build, no draft"), forKey: KeptTextStore.key)
        #expect(store.read() == nil)
        #expect(!link.hasValue(forKey: KeptTextStore.key), "the stale item is removed")
        link.write(KeptText(text: "  \n ", draftID: "d"), forKey: KeptTextStore.key)
        #expect(store.read() == nil)
        backing.set(Data(#"{"words":"an older format"}"#.utf8), forKey: KeptTextStore.key)
        #expect(store.read() == nil)
        #expect(!link.hasValue(forKey: KeptTextStore.key))
        #expect(!KeptText(text: "", draftID: "d").isShowable)
        #expect(!KeptText(text: "words").isShowable)
        #expect(KeptText(text: "words", draftID: "d").isShowable)
        store.keep("five.", draftID: "d")
        #expect(store.read()?.text == "five.")
    }

    @Test func previewCutsFromTheHead() {
        let item = KeptText(text: "milk and the eggs on Tuesday.")
        #expect(item.preview(maxCharacters: 100) == "milk and the eggs on Tuesday.")
        let cut = item.preview(maxCharacters: 12)
        #expect(cut.hasPrefix("…") && cut.hasSuffix("Tuesday.") && cut.count == 12)
    }

    // MARK: What a dropped run keeps (#299 device run: a take whose cleaned text stood in the field was kept raw)

    private func reset(_ rig: inout QueueRig) -> FieldQueue.Drop? {
        rig.queue.reset()
        return rig.queue.drainEvents().compactMap { if case .dropped(let d) = $0 { d } else { nil } }.first
    }

    @Test func aTakeWhoseCleanedTextStandsInTheFieldKeepsNothing() {
        var rig = QueueRig(FakeField(""))
        rig.queue.enqueue(snap(1, "Um. so, uh, the plan is to paint the fence.", complete: true))
        rig.drain()
        // The field cleanup's edit cleans the take in place (the run's own text stays raw).
        rig.queue.enqueue(FieldQueue.Edit(kind: .magic, before: "Um. so, uh, the plan is to paint the fence.", target: "The plan is to paint the fence.", cursorAtEnd: false))
        rig.drain()
        #expect(rig.field.string == "The plan is to paint the fence.")
        let drop = reset(&rig)
        #expect(drop?.reason == .reset, "the run's region no longer shows its raw words: it is dropped")
        #expect(drop?.kept == "")
    }

    @Test func aTakeWhoseRawTextStandsInTheFieldKeepsNothingWhenItsCleanupIsDropped() {
        var rig = QueueRig(FakeField(""))
        rig.queue.enqueue(snap(1, "um the boat left early"))
        rig.drain()
        rig.queue.enqueue(.move(-2))
        rig.queue.enqueue(.insert("Z"))
        rig.drain()
        // Its cleaned version comes after the user typed into it: it cannot stand whole, the raw words stand.
        rig.queue.enqueue(LiveDictationSnapshot(runID: "r", version: 2,
            segments: [.init(id: 0, text: "The boat left earlier.", cleaned: true, final: true)], complete: true))
        rig.drain()
        #expect(rig.field.string.contains("earZly"), "the user's word stays; the change touching it drops")
        let drops = rig.drops.filter { $0.runID == "r" }
        #expect(!drops.isEmpty)
        #expect(drops.allSatisfy { $0.kept == "" })
        let later = reset(&rig)
        #expect(later == nil || later?.kept == "")
    }

    @Test func onlyTheWordsNotYetInTheFieldAreKept() {
        var rig = QueueRig(FakeField(""))
        rig.queue.enqueue(snap(1, "alpha beta"))
        rig.drain()
        #expect(rig.field.string == "alpha beta")
        // More words arrive and the field goes away before they are typed.
        rig.queue.enqueue(snap(2, "alpha beta gamma delta"))
        let drop = reset(&rig)
        #expect(drop?.kept == "gamma delta")
        var untyped = QueueRig(FakeField(""))
        untyped.queue.enqueue(snap(1, "nothing typed yet"))
        #expect(reset(&untyped)?.kept == "nothing typed yet")
    }

    // MARK: #299 recheck: kept text offered words in the field, superseded raw words, and outlived its sent draft

    /// A cleanup that removed a whole piece of the take (its raw "Um." before a line break the user typed) superseded it:
    /// it is not missing (Safari textarea offered the corrected-away "cc Lina.").
    @Test func rawWordsACleanupReplacedAreNeverKept() {
        var rig = QueueRig(FakeField(""))
        rig.queue.enqueue(snap(1, "Um."))
        rig.drain()
        rig.queue.enqueue(.insert("\n"))
        rig.drain()
        rig.queue.enqueue(snap(2, "Um. The plan is set."))
        rig.drain()
        #expect(rig.field.string == "Um.\nThe plan is set.")
        rig.queue.enqueue(FieldQueue.Edit(kind: .magic, before: "Um.\nThe plan is set.", target: "The plan is set.", cursorAtEnd: false))
        rig.drain()
        #expect(rig.field.string == "The plan is set.")
        #expect(reset(&rig)?.kept ?? "" == "")
    }

    /// Text the shadow lost track of (a seam: the field changed in a way no op explains) was typed: in doubt, nothing is
    /// kept (WhatsApp offered "…the room is booked until five." while that stood in the field).
    @Test func typedTextBehindASeamIsNotKept() {
        var field = FakeField("")
        field.window = 20
        var rig = QueueRig(field)
        rig.queue.enqueue(snap(1, "I think the room is booked until five."))
        rig.drain()
        // Another keyboard types on: the take leaves the window and the model starts over from what it shows.
        rig.field.typeOutside(" And then a long line nobody dictated.")
        rig.run(ms: 1_000)
        #expect(rig.field.string.hasPrefix("I think the room is booked until five."))
        #expect(reset(&rig)?.kept ?? "" == "")
    }

    /// Words heard but never typed are the only kept text, also next to typed words that a cleanup changed since.
    @Test func wordsNeverTypedAreKeptBesideCleanedOnes() {
        var rig = QueueRig(FakeField(""))
        rig.queue.enqueue(snap(1, "um the boat left"))
        rig.drain()
        rig.queue.enqueue(FieldQueue.Edit(kind: .magic, before: "um the boat left", target: "The boat left", cursorAtEnd: false))
        rig.drain()
        rig.queue.enqueue(snap(2, "um the boat left early today"))
        #expect(reset(&rig)?.kept == "early today")
    }

    /// The item belongs to its draft: sending or clearing that draft ends it; another draft's end does not.
    @Test func sendingTheDraftEndsWhatWasKeptFromIt() {
        let store = KeptTextStore(LinkStore(MemoryLinkStore()))
        store.keep("five.", draftID: "a")
        #expect(!store.draftEnded("b"))
        #expect(store.read()?.text == "five.")
        #expect(store.draftEnded("a"))
        #expect(store.read() == nil)
    }
}
