import Testing
@testable import LegatoKeyboardCore

/// The shadow-document model's contracts (#299): the observer's classification, chunk planning, hops that look and
/// correct, and a failed check that re-reads.
@Suite struct ShadowObserverTests {
    @Test func cleanupReplacingTheNextPiecesFirstLetterKeepsTheSharedBoundary() {
        var document = shadow("x water it gently tomorrow.", "plant basil.")
        let at = document.cursor
        var preceding = ShadowDocument.Span(start: 1, end: at)
        preceding.dictated = true
        var following = ShadowDocument.Span(start: at, end: document.text.count)
        following.dictated = true
        var scope = ShadowDocument.Span(start: 0, end: document.text.count)
        scope.cleanup = true
        let earlier = document.addSpan(preceding)
        let later = document.addSpan(following)
        let edit = document.addSpan(scope)

        document.removeRange(at, at + 1, owner: edit)
        document.insertAtCursor(["P"], owner: edit)
        #expect(document.userCursor == at)
        #expect(document.spans[earlier]?.end == at)
        #expect(document.spans[later]?.start == at)
        #expect(String(document.text) == "x water it gently tomorrow.Plant basil.")
    }

    private func shadow(_ before: String, _ after: String = "") -> ShadowDocument {
        var doc = ShadowDocument()
        doc.seed(.init(before: before, after: after))
        return doc
    }

    @Test func aReportOfTheShadowAtItsCaretMatches() {
        let doc = shadow("the quick brown fox", " jumps over")
        #expect(doc.observe(.init(before: "brown fox", after: " jumps")) == .match)
    }

    @Test func aReportReachingFurtherExtends() {
        let doc = shadow("brown fox", " jumps")
        #expect(doc.observe(.init(before: "the quick brown fox", after: " jumps")) == .extends)
        #expect(doc.observe(.init(before: "brown fox", after: " jumps over the lazy dog")) == .extends)
    }

    @Test func knownTextElsewhereStitchesThere() {
        let doc = shadow("the quick brown fox jumps over the lazy dog")
        #expect(doc.observe(.init(before: "the quick brown ", after: "fox jumps over the")) == .stitch(at: 16))
    }

    @Test func aShortWindowIsNoEvidenceForAStitch() {
        let doc = shadow("the quick brown fox jumps over the lazy dog")
        #expect(doc.observe(.init(before: "quick ", after: "brown")) == .seam)
    }

    @Test func unknownTextIsASeam() {
        let doc = shadow("the quick brown fox")
        #expect(doc.observe(.init(before: "an entirely different draft")) == .seam)
    }

    /// Notes and Safari issue a new identity when a field becomes empty, WhatsApp once with no visible cause: the same
    /// text is the same field. An empty report while the shadow holds text is not.
    @Test func aNewIdentityWithTheSameTextIsKept() {
        var queue = FieldQueue()
        let report = FieldQueue.Report(before: "Meet at the harbour at nine", after: "")
        _ = queue.step(report: report, elapsedMs: 200)
        #expect(queue.observe(report, callback: .identity) == .match)
        #expect(queue.drainEvents().contains(.resync(.identityKept)))
        #expect(queue.observe(.init(before: ""), callback: .identity) == .seam)

        var empty = FieldQueue()
        _ = empty.step(report: .init(before: ""), elapsedMs: 200)
        #expect(empty.observe(.init(before: ""), callback: .identity) == .match)
    }

    @Test func transientBlankAfterAConfirmedMoveDoesNotEndTheDraftOrConsumeItsSpeech() {
        var rig = QueueRig(FakeField("Please move the review to Thursday."))
        rig.queue.enqueue(.move(-5))
        rig.drain()
        let known = rig.field.current
        let empty = FieldQueue.Report(before: "")
        #expect(!rig.queue.hasOpInFlight)
        var evidence = FieldQueue.DraftEvidence()
        let deadline = rig.queue.draftConfirmationMs
        #expect(evidence.observe(known, hasText: true, ownsEmpty: false, nowMs: 0, confirmationMs: deadline) == .unchanged)
        #expect(evidence.observe(empty, hasText: false, ownsEmpty: false, nowMs: 10, confirmationMs: deadline) == .pending)

        rig.queue.enqueue(snap(1, "after lunch"))
        #expect(rig.queue.step(report: empty, elapsedMs: 100, awaitingDraftEvidence: evidence.isPending) == .wait)
        rig.queue.enqueue(.insert("x"))
        #expect(rig.queue.step(report: empty, elapsedMs: 30, awaitingDraftEvidence: evidence.isPending) == .send(.insert("x")))
        rig.queue.operationDispatched()
        rig.field.apply(.insert("x"))
        let returning = rig.field.current
        #expect(rig.queue.recognizesDraft(returning))
        #expect(evidence.observe(returning, hasText: true, ownsEmpty: false, nowMs: 165, confirmationMs: deadline) == .resumed)
        rig.drain()
        #expect(rig.field.string.contains("x"))
        #expect(rig.field.string.contains("after lunch"))
    }

    /// #343, Reminders: as its editor resigns, the proxy loses its field (no document) some 400 ms before the keyboard leaves. That
    /// empty report is no evidence the draft was sent, however long it lasts. A bound field that empties (a send) still clears it.
    @Test func anUnboundFieldIsNoEvidenceThatTheDraftWasCleared() {
        var evidence = FieldQueue.DraftEvidence()
        let deadline = FieldQueue().draftConfirmationMs
        let known = FieldQueue.Report(before: "Q fresh words")
        let empty = FieldQueue.Report(before: "")
        #expect(evidence.observe(known, hasText: true, ownsEmpty: false, nowMs: 0, confirmationMs: deadline) == .unchanged)
        for t in [10.0, deadline, deadline * 5] {
            #expect(evidence.observe(empty, hasText: false, ownsEmpty: false, nowMs: t, confirmationMs: deadline, bound: false) == .unbound)
        }
        #expect(!evidence.isPending)
        #expect(evidence.observe(known, hasText: true, ownsEmpty: false, nowMs: deadline * 6, confirmationMs: deadline) == .unchanged)

        let sentAt = deadline * 7
        #expect(evidence.observe(empty, hasText: false, ownsEmpty: false, nowMs: sentAt, confirmationMs: deadline) == .pending)
        #expect(evidence.observe(empty, hasText: false, ownsEmpty: false, nowMs: sentAt + deadline, confirmationMs: deadline) == .cleared)
    }

    @Test func blankLineRecoveryRequiresIndependentEvidenceOfTheOriginalCaret() throws {
        let upper = "The upper paragraph is uniquely known."
        let lower = "The lower paragraph is also known."
        let origin = FieldQueue.Report(before: upper + "\n", after: "\n" + lower)
        var rig = QueueRig(FakeField(upper + "\n\n" + lower, caret: origin.before.count))
        rig.run(ms: 100)
        let probe = try #require(rig.queue.blankLineProbe())
        #expect(probe.units == -1)
        rig.queue.enqueue(snap(1, "At noon.", complete: true))
        let held = rig.queue.step(report: .init(before: ""), elapsedMs: 45, awaitingDraftEvidence: true)
        #expect(held == .wait)

        rig.field.apply(.move(probe.units))
        let neighbor = rig.field.current
        #expect(probe.confirmsLandmark(neighbor))
        #expect(!probe.confirmsOrigin(neighbor))
        #expect(!probe.confirmsOrigin(.init(before: "")))
        #expect(probe.confirmsOrigin(.init(before: "\n", after: "\n")))
        rig.field.apply(.move(-probe.units))
        #expect(probe.confirmsOrigin(rig.field.current))
        rig.drain()
        #expect(rig.field.string == upper + "\nAt noon.\n" + lower)
    }

    @Test func blankLineRecoveryUsesTheLowerLineOnlyWhenTheUpperIsUnavailable() throws {
        let lower = "The lower paragraph is uniquely known."
        var queue = FieldQueue()
        _ = queue.step(report: .init(before: "", after: "\n" + lower), elapsedMs: 0)
        let probe = try #require(queue.blankLineProbe())
        #expect(probe.units == 2)
        let neighbor = FieldQueue.Report(before: "\nT", after: String(lower.dropFirst()))
        #expect(probe.confirmsLandmark(neighbor))

        queue.enqueue(.insert("x"))
        #expect(queue.blankLineProbe() == nil, "a pending key preempts the automatic excursion")

        var unstructured = FieldQueue()
        _ = unstructured.step(report: .init(before: "Host context without a hard line break."), elapsedMs: 0)
        #expect(unstructured.blankLineProbe() == nil)
    }

    @Test func onlySustainedConfirmedEmptinessEndsTheDraft() {
        var evidence = FieldQueue.DraftEvidence()
        let nonempty = FieldQueue.Report(before: "This field was known.")
        let empty = FieldQueue.Report(before: "")
        let deadline = FieldQueue.checkDeadlineMs
        #expect(evidence.observe(nonempty, hasText: true, ownsEmpty: false, nowMs: 0, confirmationMs: deadline) == .unchanged)
        #expect(evidence.observe(empty, hasText: false, ownsEmpty: false, nowMs: 100, confirmationMs: deadline) == .pending)
        #expect(evidence.observe(empty, hasText: true, ownsEmpty: false, nowMs: 500, confirmationMs: deadline) == .pending)
        #expect(evidence.recheckAfterMs(nowMs: 500, confirmationMs: deadline) == nil)
        #expect(evidence.recheckAfterMs(nowMs: 500, confirmationMs: deadline, includingOpaque: true) == 0)
        #expect(evidence.observe(empty, hasText: false, ownsEmpty: false, nowMs: 550, confirmationMs: deadline) == .pending)
        #expect(evidence.observe(empty, hasText: false, ownsEmpty: false, nowMs: 550 + deadline, confirmationMs: deadline) == .cleared)
        #expect(!evidence.isPending)
    }
}

@Suite struct ChunkPlanningTests {
    private func edit(_ text: String, to target: String, field: FakeField? = nil) -> (sent: [ShadowOp], field: FakeField) {
        var rig = QueueRig(field ?? FakeField(text))
        rig.run(ms: 100)
        let from = rig.sent.count
        rig.queue.enqueue(FieldQueue.Edit(kind: .magic, before: text, target: target, cursorAtEnd: false))
        rig.drain()
        return (rig.sent[from...].map(\.op), rig.field)
    }

    /// A change at the caret is rewritten from the caret: no hop.
    @Test func aTailChangeNeedsNoHop() {
        let result = edit("the cat sat", to: "the cat sat.")
        #expect(result.sent == [.insert(".")])
        let near = edit("the cat sat.", to: "the cat sit.")
        #expect(near.sent == [.deleteBackward(3), .insert("it.")], "the two characters between are typed again")
        #expect(near.field.string == "the cat sit.")
    }

    /// A change mid-text: one hop there, one delete run, one insert, the hop back. Unchanged text stays.
    @Test func aMidTextChangeIsOneChunk() {
        let result = edit("the cat sat on the mat", to: "the dog sat on the mat")
        #expect(result.sent == [.move(-15), .deleteBackward(3), .insert("dog"), .move(15)])
        #expect(result.field.string == "the dog sat on the mat")
        #expect(result.field.caret == result.field.text.count)
    }

    /// Two places far apart are two chunks, the later one first; each returns to the user's caret.
    @Test func twoPlacesAreTwoChunks() {
        let result = edit("the cat sat on the mat and the dog ran", to: "the cow sat on the mat and the dog hid")
        #expect(result.field.string == "the cow sat on the mat and the dog hid")
        #expect(result.sent.filter { if case .deleteBackward = $0 { true } else { false } }.count == 2)
        #expect(result.sent.first == .deleteBackward(3), "the change at the caret goes first, without a hop")
    }

    /// The rich-editor rule: a line is never left empty while it is replaced.
    @Test func aLineKeepsItsLastGraphemeUntilTheNewTextStands() {
        let result = edit("milk\neggs\nbread", to: "milk\nXY\nbread", field: { var f = FakeField("milk\neggs\nbread"); f.blockEcho = true; return f }())
        #expect(result.field.string == "milk\nXY\nbread")
        // "egg" goes, "XY" stands before the last "s", then the "s" goes: the line is never empty.
        let edits = result.sent.filter { if case .move = $0 { false } else { true } }
        #expect(edits == [.deleteBackward(3), .insert("XY"), .deleteBackward(1)])
    }
}

@Suite struct ChunkHopTests {
    /// The field counts moves in graphemes, the keyboard in UTF-16: the hop over the emoji overshoots, the look sees
    /// where it landed, and the next hop corrects by what is left.
    @Test func aHopInTheOtherUnitIsCorrectedByLooking() {
        var field = FakeField("the cat 👍👍 sat on the mat")
        field.movesByCharacters = true
        var rig = QueueRig(field)
        rig.queue.config.movesByCharacters = false
        rig.run(ms: 100)
        rig.queue.enqueue(FieldQueue.Edit(kind: .magic, before: "the cat 👍👍 sat on the mat", target: "the dog 👍👍 sat on the mat", cursorAtEnd: false))
        let drained = rig.drain(); #expect(drained)
        #expect(rig.field.string == "the dog 👍👍 sat on the mat")
        #expect(rig.field.caret == rig.field.text.count)
        #expect(rig.drops.isEmpty)
    }

    /// A target beyond the visible window is reached in several hops, each within sight (WhatsApp drops an overshoot),
    /// also across windows cut at line breaks.
    @Test(arguments: [FakeField.Host.whatsApp, .notes, .safari])
    func farTargetsAreReachedHopByHopWithinSight(host: FakeField.Host) {
        let line = "a line of the list that is long enough to matter here"
        let lines = (1...12).map { "\($0). \(line)" }
        let text = lines.joined(separator: "\n")
        var rig = QueueRig(FakeField.host(host, text))
        rig.run(ms: 100)
        let target = text.replacingOccurrences(of: "2. a line", with: "2. the line")
        rig.queue.enqueue(FieldQueue.Edit(kind: .magic, before: text, target: target, cursorAtEnd: false))
        let drained = rig.drain(limitMs: 30_000); #expect(drained)
        #expect(rig.field.string == target)
        #expect(rig.field.caret == rig.field.text.count)
        let window = host == .safari ? 100 : 300
        #expect(rig.sent.allSatisfy { if case .move(let n) = $0.op { abs(n) <= window } else { true } })
    }

    /// The keyboard's own inserts and deletes make no host callback; only its moves do (measured).
    @Test func ownWritesMakeNoCallback() {
        var rig = QueueRig(FakeField.host(.whatsApp, "the cat sat on the mat"))
        rig.run(ms: 100)
        rig.queue.enqueue(FieldQueue.Edit(kind: .magic, before: "the cat sat on the mat", target: "the dog sat on the mat", cursorAtEnd: false))
        rig.drain()
        let moves = rig.sent.filter { if case .move = $0.op { true } else { false } }.count
        #expect(rig.field.callbacks == moves)
    }
}

@Suite struct ChunkCheckTests {
    /// WhatsApp and Notes answer a whole burst (hop, delete run, insert, hop back) with one callback (#299 probe): a
    /// chunk that ends with its hop back is confirmed by that callback, not by the deadline. Each one used to wait out
    /// the full 400 ms on the phone (run 3 journal: 16 of 19 cleanup chunks at 403–601 ms).
    @Test(arguments: [FakeField.Host.whatsApp, .notes])
    func aChunkEndingWithItsHopBackIsConfirmedByTheBurstsOneCallback(host: FakeField.Host) {
        // The proxy's echo after the hop already shows the text there (as in the run 3 journal), so the whole burst goes out
        // in one turn and comes back as one callback.
        var field = FakeField.host(host, "the cat sat on the mat and looked out of the window")
        field.blindAfterMove = false
        var rig = QueueRig(field)
        rig.run(ms: 100)
        rig.queue.enqueue(FieldQueue.Edit(kind: .magic, before: "the cat sat on the mat and looked out of the window",
                                          target: "the dog sat on the mat and looked out of the window", cursorAtEnd: false))
        rig.drain()
        #expect(String(rig.field.text) == "the dog sat on the mat and looked out of the window")
        let waits = rig.events.compactMap { if case .confirmed(let waited) = $0.event { waited } else { nil } }
        #expect(!waits.isEmpty)
        #expect(waits.allSatisfy { $0 < FieldQueue.checkDeadlineMs / 2 }, "confirmed waits \(waits)")
    }

    /// The host takes the hops but loses the edit: at the deadline the check fails and the queue re-reads (the report is
    /// the model, no blind restore, nothing undone). The edit is answered `unplaceable`, which makes the app's cleanup
    /// run one fresh pass on the text as read (`FieldCleanupSession`).
    @Test func aFailedCheckReReads() {
        var queue = FieldQueue()
        var caret = "the cat sat on the mat".count
        let text = Array("the cat sat on the mat")
        func report() -> FieldQueue.Report { .init(before: String(text[..<caret]), after: String(text[caret...])) }
        _ = queue.step(report: report(), elapsedMs: 100)
        queue.enqueue(FieldQueue.Edit(id: "e", kind: .magic, before: String(text), target: "the dog sat on the mat", cursorAtEnd: false))
        var sent: [ShadowOp] = [], events: [FieldQueue.Event] = []
        for _ in 0..<60 {
            if case .send(let op) = queue.step(report: report(), elapsedMs: 33) {
                sent.append(op)
                if case .move(let n) = op { caret = max(0, min(text.count, caret + n)) }
            }
            events += queue.drainEvents()
        }
        #expect(sent == [.move(-15), .deleteBackward(3), .insert("dog"), .move(15)])
        #expect(events.contains(.resync(.checkFailed)))
        #expect(queue.modelText == String(text), "the model is the field as read")
        #expect(events.contains { if case .dropped(let drop) = $0 { drop.id == "e" && drop.reason == .unplaceable } else { false } })
        #expect(queue.isIdle)
    }

    /// Safari's first callback after a move still shows the old place: a mismatch inside the deadline is no seam.
    @Test func aStaleFirstCallbackIsNoSeam() {
        var field = FakeField.host(.safari, "the cat sat on the mat")
        field.hostDelays = false
        var rig = QueueRig(field)
        rig.run(ms: 100)
        rig.queue.enqueue(FieldQueue.Edit(kind: .magic, before: "the cat sat on the mat", target: "the dog sat on the mat", cursorAtEnd: false))
        let drained = rig.drain(); #expect(drained)
        #expect(rig.field.string == "the dog sat on the mat")
        #expect(!rig.events.contains { if case .resync(let kind) = $0.event { kind == .checkFailed || kind == .reseeded } else { false } })
    }
}
