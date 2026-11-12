import Foundation
import Testing
@testable import LegatoKeyboardCore

/// Characters per second under Safari's measured timing, averaged over host seeds: dictation appends (idle and with a
/// backlog), a one-word fix mid-text and a 55-character Magic. `LEGATO_PACE_REPORT=1` prints the table.
@Suite struct FieldQueuePaceReport {
    private static let seeds: [UInt64] = Array(1...24)

    private struct Sample { var chars: Int; var landedMs: Double; var doneMs: Double }

    /// Ticks until the field holds `expected` (landed) and the queue is idle with the field settled (done).
    private func measure(_ rig: inout QueueRig, expected: String, chars: Int) -> Sample {
        let start = rig.clockMs
        var landed: Double?
        while rig.clockMs - start < 20_000 {
            rig.tick()
            if landed == nil, rig.field.string == expected { landed = rig.clockMs - start }
            if landed != nil, rig.queue.isIdle, !rig.queue.hasOpInFlight, rig.field.settled { break }
        }
        #expect(rig.field.string == expected)
        #expect(rig.field.reorders == 0 && rig.field.staleTriggers == 0)
        return Sample(chars: chars, landedMs: landed ?? .infinity, doneMs: rig.clockMs - start)
    }

    private func rig(_ text: String, seed: UInt64) -> QueueRig {
        var field = FakeField(text)
        field.hostDelays = true
        field.rng = SeededGenerator(seed: seed)
        return QueueRig(field, config: .init(animated: true))
    }

    private func append(_ added: String, seed: UInt64) -> Sample {
        var rig = rig("Note: ", seed: seed)
        rig.queue.enqueue(snap(1, "we need"))
        rig.drain()
        rig.run(ms: 200)
        rig.queue.enqueue(snap(2, "we need" + added))
        return measure(&rig, expected: "Note: we need" + added, chars: added.count)
    }

    private func wordFix(seed: UInt64) -> Sample {
        var rig = rig("", seed: seed)
        rig.queue.enqueue(snap(1, "I will meet you on Thursday at noon in the lobby"))
        rig.drain()
        rig.run(ms: 200)
        rig.queue.enqueue(snap(2, "I will meet you on Friday at noon in the lobby"))
        return measure(&rig, expected: "I will meet you on Friday at noon in the lobby", chars: "Friday".count)
    }

    private func magic(seed: UInt64) -> Sample {
        let sentence = "the meeting is at three pm tomorrow, we need the slides"
        var rig = rig(sentence, seed: seed)
        rig.run(ms: 200)
        rig.queue.enqueue(FieldQueue.Edit(kind: .magic, before: sentence, target: sentence.uppercased(), cursorAtEnd: false, paced: true))
        return measure(&rig, expected: sentence.uppercased(), chars: sentence.count)
    }

    private func line(_ name: String, _ samples: [Sample]) -> String {
        let landed = samples.map(\.landedMs).reduce(0, +) / Double(samples.count)
        let done = samples.map(\.doneMs).reduce(0, +) / Double(samples.count)
        let cps = Double(samples[0].chars) / (landed / 1_000)
        return String(format: "%-34@ %3d chars  landed %5.0f ms  done %5.0f ms  %5.1f chars/s", name as NSString, samples[0].chars, landed, done, cps)
    }

    @Test func charactersPerSecond() {
        let rows = [
            line("dictation append, idle", Self.seeds.map { append(" slides for", seed: $0) }),
            line("dictation append, backlog", Self.seeds.map { append(" slides for the meeting tomorrow at three and the budget", seed: $0) }),
            line("one-word fix mid-text", Self.seeds.map { wordFix(seed: $0) }),
            line("Magic, 55 characters", Self.seeds.map { magic(seed: $0) }),
        ]
        if ProcessInfo.processInfo.environment["LEGATO_PACE_REPORT"] == "1" { print(rows.joined(separator: "\n")) }
    }
}
