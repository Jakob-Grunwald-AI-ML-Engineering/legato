import Foundation
import Testing
@testable import LegatoKeyboardCore

/// The user types while staged units enter the field (phone UAT round 3): a key lands before or after a whole unit, never
/// inside it; the separator follows the text the unit meets when it starts; nothing is typed twice.
@Suite(.serialized) struct StagedTypingDuringDeliveryTests {
    /// The controller's loop in miniature: units are queued one at a time as staged edits, in order.
    private struct Session {
        var rig: QueueRig
        var take = StagedDictation()
        var editID: String?
        var delivered: [String] = []
        var pressed: [String] = []

        init(_ field: FakeField, units: [String], config: FieldQueue.Config = .init(chunkEntrance: true)) {
            rig = QueueRig(field, config: config)
            rig.tick()
            let segments = units.enumerated().map { LiveSegment(id: $0.offset, text: $0.element, cleaned: true, final: true, ready: true) }
            take.receive(.init(runID: "t", version: 1, segments: segments, complete: true, staged: true))
        }

        private var before: String { String(rig.field.text[..<rig.field.caret]) }

        mutating func drive() {
            if let id = editID {
                let result = rig.events.compactMap { event -> String? in
                    if case .applied(let applied, _, let text) = event.event, applied == id { return text.result }
                    return nil
                }.first
                if let result {
                    editID = nil
                    take.delivered(take.inFlight ?? 0, typed: result)
                    delivered.append(result)
                } else if rig.drops.contains(where: { $0.id == id }) {
                    editID = nil
                    _ = take.hold()
                }
            }
            guard editID == nil, !take.held, let unit = take.nextReady else { return }
            take.begin(unit.id, typed: unit.text)
            var edit = FieldQueue.Edit(kind: .typist, target: unit.text, atCursor: true, requiresVerifiedInsertion: true, isSpeech: true)
            edit.unit = .init(text: unit.text, capitalization: .sentences, contextFallback: take.context(proxyBefore: before))
            editID = edit.id
            rig.queue.enqueue(edit, user: false)
        }

        /// Runs `ms`, pressing `keys` one every `every` ms from `startMs`.
        mutating func run(ms: Double, keys: String = "", every: Double = 0, startMs: Double = 0) {
            var pending = Array(keys)
            var nextKey = rig.clockMs + startMs
            let end = rig.clockMs + ms
            while rig.clockMs < end {
                rig.tick()
                drive()
                if !pending.isEmpty, rig.clockMs >= nextKey {
                    let key = String(pending.removeFirst())
                    rig.queue.enqueue(.insert(key))
                    pressed.append(key)
                    nextKey += every
                }
            }
        }

        var text: String { rig.field.string }
    }

    private static let units = ["It is simple.", "Then it is coffee and cake on the terrace.", "The plan holds if the weather does."]

    /// The field with every delivered unit taken out whole: what is left is the start and the person's keys, in order.
    private func withoutUnits(_ session: Session) -> String? {
        var rest = session.text
        for typed in session.delivered {
            guard let range = rest.range(of: typed.trimmingCharacters(in: .whitespaces)), rest.components(separatedBy: typed.trimmingCharacters(in: .whitespaces)).count == 2 else { return nil }
            rest.removeSubrange(range)
        }
        return rest.filter { !$0.isWhitespace }
    }

    @Test(arguments: [FakeField.Host.notes, .safari, .whatsApp], [true, false])
    func keysTypedDuringDeliveryLandOutsideWholeUnits(host: FakeField.Host, entrance: Bool) {
        var session = Session(FakeField.host(host, "Notes: "), units: Self.units, config: .init(chunkEntrance: entrance))
        session.run(ms: 12_000, keys: "abcdefgh", every: 250)
        #expect(session.delivered.count == 3, "\(session.text.debugDescription)")
        // Each unit once and whole, the keys in the order typed, none inside a unit.
        #expect(withoutUnits(session) == "Notes:abcdefgh", "\(session.text.debugDescription)")
    }

    @Test(arguments: [FakeField.Host.notes, .safari, .whatsApp])
    func theCaretStaysWhereTheKeysLeftItAfterAUnit(host: FakeField.Host) {
        var session = Session(FakeField.host(host, "Notes: "), units: ["It is simple."])
        // A key as the unit's check is still out (Notes confirms after a callback).
        session.run(ms: 300, keys: "ab", every: 40, startMs: 150)
        session.run(ms: 2_000)
        #expect(session.text == "Notes: It is simple.ab", "\(session.text.debugDescription)")
        #expect(session.rig.queue.userCursor == session.rig.field.caret)
    }

    @Test(arguments: [FakeField.Host.notes, .safari, .whatsApp])
    func theSeparatorFollowsWhatTheKeysTypedBeforeTheUnitStarted(host: FakeField.Host) {
        // Keys go first; the proxy may show nothing before the caret after a move (blind), so the queue's own text decides.
        var session = Session(FakeField.host(host, "Later."), units: ["Then it is coffee."])
        session.take.receive(.init(runID: "t", version: 2, segments: [.init(id: 0, text: "Then it is coffee.", cleaned: true, final: true, ready: false)], complete: true, staged: true))
        session.run(ms: 1_000, keys: "Err", every: 60)
        session.take.receive(.init(runID: "t", version: 3, segments: [.init(id: 0, text: "Then it is coffee.", cleaned: true, final: true, ready: true)], complete: true, staged: true))
        session.run(ms: 3_000)
        #expect(session.text == "Later.Err Then it is coffee.", "\(session.text.debugDescription)")
    }

    @Test func aTrailingSpaceTheUserTypedIsNotDoubled() {
        var session = Session(FakeField.host(.notes, "Later."), units: ["then coffee."])
        session.take.receive(.init(runID: "t", version: 2, segments: [.init(id: 0, text: "then coffee.", cleaned: true, final: true, ready: false)], complete: true, staged: true))
        session.run(ms: 600, keys: " ", every: 60)
        session.take.receive(.init(runID: "t", version: 3, segments: [.init(id: 0, text: "then coffee.", cleaned: true, final: true, ready: true)], complete: true, staged: true))
        session.run(ms: 3_000)
        #expect(session.text == "Later. Then coffee.", "\(session.text.debugDescription)")
    }

    @Test(arguments: [FakeField.Host.notes, .safari, .whatsApp], 0..<12)
    func keysAtAnyMomentNeverSplitOrRepeatAUnit(host: FakeField.Host, seed: Int) {
        var generator = SeededGenerator(seed: UInt64(seed + 1))
        var session = Session(FakeField.host(host, "Notes: "), units: Self.units, config: .init(chunkEntrance: seed % 2 == 0))
        let letters = Array("abcdefghijkl")
        var count = 0
        for _ in 0..<12 {
            session.run(ms: Double.random(in: 20...600, using: &generator), keys: String(letters[count]), every: 0)
            count += 1
        }
        session.run(ms: 8_000)
        let typed = String(letters[..<count])
        #expect(session.delivered.count == 3, "\(session.text.debugDescription)")
        #expect(withoutUnits(session) == "Notes:" + typed, "\(session.text.debugDescription)")
    }

    // MARK: Insert at the end of a note, a unit the check lost

    @Test(arguments: [FakeField.Host.notes, .safari, .whatsApp])
    func aKeptTextInsertGoesInAtTheEndOfANoteAfterATapThatLeftTheCaretThere(host: FakeField.Host) {
        var rig = QueueRig(FakeField.host(host, "Then it is coffee and cake on the terrace."))
        rig.run(ms: 200)
        // The tap in the empty area below the text: the caret stays at the end, the host calls back with the same report.
        rig.queue.observe(rig.field.current, callback: .selection, hasText: true, elapsedSinceLastStepMs: 2_000)
        #expect(rig.queue.hasUnverifiedInput)
        var edit = FieldQueue.Edit(kind: .typist, target: "the plan holds", atCursor: true, requiresVerifiedInsertion: true, isSpeech: true)
        edit.unit = .init(text: "the plan holds", capitalization: .sentences, contextFallback: "")
        rig.queue.enqueue(edit, user: false)
        let drained = rig.drain(); #expect(drained)
        #expect(rig.field.string == "Then it is coffee and cake on the terrace. The plan holds")
        #expect(rig.applied.contains(edit.id) && rig.drops.isEmpty)
    }

    @Test func anInsertTheQueueCannotVerifyIsHeldUnlessItIsMarkedAsSpeech() {
        var rig = QueueRig(FakeField.host(.notes, "Done."))
        rig.run(ms: 200)
        rig.queue.observe(rig.field.current, callback: .selection, hasText: true, elapsedSinceLastStepMs: 2_000)
        let edit = FieldQueue.Edit(kind: .typist, target: " More.", atCursor: true, requiresVerifiedInsertion: true)
        rig.queue.enqueue(edit, user: false)
        rig.run(ms: 600)
        #expect(rig.field.string == "Done.", "Held, never typed blind")
    }

    private func drop(_ text: String, partial: String? = nil, issued: Bool) -> FieldQueue.Drop {
        .init(id: "e", runID: nil, kind: .typist, reason: .changed, text: text, partial: partial, issuedMutation: issued)
    }

    @Test func aUnitWhoseCheckFailedButWhoseWordsAreInTheFieldCountsAsDelivered() {
        let report = FieldQueue.Report(before: "Later.Err Then it is coffee.", after: "")
        #expect(StagedDictation.landed(drop(" Then it is coffee.", issued: true), report: report), "The window shows the words")
        #expect(StagedDictation.landed(drop(" Then it is coffee.", partial: " Then it is coffee.", issued: true), report: .init(before: "")))
        #expect(StagedDictation.landed(drop(" Then it is coffee.", issued: true), report: .init(before: "Later.", after: " Then it is coffee. More")), "After the caret too")
    }

    @Test func aUnitThatMayNotHaveLandedIsNeverCountedAsDelivered() {
        let report = FieldQueue.Report(before: "Later.")
        #expect(!StagedDictation.landed(drop(" Then it is coffee.", issued: true), report: report), "Not shown: kept, not retyped")
        #expect(!StagedDictation.landed(drop(" Then it is coffee.", partial: " Then it", issued: true), report: report))
        #expect(!StagedDictation.landed(drop(" Then it is coffee.", issued: false), report: .init(before: "Then it is coffee.")), "Nothing was written")
    }
}
