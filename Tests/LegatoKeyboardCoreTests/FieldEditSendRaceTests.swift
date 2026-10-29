import Foundation
import LegatoFieldEdit
import Testing
@testable import LegatoKeyboardCore

/// The device defect of review item 8: a chat app sends (and empties) the field before the run's Live revision
/// landed, and the next run starts typing at once, while the proxy still reports the old field. The new run's
/// stream is never refused as the user's (`ownerTainted`): a cleared field is a run boundary, and the next run's
/// text is its own.
@MainActor
struct FieldEditSendRaceTests {
    let timers = ManualTimers()

    final class Trace {
        var lines: [String] = []
        func count(_ part: String) -> Int { lines.filter { $0.contains(part) }.count }
    }

    final class Outcomes {
        var all: [UUID: [FieldEditCoordinator.Outcome]] = [:]
        func record(_ id: UUID) -> (FieldEditCoordinator.Outcome) -> Void { { [self] in all[id, default: []].append($0) } }
        var reasons: [Conflict.Reason] {
            all.values.flatMap { $0 }.compactMap { if case .conflict(let c) = $0 { c.reason } else { nil } }
        }
    }

    func asr(_ c: FieldEditCoordinator, _ text: String, owner: String, id: UUID = UUID()) -> EditTransaction {
        EditTransaction(
            id: id, origin: .asr, owner: owner, base: c.predicted.version, steps: [.insert(text, at: c.predicted.caret)])
    }

    /// The device trace: the host sends (empties) the field before reporting it, and run 2's first chunk is typed
    /// into the empty field at once; the first read shows only run 2's "Hi" (caret 43 → 2). Every later chunk of
    /// run 2 lands; none is refused as the user's, and a taint, if any, is traced with its source.
    @Test func aSendReadOnlyAfterTheNextRunsFirstChunkDoesNotBlockThatRun() {
        let d = ManualDocument("")
        let c = FieldEditCoordinator(document: d, settleTimeout: .milliseconds(250), schedule: timers.schedule)
        let trace = Trace()
        c.trace = { trace.lines.append($0) }
        let outcomes = Outcomes()
        c.submit(asr(c, "teh cat sat on the mat and then it ran away", owner: "run1"))
        d.report()
        c.sync()
        d.field = CaretProxy("")  // Send: the host empties the field, not reported yet
        let chunks = ["Hi", " there", " my", " friend", " how", " are", " you"]
        for chunk in chunks {
            let id = UUID()
            c.submit(asr(c, chunk, owner: "run2", id: id), onOutcome: outcomes.record(id))
            timers.advance(by: .milliseconds(40))
            d.report()
            c.sync()
        }
        timers.advance(by: .seconds(2))
        d.report()
        c.sync()
        #expect(!outcomes.reasons.contains(.ownerTainted), "\(trace.lines.joined(separator: "\n"))")
        #expect(d.field.text == "Hi there my friend how are you", "\(d.field.text)")
    }

    /// A taint is traced with its source, so a device log says why later edits were refused.
    @Test func aTaintIsTracedWithItsSource() {
        let d = ManualDocument("")
        let c = FieldEditCoordinator(document: d, settleTimeout: .milliseconds(250), schedule: timers.schedule)
        let trace = Trace()
        c.trace = { trace.lines.append($0) }
        c.submit(asr(c, "teh report", owner: "run"))
        d.report()
        c.sync()
        d.field = CaretProxy("tex report", caret: 3)
        d.report()
        c.sync()
        #expect(trace.count("fe.taint source=userEdit at=2 len=1") == 1, "\(trace.lines)")
    }

    /// Run 1 is in the field with its Live revision waiting behind its last chunk; the host sends and clears; run 2
    /// streams at once, the reports trailing. Then (as `ClearWatch` does when the empty read shows) the queue is
    /// told the field was cleared. Every chunk of run 2 is in the field, none was refused as the user's.
    @Test(arguments: [false, true])
    func theNextRunAfterASendIsNeverRefusedAsTheUsers(clearWatch: Bool) {
        let proxy = LaggingProxy("")
        let c = FieldEditCoordinator(document: proxy, settleTimeout: .milliseconds(250), schedule: timers.schedule)
        let trace = Trace()
        c.trace = { trace.lines.append($0) }
        let outcomes = Outcomes()
        c.submit(asr(c, "teh cat sat.", owner: "run1"))
        proxy.deliverAll()
        c.sync()
        c.submit(asr(c, " A dgo ran.", owner: "run1"))  // its read has not come yet
        let revision = EditTransaction(
            origin: .liveCleanup, owner: "run1", base: c.predicted.version,
            steps: [EditStep(span: Span(location: 0, length: 3), text: "the", expect: "teh")])
        c.submit(revision)  // waits in the cleanup lane
        proxy.hostClears()  // Send
        let chunks = ["Hi", " there", " my", " friend", " how", " are", " you"]
        var cleared = false
        for chunk in chunks {
            let id = UUID()
            // The run's stream is planned on the predicted field (its caret), as the keyboard does.
            c.submit(asr(c, chunk, owner: "run2", id: id), onOutcome: outcomes.record(id))
            timers.advance(by: .milliseconds(40))
            proxy.deliverNext()
            c.sync()
            if clearWatch, !cleared, proxy.contextBefore.isEmpty, proxy.contextAfter.isEmpty {
                cleared = true
                c.fieldCleared()
            }
        }
        proxy.deliverAll()
        c.sync()
        timers.advance(by: .seconds(2))
        proxy.deliverAll()
        c.sync()
        #expect(!outcomes.reasons.contains(.ownerTainted), "\(trace.lines.joined(separator: "\n"))")
        #expect(trace.count("reason=ownerTainted") == 0)
        #expect(proxy.text.hasSuffix(" how are you"), "\(proxy.text)")
    }
}
