import Foundation
import Testing
@testable import LegatoFieldEdit

/// The run's own stream is never refused as the user's for text the user did not touch (review L6 #8, the device
/// "Send, then dictate again" defect): a deletion leaves a zero-length taint where the user's text was, and every
/// later ASR chunk at the caret touched it, so the next run's text never reached the field.
struct FieldEditQueueStreamTaintTests {
    let v0 = FieldVersion(0)

    /// The user deletes the run's last letter: the next chunk appends at that very place, and lands.
    @Test func aChunkAtAPlaceTheUserDeletedLands() {
        var field = ""
        var queue = macQueue(field)
        queue.submit(EditTransaction(origin: .asr, owner: "run", base: v0, steps: [.insert("hello there", at: 0)]))
        queue.drain(&field)
        queue.hostEdit(&field, to: "hello ther")
        _ = queue.takeEvents()
        let chunk = EditTransaction(origin: .asr, owner: "run", base: queue.document.version, steps: [.insert("e you", at: 10)])
        queue.submit(chunk)
        #expect(queue.drain(&field).count == 1)
        #expect(field == "hello there you")
        #expect(!queue.takeEvents().contains { if case .conflict(_, let c) = $0 { c.reason == .ownerTainted } else { false } })
    }

    /// The host emptied the run's text as the user's deletion (a send seen as an edit): the next run's stream
    /// starts there, rewrites its own tentative text there, and lands every time.
    @Test func theNextRunStreamsWhereTheLastRunsTextWasDeleted() {
        var field = ""
        var queue = macQueue(field)
        queue.submit(EditTransaction(origin: .asr, owner: "run1", base: v0, steps: [.insert("Hi. teh cat", at: 0)]))
        queue.drain(&field)
        queue.hostEdit(&field, to: "Hi. ")  // the run's text deleted by the user (or a send the queue took for one)
        _ = queue.takeEvents()
        queue.submit(EditTransaction(origin: .asr, owner: "run2", base: queue.document.version, steps: [.insert("A dgo", at: 4)]))
        #expect(queue.drain(&field).count == 1)
        // Its tentative tail is rewritten from the run's start (a delete-and-type of its own text).
        queue.submit(EditTransaction(
            origin: .asr, owner: "run2", base: queue.document.version, steps: [replace(4, "A dgo", with: "A dog ran")]))
        #expect(queue.drain(&field).count == 1)
        #expect(field == "Hi. A dog ran")
        #expect(!queue.takeEvents().contains { if case .conflict(_, let c) = $0 { c.reason == .ownerTainted } else { false } })
    }

    /// Text the user typed stays theirs: a stream step that rewrites it is still refused.
    @Test func aStreamStepOverTheUsersTypedTextIsStillRefused() {
        var field = ""
        var queue = macQueue(field)
        queue.submit(EditTransaction(origin: .asr, owner: "run", base: v0, steps: [.insert("teh report", at: 0)]))
        queue.drain(&field)
        queue.hostEdit(&field, to: "tex report", caret: 3)
        _ = queue.takeEvents()
        let step = EditTransaction(origin: .asr, owner: "run", base: queue.document.version, steps: [replace(0, "tex", with: "the")])
        queue.submit(step)
        #expect(queue.drain(&field).isEmpty)
        #expect(queue.takeEvents().first == .conflict(step.id, Conflict(.ownerTainted, byUser: true)))
    }

    /// A deletion strictly inside the step's span: rewriting the run would undo it, so the step is refused.
    @Test func aStreamRewriteSpanningTheUsersDeletionIsRefused() {
        var field = ""
        var queue = macQueue(field)
        queue.submit(EditTransaction(origin: .asr, owner: "run", base: v0, steps: [.insert("hello big world", at: 0)]))
        queue.drain(&field)
        queue.hostEdit(&field, to: "hello world")
        _ = queue.takeEvents()
        let step = EditTransaction(
            origin: .asr, owner: "run", base: queue.document.version,
            steps: [replace(0, "hello world", with: "hello big world.")])
        queue.submit(step)
        #expect(queue.drain(&field).isEmpty)
        #expect(field == "hello world")
        #expect(queue.takeEvents().first == .conflict(step.id, Conflict(.ownerTainted, byUser: true)))
    }

    /// Every taint is reported with its source, for the keyboard's trace.
    @Test func taintsAreReportedWithTheirSource() {
        var field = ""
        var queue = macQueue(field)
        queue.submit(EditTransaction(origin: .asr, owner: "run", base: v0, steps: [.insert("teh report", at: 0)]))
        queue.drain(&field)
        queue.hostEdit(&field, to: "tex report", caret: 3)
        #expect(queue.takeTaints() == [TaintNote(source: .userEdit, span: Span(location: 2, length: 1))])
        #expect(queue.takeTaints().isEmpty)
    }

    /// A cleared field is a run boundary: nothing stays tainted or owned.
    @Test func aClearedFieldLeavesNoTaint() {
        var field = ""
        var queue = macQueue(field)
        queue.submit(EditTransaction(origin: .asr, owner: "run", base: v0, steps: [.insert("teh report", at: 0)]))
        queue.drain(&field)
        queue.hostEdit(&field, to: "tex report", caret: 3)
        queue.hostEdit(&field, to: "")
        #expect(queue.document.tainted.isEmpty && queue.document.owned.isEmpty)
    }
}
