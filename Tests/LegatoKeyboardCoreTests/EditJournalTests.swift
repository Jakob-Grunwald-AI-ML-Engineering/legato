import Foundation
import Testing
@testable import LegatoKeyboardCore

/// Replays an edit journal (a device's `edit-journal.jsonl`) against `FieldQueue`: the reports it recorded, the user's
/// input and the items enqueued, at their recorded times. `run` gives the ops the queue sends now next to the ops the
/// device sent; `simulate` drives a `FakeField` seeded from the first report with the same input instead, for
/// invariant checks. Paste a pulled journal into a test with `EditJournal.entries(_:)` to turn a report into a case.
enum JournalReplay {
    struct Result {
        var sent: [ShadowOp] = []
        var recorded: [ShadowOp] = []
        var events: [FieldQueue.Event] = []
    }

    static func run(_ entries: [EditJournal.Entry], config: FieldQueue.Config = .init()) -> Result {
        var queue = FieldQueue(config: config)
        var result = Result()
        var lastStep: Double?
        for entry in entries {
            switch entry.kind {
            case .field, .reset: queue = FieldQueue(config: config); lastStep = nil
            case .input: if let input = entry.input { queue.enqueue(input) }
            case .edit: if let edit = entry.edit { queue.enqueue(edit, user: entry.user ?? false) }
            case .live: if let snapshot = entry.snapshot { queue.enqueue(snapshot) }
            case .step:
                guard let report = entry.report else { continue }
                let action = queue.step(report: report, elapsedMs: lastStep.map { entry.t - $0 } ?? 0)
                lastStep = entry.t
                result.events += queue.drainEvents()
                if case .send(let op) = action { result.sent.append(op) }
            case .sent: if let op = entry.op?.op, entry.detail != "behind" { result.recorded.append(op) }
            default: break
            }
        }
        return result
    }

    /// The journal's input against a fake field that starts as its first report showed the field.
    static func simulate(_ entries: [EditJournal.Entry], configure: (inout FakeField) -> Void = { _ in }) -> QueueRig {
        let first = entries.first { $0.report != nil }?.report ?? .init(before: "")
        var field = FakeField(first.before + (first.selected ?? "") + first.after, caret: first.before.count)
        configure(&field)
        var rig = QueueRig(field, config: .init(animated: true))
        let start = entries.first?.t ?? 0
        for entry in entries {
            while rig.clockMs < entry.t - start { rig.tick() }
            switch entry.kind {
            case .input: if let input = entry.input { rig.queue.enqueue(input) }
            case .edit: if let edit = entry.edit { rig.queue.enqueue(edit, user: entry.user ?? false) }
            case .live: if let snapshot = entry.snapshot { rig.queue.enqueue(snapshot) }
            default: break
            }
        }
        rig.drain()
        return rig
    }
}

/// Records a rig session the way the keyboard writes its journal.
private struct Recorder {
    var entries: [EditJournal.Entry] = []
    var lastReport: FieldQueue.Report?

    mutating func enqueue(_ rig: inout QueueRig, input: FieldQueue.Input) {
        var entry = EditJournal.Entry(t: rig.clockMs, kind: .input); entry.input = input
        entries.append(entry); rig.queue.enqueue(input)
    }
    mutating func enqueue(_ rig: inout QueueRig, snapshot: LiveDictationSnapshot) {
        var entry = EditJournal.Entry(t: rig.clockMs, kind: .live); entry.snapshot = snapshot
        entries.append(entry); rig.queue.enqueue(snapshot)
    }
    /// One keyboard step: the report, the queue's answer, the op carried out.
    mutating func step(_ rig: inout QueueRig, elapsed: Double) {
        rig.clockMs += elapsed
        rig.field.nowMs = rig.clockMs
        let report = rig.field.tick()
        var entry = EditJournal.Entry(t: rig.clockMs, kind: .step); entry.report = report
        let action = rig.queue.step(report: report, elapsedMs: elapsed)
        entries.append(entry)
        entries += EditJournal.entries(for: rig.queue.drainEvents(), t: rig.clockMs, field: "doc")
        if case .send(let op) = action { rig.field.apply(op) }
    }
}

@Suite struct EditJournalTests {
    @Test func aLineRoundTripsWithFullText() {
        var entry = EditJournal.Entry(t: 12.5, kind: .edit, field: "doc")
        entry.edit = FieldQueue.Edit(id: "e", kind: .magic, before: "I saw teh", after: " cat", target: "I saw the cat")
        entry.report = .init(before: "line\n", after: "👍 next", selected: nil)
        let data = EditJournal.line(entry)
        #expect(data.last == 0x0A)
        let back = EditJournal.entries(String(decoding: data, as: UTF8.self) + "not json\n")
        #expect(back == [entry])
    }

    @Test func aRecordedSessionReplaysToTheSameOps() {
        var rig = QueueRig(FakeField("Notes: "), config: .init(animated: true))
        var recorder = Recorder()
        recorder.entries.append(.init(t: 0, kind: .field, field: "doc"))
        recorder.enqueue(&rig, snapshot: snap(1, "hello wrld"))
        for _ in 0..<20 { recorder.step(&rig, elapsed: 33) }
        recorder.enqueue(&rig, snapshot: snap(2, "hello world and more"))
        recorder.enqueue(&rig, input: .insert("!"))
        for _ in 0..<60 { recorder.step(&rig, elapsed: 33) }
        // Through the file format and back.
        let text = recorder.entries.map { String(decoding: EditJournal.line($0), as: UTF8.self) }.joined()
        let replay = JournalReplay.run(EditJournal.entries(text), config: .init(animated: true))
        #expect(!replay.recorded.isEmpty)
        #expect(replay.sent == replay.recorded)
        // The same input against a fresh fake field keeps the user's key and ends idle.
        let simulated = JournalReplay.simulate(EditJournal.entries(text))
        #expect(simulated.field.string.contains("!"))
        #expect(simulated.queue.isIdle)
    }
}
