import Testing
@testable import LegatoKeyboardCore

/// A Live run as the keyboard meets it: partials, finals one phrase at a time, and a rolling pass's revision
/// of the whole text so far arriving while the next phrase is being spoken (and revealed).
private struct FlowRig {
    var reveal = TypewriterReveal()
    var field: String
    var cursor: AppliedCursor?
    /// The field as the proxy reports it lags one apply behind (`documentContextBeforeInput` after an insert).
    var lagging: Bool
    private var reported: String

    init(field: String = "", lagging: Bool) {
        self.field = field
        self.lagging = lagging
        self.reported = field
    }

    mutating func feed(_ state: HostState, elapsedMs: Double = 0) {
        let context = lagging ? reported : field
        let plan = reveal.plan(
            state: state, cursor: cursor, contextBefore: context, documentID: "doc-A", animated: true,
            elapsedMs: elapsedMs)
        reported = field
        for op in plan.ops {
            switch op {
            case .deleteBackward(let count): field.removeLast(min(count, field.count))
            case .insert(let text): field += text
            }
        }
        cursor = plan.cursor
    }

    mutating func ticks(_ state: HostState, _ count: Int) {
        for _ in 0..<count { feed(state, elapsedMs: 33) }
    }

    mutating func drain(_ state: HostState) {
        var n = 0
        while reveal.needsTicks, n < 400 {
            feed(state, elapsedMs: 33)
            n += 1
        }
    }
}

private func live(
    _ committed: String, _ volatile: String = "", revision: HostRevision? = nil, phase: HostPhase = .listening
) -> HostState {
    var host = hostState(phase: phase, committed: committed, volatile: volatile)
    host.delivery = .live
    host.revision = revision
    return host
}

@Suite struct TypewriterRevealLiveFlowTests {
    private let s1 = "hallo wie gehts"
    private let s2 = " ich wollte fragen ob du morgen zeit hast"
    private let r1 = HostRevision(n: 1, start: 0, raw: "hallo wie gehts", text: "Hallo, wie gehts?")
    /// The next pass covers both phrases.
    private var r2: HostRevision {
        HostRevision(
            n: 2, start: 0, raw: "hallo wie gehts ich wollte fragen ob du morgen zeit hast",
            text: "Hallo, wie gehts? Ich wollte fragen, ob du morgen Zeit hast.")
    }

    private func run(lagging: Bool, prefix: String = "") -> (rig: FlowRig, midRun: String) {
        var rig = FlowRig(field: prefix, lagging: lagging)
        rig.feed(live("", "hallo"))
        rig.ticks(live("", "hallo"), 3)
        rig.feed(live("", "hallo wie"))
        rig.ticks(live("", "hallo wie"), 3)
        rig.feed(live(s1))
        rig.ticks(live(s1), 4)
        rig.feed(live(s1, " ich"))
        rig.ticks(live(s1, " ich"), 2)
        rig.feed(live(s1, " ich wollte"))
        rig.ticks(live(s1, " ich wollte"), 2)
        // Segment 1's revision arrives while segment 2 is spoken.
        rig.feed(live(s1, " ich wollte", revision: r1))
        rig.ticks(live(s1, " ich wollte", revision: r1), 3)
        rig.feed(live(s1, " ich wollte fragen ob", revision: r1))
        rig.ticks(live(s1, " ich wollte fragen ob", revision: r1), 3)
        let midRun = rig.field
        rig.feed(live(s1 + s2, revision: r1))
        rig.ticks(live(s1 + s2, revision: r1), 4)
        rig.feed(live(s1 + s2, revision: r2))
        rig.drain(live(s1 + s2, revision: r2))
        let final = live(s1 + s2, revision: r2, phase: .idle)
        rig.feed(final)
        rig.drain(final)
        return (rig, midRun)
    }

    @Test(arguments: [false, true])
    func eachPhraseIsReplacedByItsCleanedTextWhileTheNextIsSpoken(lagging: Bool) {
        let (rig, midRun) = run(lagging: lagging)
        #expect(midRun.hasPrefix("Hallo, wie gehts? ich"), "phrase 1 is cleaned while phrase 2 is spoken")
        #expect(rig.field == "Hallo, wie gehts? Ich wollte fragen, ob du morgen Zeit hast.")
        #expect(rig.cursor?.revisionSkipped != true)
        #expect(rig.cursor?.finalApplied == true)
    }

    @Test(arguments: [false, true])
    func aPhraseAfterTextAlreadyInTheFieldIsReplacedToo(lagging: Bool) {
        let (rig, _) = run(lagging: lagging, prefix: "Moin.")
        #expect(rig.field == "Moin. Hallo, wie gehts? Ich wollte fragen, ob du morgen Zeit hast.")
        #expect(rig.cursor?.revisionSkipped != true)
    }
}
