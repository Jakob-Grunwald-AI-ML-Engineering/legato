import Foundation
import Testing
@testable import LegatoKeyboardCore

/// #300 on the queue: a chunk's insert enters as a burst but stays one chunk with one check, and a key waits only for the
/// burst to end.
@Suite struct ChunkEntranceQueueTests {
    private var config: FieldQueue.Config { .init(prioritizeSpeech: false, chunkEntrance: true) }

    private func rig(_ text: String = "", host: FakeField.Host = .whatsApp) -> QueueRig {
        var rig = QueueRig(FakeField.host(host, text), config: config)
        rig.tickMs = 4 // the keyboard's own ticker is 5 ms
        rig.run(ms: 100)
        return rig
    }

    private func confirmations(_ rig: QueueRig) -> Int { rig.events.filter { if case .confirmed = $0.event { true } else { false } }.count }
    private func inserts(_ rig: QueueRig, from start: Int = 0) -> [(ms: Double, text: String)] {
        rig.sent.dropFirst(start).compactMap { if case .insert(let s) = $0.op { ($0.ms, s) } else { nil } }
    }

    @Test func speechEntersGraphemeByGraphemeWithinTheCap() {
        var rig = rig()
        rig.queue.enqueue(snap(1, "hello brave new world"))
        rig.drain()
        let pieces = inserts(rig)
        #expect(pieces.map(\.text).joined() == "hello brave new world" && rig.field.string == "hello brave new world")
        #expect(pieces.count > 10, "one grapheme per piece: \(pieces.count)")
        let burst = pieces.last!.ms - pieces.first!.ms
        #expect(burst >= Double(pieces.count - 1) * ChunkEntrance.gapMs - 1e-9 && burst <= ChunkEntrance.capMs + rig.tickMs, "\(burst)")
        #expect(rig.queue.modelText == rig.field.string)
    }

    @Test func aWholeBurstIsOneChunkWithOneCheck() {
        var rig = rig()
        rig.queue.enqueue(snap(1, "hello brave new world"))
        rig.drain()
        #expect(confirmations(rig) == 1, "one check for the whole burst, not one per piece")
        #expect(!rig.events.contains { if case .resync = $0.event { true } else { false } })
    }

    @Test func aRevisionChunkEntersAsABurstAndIsCheckedOnceAfterItsLastPiece() {
        var rig = rig("alpha bravo charlie delta echo foxtrot golf hotel")
        rig.queue.enqueue(FieldQueue.Edit(kind: .magic, before: rig.field.string, target: "alpha BRAVO XYLOPHONE delta echo foxtrot golf hotel",
                                          cursorAtEnd: false))
        let start = rig.sent.count, confirmed = confirmations(rig)
        rig.drain()
        let pieces = inserts(rig, from: start)
        #expect(pieces.count > 3 && pieces.map(\.text).joined().contains("XYLOPHONE"), "\(pieces.map(\.text))")
        #expect(rig.field.string == "alpha BRAVO XYLOPHONE delta echo foxtrot golf hotel")
        #expect(confirmations(rig) - confirmed == 1, "the chunk's one check")
        #expect(rig.applied.count == 1 && rig.drops.isEmpty)
    }

    /// How long after the chunk's last insert a user's key typed during the chunk goes out (the plain chunk's own check wait
    /// is the same with or without the entrance); `askAfter` pieces in (the whole insert when the entrance is off).
    private func keyDelay(entrance: Bool) -> (afterLastPiece: Double, sinceAsked: Double, burstLeft: Double) {
        var rig = rig()
        rig.queue.config.chunkEntrance = entrance
        rig.queue.enqueue(snap(1, String(repeating: "word ", count: 12) + "end"))
        while inserts(rig).count < (entrance ? 6 : 1) { rig.tick() }
        let asked = rig.clockMs, first = inserts(rig).first!.ms
        rig.queue.enqueue(.insert("!"))
        rig.drain()
        let all = inserts(rig), key = all.first { $0.text == "!" }!
        let own = all.filter { $0.text != "!" }
        #expect(own.map(\.text).joined() == String(repeating: "word ", count: 12) + "end")
        #expect(key.ms >= own.last!.ms, "the key goes after the chunk's last piece")
        #expect(rig.field.string.hasSuffix("end!") && rig.queue.modelText == rig.field.string)
        return (key.ms - own.last!.ms, key.ms - asked, own.last!.ms - first)
    }

    @Test func aKeyDuringABurstWaitsOnlyForTheBurst() {
        let whole = keyDelay(entrance: false), burst = keyDelay(entrance: true)
        // A key queued during the burst lands the rest of it as one write (#313), so the burst never outlasts the cap.
        #expect(burst.burstLeft <= ChunkEntrance.capMs + 8, "the burst ran \(burst.burstLeft) ms")
        // After the burst the key goes as it would after a whole insert: no extra wait from the entrance.
        #expect(burst.afterLastPiece <= whole.afterLastPiece + 2 * 4, "after the burst \(burst.afterLastPiece) ms, whole \(whole.afterLastPiece) ms")
        #expect(burst.sinceAsked <= ChunkEntrance.capMs + whole.afterLastPiece + 2 * 4, "waited \(burst.sinceAsked) ms")
    }

    @Test func aFlushAndReduceMotionWriteWhole() {
        var rig = rig()
        rig.queue.config.chunkEntrance = false
        rig.queue.enqueue(snap(1, "hello brave new world"))
        rig.drain()
        #expect(inserts(rig).map(\.text) == ["hello brave new world"])
        // A finished take's rest is a flush.
        var flush = self.rig()
        flush.queue.enqueue(snap(1, "hello brave new world", complete: true))
        flush.drain()
        #expect(inserts(flush).map(\.text).joined() == "hello brave new world" && flush.field.string == "hello brave new world")
        #expect(inserts(flush).count == 1, "\(inserts(flush).map(\.text))")
    }

    private func stagedUnit(_ text: String) -> FieldQueue.Edit {
        var edit = FieldQueue.Edit(kind: .typist, target: text, atCursor: true, requiresVerifiedInsertion: true, isSpeech: true)
        edit.unit = .init(text: text, capitalization: .none, contextFallback: "")
        return edit
    }

    /// #313: a staged unit types at the typewriter pace; a key typed during it lands the rest of the burst as one write and
    /// goes in right after, so the key waits for one write, not for the burst.
    @Test func aStagedUnitTypesAtTheTypewriterPaceAndAKeyFlushesTheRestOfItsBurst() {
        let text = String(repeating: "word ", count: 20) + "end"
        var paced = rig()
        paced.queue.enqueue(stagedUnit(text))
        paced.drain()
        let pieces = inserts(paced)
        #expect(pieces.map(\.text).joined() == text && pieces.count == text.count)
        #expect(pieces.last!.ms - pieces.first!.ms >= Double(pieces.count - 1) * ChunkEntrance.typewriterGapMs - 1e-9)
        #expect(paced.field.string == text)

        var rig = rig()
        rig.queue.enqueue(stagedUnit(text))
        while inserts(rig).count < 10 { rig.tick() }
        let asked = rig.clockMs
        rig.queue.enqueue(.insert("!"))
        rig.drain()
        let all = inserts(rig), key = all.first { $0.text == "!" }!
        let own = all.filter { $0.text != "!" }
        #expect(own.map(\.text).joined() == text)
        #expect(own.last!.text.count > 50, "the rest of the burst went as one write: \(own.last!.text.count)")
        #expect(own.last!.ms <= asked + 2 * rig.tickMs + 1 && key.ms >= own.last!.ms, "key waited \(key.ms - asked) ms")
        // The burst would have taken 600+ ms more; the key goes after the host's usual check wait for one write.
        #expect(key.ms - asked < 500 && Double(text.count) * ChunkEntrance.typewriterGapMs > 2_000)
        #expect(rig.field.string == text + "!" && rig.queue.modelText == rig.field.string && rig.drops.isEmpty)
    }
}
