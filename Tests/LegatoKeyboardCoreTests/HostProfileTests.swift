import Foundation
import Testing
@testable import LegatoKeyboardCore

/// #299 round 4: the queue learns each field's host at runtime (no host table). WhatsApp and Notes answer a burst with
/// one callback within ~50 ms; Safari answers stage by stage, its last callback up to ~350 ms later. The check's
/// deadline follows the learned latency, within bounds, and starts over with a new field.
@Suite struct HostProfileTests {
    private static let words = ["alpha", "bravo", "charlie", "delta", "echo", "foxtrot", "golf", "hotel", "india", "juliet"]

    /// A rig on `host` that ran `edits` mid-text edits, each a chunk with hops.
    private func edited(_ host: FakeField.Host, edits: Int) -> QueueRig {
        var text = (Self.words + Self.words + Self.words).joined(separator: " ")
        var rig = QueueRig(FakeField.host(host, text))
        rig.run(ms: 100)
        for i in 0..<edits {
            let word = Self.words[i % 3]
            let target = text.replacingOccurrences(of: word, with: word.uppercased())
            rig.queue.enqueue(FieldQueue.Edit(kind: .magic, before: text, target: target, cursorAtEnd: false))
            rig.drain()
            #expect(rig.field.string == target)
            text = target.lowercased()
            rig.queue.enqueue(FieldQueue.Edit(kind: .magic, before: target, target: text, cursorAtEnd: false))
            rig.drain()
            #expect(rig.field.string == text)
        }
        return rig
    }

    @Test func aCoalescingFieldAndAPerStageFieldLearnDifferentDeadlines() {
        let whatsApp = edited(.whatsApp, edits: 4).queue.host
        let safari = edited(.safari, edits: 4).queue.host
        #expect(whatsApp.samples >= HostLatency.samplesNeeded && safari.samples >= HostLatency.samplesNeeded)
        #expect(whatsApp.callbacks == .perBurst, "\(whatsApp.summary)")
        #expect(safari.callbacks == .perStage, "\(safari.summary)")
        #expect(whatsApp.movesByCharacters != true && safari.movesByCharacters != false)
        #expect(whatsApp.windowBefore > safari.windowBefore, "the widest report: \(whatsApp.windowBefore) and \(safari.windowBefore)")
        #expect(safari.windowBefore <= 100)
        // A native host's deadline goes down to the floor; Safari's stays well above it, both inside the bounds.
        #expect(whatsApp.deadlineMs == HostLatency.minDeadlineMs, "\(whatsApp.summary)")
        #expect(safari.deadlineMs > whatsApp.deadlineMs + 50, "\(safari.summary)")
        #expect(safari.deadlineMs <= HostLatency.maxDeadlineMs)
    }

    @Test func aNewFieldStartsOverASentDraftDoesNot() {
        var rig = edited(.whatsApp, edits: 3)
        let learned = rig.queue.host
        #expect(learned.samples >= HostLatency.samplesNeeded)
        rig.queue.reset(keepingHost: true)
        #expect(rig.queue.host == learned, "a sent or cleared draft is the same field")
        rig.queue.reset()
        #expect(rig.queue.host == HostProfile())
        #expect(rig.queue.deadlineMs == FieldQueue.checkDeadlineMs)
    }
}
