import Testing
@testable import LegatoKeyboardCore

/// While the selection or context is unverified (an external callback whose report stayed the same), a take's words
/// still go in at the caret as plain inserts; everything that needs to know where the caret is stays held.
@Suite struct FieldQueueHeldSpeechTests {
    enum Reason: String, CaseIterable, Sendable { case selection, externalContext }

    private static let draft = "Old draft safe 4471"

    private func heldRig(_ text: String = draft, reason: Reason, hostDelays: Bool, animated: Bool = true) -> QueueRig {
        var field = FakeField(text); field.hostDelays = hostDelays
        var rig = QueueRig(field, config: .init(prioritizeSpeech: true))
        rig.run(ms: 300)
        hold(&rig, reason)
        return rig
    }

    /// The native callback with an unchanged report and no selection shown.
    private func hold(_ rig: inout QueueRig, _ reason: Reason) {
        switch reason {
        case .selection: rig.queue.observe(rig.field.current, callback: .selection, hasText: true, elapsedSinceLastStepMs: 2_000)
        case .externalContext: rig.queue.observe(rig.field.current, callback: .text, hasText: true, elapsedSinceLastStepMs: 2_000)
        }
    }

    private func isInsert(_ op: ShadowOp) -> Bool { if case .insert = op { true } else { false } }

    /// Ticks until the hold lifted; returns how many ops were sent by then.
    private func runUntilReleased(_ rig: inout QueueRig) -> Int {
        while rig.queue.hasUnverifiedInput, rig.clockMs < 20_000 { rig.tick() }
        return rig.sent.count
    }

    @Test(arguments: Reason.allCases, [false, true])
    func speechIsTypedAtTheCaretAndItsReportLiftsTheHold(reason: Reason, hostDelays: Bool) {
        var rig = heldRig(reason: reason, hostDelays: hostDelays)
        #expect(rig.queue.hasUnverifiedInput)
        #expect(rig.queue.unverifiedInputReason == (reason == .selection ? .selection : .externalContext))
        rig.queue.enqueue(snap(1, "the cat waits near the boat"))
        let held = runUntilReleased(&rig)
        #expect(!rig.queue.hasUnverifiedInput)
        #expect(held > 0)
        #expect(rig.sent.prefix(held).allSatisfy { isInsert($0.op) })
        do { let drained = rig.drain(); #expect(drained) }
        #expect(rig.field.string == Self.draft + " the cat waits near the boat")
        #expect(rig.queue.modelText == rig.field.string)
        // Nothing typed twice, and nothing but appends for a take that only grew.
        #expect(rig.sent.allSatisfy { isInsert($0.op) })
        #expect(rig.sent.map { if case .insert(let s) = $0.op { s } else { "" } }.joined() == " the cat waits near the boat")
        // The old text with the insert showed: confirmed as typed, the model was never replaced.
        #expect(!rig.events.contains { $0.event == .resync(.reseeded) })

        // The run's piece covers what the raw path typed: a later revision and the final text apply to it.
        rig.queue.enqueue(snap(2, "the dog waits near the boat.", complete: true))
        do { let drained = rig.drain(); #expect(drained) }
        #expect(rig.field.string == Self.draft + " the dog waits near the boat.")
        #expect(rig.queue.modelText == rig.field.string)
        #expect(!rig.field.deletions.contains { $0.origin != .live })
        #expect(rig.drops.isEmpty)
        #expect(rig.events.contains { if case .liveApplied("r", 2, true) = $0.event { true } else { false } })
        #expect(rig.field.caret == rig.field.userCaret)
    }

    @Test(arguments: [false, true], [false, true])
    func aHiddenSelectAllIsReplacedAndTheReportBecomesTheModel(hostDelays: Bool, animated: Bool) {
        var field = FakeField(Self.draft); field.hostDelays = hostDelays
        var rig = QueueRig(field, config: .init(prioritizeSpeech: true))
        rig.run(ms: 300)
        // Safari's opaque Select All: the report stays the same and shows no selection.
        rig.field.hidesSelection = true
        rig.field.select(0..<rig.field.text.count)
        #expect(rig.field.current == FieldQueue.Report(before: Self.draft))
        hold(&rig, .selection)
        #expect(rig.queue.hasUnverifiedSelection)
        rig.queue.enqueue(snap(1, "the cat waits near the boat"))
        let held = runUntilReleased(&rig)
        #expect(held > 0)
        #expect(rig.sent.prefix(held).allSatisfy { isInsert($0.op) })
        do { let drained = rig.drain(); #expect(drained) }
        // The first insert replaced the selection, as a key would; the rest of the speech followed, once.
        #expect(rig.field.string.trimmingCharacters(in: .whitespaces) == "the cat waits near the boat")
        #expect(rig.queue.modelText == rig.field.string)
        #expect(rig.sent.allSatisfy { isInsert($0.op) })
        #expect(rig.sent.map { if case .insert(let s) = $0.op { s } else { "" } }.joined() == " the cat waits near the boat")
        #expect(rig.drops.isEmpty)
        #expect(rig.events.contains { $0.event == .resync(.reseeded) })
        #expect(rig.field.deletions.allSatisfy { $0.origin == .initial })

        rig.queue.enqueue(snap(2, "the dog waits near the boat.", complete: true))
        do { let drained = rig.drain(); #expect(drained) }
        #expect(rig.field.string.trimmingCharacters(in: .whitespaces) == "the dog waits near the boat.")
        #expect(rig.queue.modelText == rig.field.string)
        #expect(rig.events.contains { if case .liveApplied("r", 2, true) = $0.event { true } else { false } })
    }

    /// The proxy's windows were stale (text arrived unseen): the fresh report after the insert is the model, and the
    /// take goes on from its own words before the caret.
    @Test func staleContextIsReplacedByTheReportAfterTheInsert() {
        var queue = FieldQueue(config: .init())
        let stale = FieldQueue.Report(before: "Le")
        _ = queue.step(report: stale, elapsedMs: 200)
        queue.observe(stale, callback: .text)
        queue.enqueue(snap(1, "hello"))
        #expect(queue.step(report: stale, elapsedMs: 200) == .send(.insert(" hello")))
        queue.operationDispatched()
        let fresh = FieldQueue.Report(before: "Legato external synthetic text. hello")
        var sent: [ShadowOp] = []
        for _ in 0..<10 {
            guard case .send(let op) = queue.step(report: fresh, elapsedMs: 50) else { continue }
            sent.append(op); queue.operationDispatched()
        }
        #expect(sent.isEmpty)
        #expect(!queue.hasUnverifiedInput)
        #expect(queue.modelText == fresh.before)
        #expect(queue.openRegion?.text == " hello")
        queue.enqueue(snap(2, "hello there"))
        #expect(queue.step(report: fresh, elapsedMs: 200) == .send(.insert(" there")))
    }

    @Test(arguments: Reason.allCases)
    func whileHeldOnlyInsertsGoAndEditsWait(reason: Reason) {
        var queue = FieldQueue(config: .init())
        let old = FieldQueue.Report(before: Self.draft)
        _ = queue.step(report: old, elapsedMs: 200)
        switch reason {
        case .selection: queue.observe(old, callback: .selection)
        case .externalContext: queue.observe(old, callback: .text)
        }
        queue.enqueue(FieldQueue.Edit(id: "magic", kind: .magic, before: Self.draft, target: "New draft safe 4471"))
        queue.enqueue(snap(1, "the cat waits"))
        // The proxy never shows anything new: the hold cannot lift.
        var sent: [ShadowOp] = []
        func pump(_ queue: inout FieldQueue, steps: Int) -> [ShadowOp] {
            var ops: [ShadowOp] = []
            for _ in 0..<steps {
                guard case .send(let op) = queue.step(report: old, elapsedMs: 100) else { continue }
                ops.append(op); queue.operationDispatched()
            }
            return ops
        }
        sent += pump(&queue, steps: 30)
        #expect(sent == [.insert(" the cat waits")])
        // A revision of what was typed needs a delete: it waits. Words said after it are plain appends and go.
        queue.enqueue(snap(2, "the dog waits"))
        sent += pump(&queue, steps: 30)
        #expect(sent == [.insert(" the cat waits")])
        queue.enqueue(snap(3, "the dog waits here", complete: true))
        sent += pump(&queue, steps: 30)
        #expect(sent == [.insert(" the cat waits"), .insert(" here")])
        #expect(queue.hasUnverifiedInput)
        #expect(queue.pendingEditIDs == ["magic"])
    }

    @Test(arguments: Reason.allCases, [false, true])
    func aKeyDuringTheHeldSpeechGoesNextAndInOrder(reason: Reason, hostDelays: Bool) throws {
        var rig = heldRig(reason: reason, hostDelays: hostDelays)
        rig.queue.enqueue(snap(1, "the cat waits near the boat"))
        while rig.sent.isEmpty, rig.clockMs < 5_000 { rig.tick() }
        // The speech is one chunk, on its way: the key goes right behind it.
        try #require(rig.sent.map(\.op) == [.insert(" the cat waits near the boat")])
        rig.queue.enqueue(.insert("!"))
        do { let drained = rig.drain(); #expect(drained) }
        #expect(rig.sent.map(\.op) == [.insert(" the cat waits near the boat"), .insert("!")])
        #expect(rig.field.string == Self.draft + " the cat waits near the boat!")
        #expect(rig.queue.modelText == rig.field.string)
        #expect(!rig.queue.hasUnverifiedInput)
        #expect(rig.field.deletions.isEmpty)
    }

    /// Unchanged by the held speech: a key pressed before any of it went is first, raw.
    @Test func aKeyBeforeTheHeldSpeechIsStillFirst() {
        var rig = heldRig(reason: .selection, hostDelays: false)
        rig.queue.enqueue(snap(1, "the cat waits"))
        rig.queue.enqueue(.insert("!"))
        rig.tick()
        #expect(rig.sent.first?.op == .insert("!"))
        rig.drain()
        #expect(rig.field.string.hasPrefix(Self.draft + "!"))
        #expect(!rig.queue.hasUnverifiedInput)
        #expect(rig.field.deletions.isEmpty)
        // As before: the raw key starts the model over, the take is reported dropped (the app keeps it).
        #expect(rig.drops.map(\.reason) == [.reset])
    }
}
