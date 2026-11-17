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
        #expect(whatsApp.samples >= HostProfile.samplesNeeded && safari.samples >= HostProfile.samplesNeeded)
        #expect(whatsApp.callbacks == .perBurst, "\(whatsApp.summary)")
        #expect(safari.callbacks == .perStage, "\(safari.summary)")
        #expect(whatsApp.movesByCharacters != true && safari.movesByCharacters != false)
        #expect(whatsApp.windowBefore > safari.windowBefore, "the widest report: \(whatsApp.windowBefore) and \(safari.windowBefore)")
        #expect(safari.windowBefore <= 100)
        // A native host's deadline goes down to the floor; Safari's stays well above it, both inside the bounds.
        #expect(whatsApp.deadlineMs == HostProfile.minDeadlineMs, "\(whatsApp.summary)")
        #expect(safari.deadlineMs > whatsApp.deadlineMs + 50, "\(safari.summary)")
        #expect(safari.deadlineMs <= HostProfile.maxDeadlineMs)
    }

    @Test func theColdDeadlineHoldsUntilEnoughSamples() {
        var profile = HostProfile()
        #expect(profile.deadlineMs == HostProfile.coldDeadlineMs)
        profile.heard(afterMs: 30, callbacks: 1)
        profile.heard(afterMs: 35, callbacks: 1)
        #expect(profile.deadlineMs == HostProfile.coldDeadlineMs)
        profile.timedOut()
        #expect(profile.deadlineMs == HostProfile.coldDeadlineMs, "nothing learned yet: no back-off either")
        profile.heard(afterMs: 40, callbacks: 1)
        #expect(profile.deadlineMs == HostProfile.minDeadlineMs)
        // A check that times out backs the learned deadline off; later samples bring it down again.
        profile.timedOut()
        #expect(profile.deadlineMs > HostProfile.minDeadlineMs)
        for _ in 0..<40 { profile.heard(afterMs: 35, callbacks: 1) }
        #expect(profile.deadlineMs == HostProfile.minDeadlineMs)
        // A very slow host is bounded.
        for _ in 0..<60 { profile.heard(afterMs: 5_000, callbacks: 3) }
        #expect(profile.deadlineMs == HostProfile.maxDeadlineMs)
        #expect(profile.callbacks == .perStage)
    }

    /// Device run 4 (WhatsApp): after small chunks the learned deadline was 104 ms; a chunk deleting 23 graphemes showed at
    /// about 104 ms, its check failed by a hair and a read walk took 1.8 s. A chunk's deadline grows with its delete run.
    @Test func aLongDeleteRunGetsMoreTimeThanTheLearnedLatency() {
        var profile = HostProfile()
        for ms in [30.0, 62, 18, 41, 26] { profile.heard(afterMs: ms, callbacks: 1) }
        #expect(profile.deadlineMs(deletes: 0) == profile.deadlineMs)
        #expect(profile.deadlineMs(deletes: 23) >= profile.deadlineMs + 23 * 3, "\(profile.summary)")
        #expect(profile.deadlineMs(deletes: 23) > 104 + 40)
    }

    @Test func aNewFieldStartsOverASentDraftDoesNot() {
        var rig = edited(.whatsApp, edits: 3)
        let learned = rig.queue.host
        #expect(learned.samples >= HostProfile.samplesNeeded)
        rig.queue.reset(keepingHost: true)
        #expect(rig.queue.host == learned, "a sent or cleared draft is the same field")
        rig.queue.reset()
        #expect(rig.queue.host == HostProfile())
        #expect(rig.queue.deadlineMs == FieldQueue.checkDeadlineMs)
    }
}
