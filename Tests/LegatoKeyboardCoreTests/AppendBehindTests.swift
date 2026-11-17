import Foundation
import Testing
@testable import LegatoKeyboardCore

/// #299 round 4: speech at the caret never waits for a running chunk's check. Hosts apply ops in order (measured), so
/// the chunk's check covers the appended words too; a chunk with hops still waits for its check before the next one.
@Suite struct AppendBehindTests {
    private static let take = "alpha bravo charlie delta echo foxtrot golf hotel"

    /// A WhatsApp field that learned it answers a burst with one callback, with a take typed and a cleanup chunk (hops to
    /// "bravo" and back) sent; its check is still open.
    private func chunkInFlight(_ host: FakeField.Host = .whatsApp) -> QueueRig {
        var rig = QueueRig(FakeField.host(host, ""))
        rig.run(ms: 100)
        rig.queue.enqueue(snap(1, Self.take))
        rig.drain()
        // Learn the host: a few edits with hops.
        for word in ["alpha", "charlie", "echo"] {
            let text = rig.field.string
            rig.queue.enqueue(FieldQueue.Edit(kind: .magic, before: text, target: text.replacingOccurrences(of: word, with: word.uppercased()),
                                              cursorAtEnd: false))
            rig.drain()
        }
        #expect(rig.queue.host.callbacks == (host == .safari ? .perStage : .perBurst))
        let text = rig.field.string
        rig.queue.enqueue(FieldQueue.Edit(id: "cleanup", kind: .magic, before: text,
                                          target: text.replacingOccurrences(of: "bravo", with: "Bravo"), cursorAtEnd: false))
        let start = rig.sent.count
        // Until the chunk's hop back went out: its ops are done, its check is open.
        while rig.clockMs < 5_000 {
            rig.tick()
            let ops = rig.sent.dropFirst(start).map(\.op)
            if ops.contains(.insert("B")), case .move? = ops.last, rig.queue.hasOpInFlight, !rig.queue.isInChunk { break }
        }
        #expect(rig.queue.hasOpInFlight && !rig.queue.isInChunk)
        return rig
    }

    @Test func speechGoesBehindARunningChunkWithoutWaitingForItsCheck() {
        var rig = chunkInFlight()
        _ = rig.queue.drainEvents()
        // More words arrive before the host's callback for the chunk.
        rig.queue.enqueue(snap(2, Self.take + " india juliet"))
        let action = rig.queue.step(report: rig.field.tick(fresh: false), elapsedMs: 1, callback: false)
        #expect(action == .send(.insert(" india juliet")), "the words go right behind the chunk")
        let events = rig.queue.drainEvents()
        #expect(!events.contains { if case .confirmed = $0 { true } else { false } }, "before the chunk's check")
        rig.field.send(.init(op: .insert(" india juliet"), writer: .live))
        rig.drain()
        #expect(rig.field.string == "ALPHA Bravo CHARLIE delta ECHO foxtrot golf hotel india juliet")
        #expect(rig.queue.modelText == rig.field.string)
        #expect(!rig.events.contains { if case .resync(.checkFailed) = $0.event { true } else { false } })
        #expect(rig.applied.contains("cleanup"))
    }

    /// The chunk landed but the words behind it never showed (the host lost them): the check fails, the words come out
    /// of the model and go again. Nothing is lost, nothing is doubled.
    @Test func aFailedCheckWithSpeechBehindItLosesNothing() {
        var rig = chunkInFlight()
        rig.queue.enqueue(snap(2, Self.take + " india juliet"))
        let action = rig.queue.step(report: rig.field.tick(fresh: false), elapsedMs: 1, callback: false)
        #expect(action == .send(.insert(" india juliet")))
        // Not sent to the field: the host dropped it.
        rig.drain()
        #expect(rig.events.contains { if case .resync(.checkFailed) = $0.event { true } else { false } })
        #expect(rig.field.string == "ALPHA Bravo CHARLIE delta ECHO foxtrot golf hotel india juliet")
        #expect(rig.queue.modelText == rig.field.string)
        #expect(rig.drops.isEmpty)
    }

    /// The next chunk with hops waits for the check of the one before, appends or not.
    @Test func aChunkWithHopsWaitsForTheCheckBeforeIt() {
        var rig = chunkInFlight()
        let text = rig.queue.modelText
        rig.queue.enqueue(FieldQueue.Edit(id: "next", kind: .magic, before: text, target: text.replacingOccurrences(of: "golf", with: "Golf"),
                                          cursorAtEnd: false))
        rig.queue.enqueue(snap(2, Self.take + " india"))
        let start = rig.sent.count
        let action = rig.queue.step(report: rig.field.tick(fresh: false), elapsedMs: 1, callback: false)
        #expect(action == .send(.insert(" india")))
        if case .send(let op) = action { rig.field.send(.init(op: op, writer: .live)) }
        #expect(rig.queue.step(report: rig.field.tick(fresh: false), elapsedMs: 1, callback: false) == .wait,
                "no hop goes out before the check")
        #expect(rig.sent.count == start)
        rig.drain()
        #expect(rig.field.string == "ALPHA Bravo CHARLIE delta ECHO foxtrot Golf hotel india")
    }

    /// Safari answers stage by stage: speech waits for the check there (its proxy keeps the report after a move while an
    /// edit sent right behind it lands).
    @Test func speechWaitsBehindAChunkInAPerStageField() {
        var rig = chunkInFlight(.safari)
        rig.queue.enqueue(snap(2, Self.take + " india juliet"))
        #expect(rig.queue.step(report: rig.field.tick(fresh: false), elapsedMs: 1, callback: false) == .wait)
        rig.drain()
        #expect(rig.field.string == "ALPHA Bravo CHARLIE delta ECHO foxtrot golf hotel india juliet")
    }
}
