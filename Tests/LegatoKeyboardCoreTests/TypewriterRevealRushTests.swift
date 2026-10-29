import Foundation
import Testing
@testable import LegatoKeyboardCore

/// The reveal's rush mode: while edits wait behind it, it drains at least eight times faster and is done within
/// `TypewriterReveal.rushLimitMs` of rushing.
@Suite struct TypewriterRevealRushTests {
    private let long = String(repeating: "word ", count: 80) // 400 characters

    private struct Rig {
        var reveal = TypewriterReveal()
        var field = ""
        var cursor: AppliedCursor?

        mutating func feed(_ state: HostState, elapsedMs: Double = 0, rush: Bool) {
            let plan = reveal.plan(
                state: state, cursor: cursor, contextBefore: field, documentID: "doc-A", animated: true,
                elapsedMs: elapsedMs, rush: rush)
            for op in plan.ops {
                switch op {
                case .deleteBackward(let count): field.removeLast(min(count, field.count))
                case .insert(let text): field += text
                }
            }
            cursor = plan.cursor
        }
    }

    @Test func aRushingTickRevealsAtLeastEightTimesWhatANormalTickDoes() {
        let state = hostState(committed: long)
        var normal = Rig(), rushed = Rig()
        normal.feed(state, rush: false)
        rushed.feed(state, rush: true)
        normal.feed(state, elapsedMs: 10, rush: false)
        rushed.feed(state, elapsedMs: 10, rush: true)
        #expect(normal.field.count > 0)
        #expect(rushed.field.count >= 8 * normal.field.count)
        #expect(long.hasPrefix(rushed.field))
    }

    @Test func aRushIsDoneWithinTheLimit() {
        let state = hostState(committed: String(repeating: long, count: 3))
        var rig = Rig()
        rig.feed(state, rush: true)
        var elapsed = 0.0
        while rig.reveal.needsTicks, elapsed < 1000 {
            rig.feed(state, elapsedMs: 5, rush: true)
            elapsed += 5
        }
        #expect(rig.field == state.committed)
        #expect(elapsed <= TypewriterReveal.rushLimitMs)
        #expect(TypewriterReveal.rushLimitMs <= 150)
        #expect(TypewriterReveal.rushFactor >= 8)
    }

    @Test func withoutRushTheRevealDrainsAsBefore() {
        let state = hostState(committed: long)
        var unrushed = Rig()
        var reveal = TypewriterReveal()
        var field = ""
        var cursor: AppliedCursor?
        func legacy(_ elapsedMs: Double) {
            let plan = reveal.plan(
                state: state, cursor: cursor, contextBefore: field, documentID: "doc-A", animated: true, elapsedMs: elapsedMs)
            for op in plan.ops {
                if case .insert(let text) = op { field += text }
            }
            cursor = plan.cursor
        }
        legacy(0)
        unrushed.feed(state, rush: false)
        for _ in 0..<5 {
            legacy(33)
            unrushed.feed(state, elapsedMs: 33, rush: false)
            #expect(unrushed.field == field)
        }
    }

    @Test func aRushThatEndsFallsBackToTheNormalPace() {
        let state = hostState(committed: long)
        var rig = Rig()
        rig.feed(state, rush: true)
        rig.feed(state, elapsedMs: 10, rush: true)
        let afterRush = rig.field.count
        let pending = long.count - afterRush
        rig.feed(state, elapsedMs: 10, rush: false)
        // A normal tick reveals the share of what is pending that fits the drain window.
        #expect(rig.field.count - afterRush == Int((Double(pending) * 10 / TypewriterDrain.windowMs).rounded(.up)))
    }
}
