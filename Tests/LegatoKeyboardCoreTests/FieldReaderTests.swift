import Testing
@testable import LegatoKeyboardCore

/// A field whose windows are small and ragged, like the hosts' (`documentContextBeforeInput` cut at varying sizes).
@MainActor private final class FakeField: FieldWindowProxy {
    var text: [Character]
    /// Cursor, in characters.
    var cursor: Int
    var sizes: [Int]
    private var reads = 0
    /// Windows before these positions drop one character (a host whose windows do not tile there).
    var brokenAt: Set<Int> = []
    /// The first reads at a position return a stale window this many times (the host is still updating).
    var staleReads = 0
    private var stale = 0
    var moves = 0

    init(_ text: String, cursor: Int? = nil, sizes: [Int] = [87, 65, 118, 40, 73]) {
        self.text = Array(text); self.cursor = cursor ?? text.count; self.sizes = sizes
    }
    private var size: Int { sizes[(cursor / 7) % sizes.count] }
    var windowBefore: String {
        if stale > 0 { stale -= 1; return "stale" }
        let window = String(text[max(0, cursor - size)..<cursor])
        if brokenAt.contains(cursor), window.count > 2 { var w = Array(window); w.remove(at: 1); return String(w) }
        return window
    }
    var windowAfter: String { String(text[cursor..<min(text.count, cursor + 65)]) }
    func move(by units: Int) {
        moves += 1
        var remaining = abs(units)
        while remaining > 0 {
            if units > 0 { guard cursor < text.count else { break }; remaining -= String(text[cursor]).utf16.count; cursor += 1 }
            else { guard cursor > 0 else { break }; remaining -= String(text[cursor - 1]).utf16.count; cursor -= 1 }
        }
        stale = staleReads
    }
    func pause(milliseconds: Int) async {}
}

private func paragraphs(_ count: Int) -> String {
    (0..<count).map { "Paragraph \($0) talks about the harbour, the tide and the next crossing to the island. 🌊 Später mehr." }
        .joined(separator: "\n")
}

@MainActor @Suite struct FieldReaderTests {
    @Test func readsAShortFieldToItsStartAndReturnsTheCursor() async throws {
        let field = FakeField("Hello Anna, the meeting moved to Thursday. Can you make it?")
        let result = try await FieldReader(settleMilliseconds: 0).readUp(field, known: "", limit: .cap).get()
        #expect(result.text == "Hello Anna, the meeting moved to Thursday. Can you make it?")
        #expect(result.stop == .start)
        #expect(result.moreRemains == false)
        #expect(field.cursor == field.text.count)
    }

    @Test func stitchesRaggedWindowsWithEmojiAndAccents() async throws {
        let text = paragraphs(20)
        let field = FakeField(text, sizes: [87, 13, 118, 40, 547, 9])
        field.staleReads = 1
        let result = try await FieldReader(cap: 10_000, settleMilliseconds: 0).readUp(field, known: "", limit: .cap).get()
        #expect(result.text == text)
        #expect(result.stop == .start)
        #expect(field.cursor == field.text.count)
        #expect(result.rereads > 0, "A stale read is read again until two reads agree")
    }

    @Test func aWindowThatDoesNotTileFailsLoudlyAndTheCursorReturns() async throws {
        let text = paragraphs(6)
        let field = FakeField(text)
        // The second window position above the cursor reports a character short.
        let first = text.count - field.sizes[(text.count / 7) % field.sizes.count]
        field.brokenAt = [first]
        let result = await FieldReader(settleMilliseconds: 0).readUp(field, known: "", limit: .cap)
        guard case .failure(let failure) = result else { Issue.record("expected a failure, got \(result)"); return }
        guard case .stitch = failure else { Issue.record("expected a stitch failure, got \(failure)"); return }
        #expect(field.cursor == text.count, "The cursor goes back even when the read fails")
    }

    @Test func capEndsAtALineStartAndSaysMoreRemains() async throws {
        let field = FakeField(paragraphs(60))
        let result = try await FieldReader(settleMilliseconds: 0).readUp(field, known: "", limit: .cap).get()
        #expect(result.stop == .cap)
        #expect(result.moreRemains)
        #expect(result.text.count <= FieldReader.defaultCap)
        #expect(result.text.hasPrefix("Paragraph "), "A capped read starts at a paragraph")
        #expect(paragraphs(60).hasSuffix(result.text))
    }

    @Test func readMoreExtendsByOneBlockFromWhatWasRead() async throws {
        let text = paragraphs(40)
        let field = FakeField(text)
        let reader = FieldReader(settleMilliseconds: 0)
        let first = try await reader.readUp(field, known: "", limit: .block).get()
        #expect(first.stop == .block && first.moreRemains)
        #expect(first.added <= FieldReader.blockLimit && first.added >= FieldReader.blockMinimum)
        let moves = field.moves
        let second = try await reader.readUp(field, known: first.text, limit: .block).get()
        #expect(second.text.hasSuffix(first.text) && second.text.count > first.text.count)
        #expect(text.hasSuffix(second.text))
        #expect(second.text.hasPrefix("Paragraph "))
        #expect(field.cursor == text.count)
        #expect(field.moves > moves + 1, "The known text is jumped over, then read upward")
    }

    @Test func knownTextThatNoLongerMatchesTheFieldIsRefused() async {
        let field = FakeField("Something else entirely is before the cursor now.")
        let result = await FieldReader(settleMilliseconds: 0).readUp(field, known: "the text read earlier", limit: .block)
        #expect(result == .failure(.changed))
    }

    @Test func stopsAtTheNearestQuoteHeaderOrSignature() async throws {
        let mail = "Hi Max,\nthanks for the notes.\n\nOn Mon, 3 Nov 2026 at 10:12, Anna <anna@example.com> wrote:\n> Here are the notes.\n> Best, Anna\nI agree with all of it."
        let field = FakeField(mail)
        let result = try await FieldReader(settleMilliseconds: 0).readUp(field, known: "", limit: .cap).get()
        #expect(result.text == "I agree with all of it.")
        #expect(result.stop == .quote)
        #expect(result.moreRemains)
    }

    @Test func structuralStopsAreFoundByLine() {
        func below(_ text: String) -> String? {
            FieldReader.structuralStop(in: text, atFieldStart: true).map { String(text[$0.index...]) }
        }
        #expect(below("Reply here\n-----Original Message-----\nFrom: x\nmy text") == "From: x\nmy text")
        #expect(below("Am 03.11.2026 um 10:12 schrieb Anna:\nGerne, bis dann") == "Gerne, bis dann")
        #expect(below("Body\n-- \nJakob\nmore") == "Jakob\nmore")
        #expect(FieldReader.structuralStop(in: "Body\n-- \nJakob", atFieldStart: true)?.kind == .signature)
        #expect(below("No structure at all.\nJust lines.\nAnd more") == nil)
        #expect(below("On my way home I wrote: nothing\nreally") == nil, "Not a header: does not end with a colon")
        #expect(FieldReader.structuralStop(in: "> quoted", atFieldStart: true) == nil, "The cursor's own line is never a stop")
        #expect(FieldReader.structuralStop(in: "ote:\nOn Monday Anna wrote:\nmine", atFieldStart: false)?.kind == .quote)
        #expect(FieldReader.structuralStop(in: "On Monday Anna wrote:\nmine", atFieldStart: false) == nil,
                "A first line that may be cut off does not count")
    }
}

@Suite struct ScopedEditPlannerTests {
    private func land(_ edit: ScopedEdit, field: String, cursor: Int, windowBefore: String? = nil, windowAfter: String? = nil) throws -> (text: String, cursor: Int, plan: ScopedEditPlanner.Plan) {
        let chars = Array(field)
        let before = windowBefore ?? String(chars[max(0, cursor - 60)..<cursor])
        let after = windowAfter ?? String(chars[cursor..<min(chars.count, cursor + 60)])
        let plan = try ScopedEditPlanner.plan(edit, windowBefore: before, windowAfter: after, selected: nil).get()
        let utf16Cursor = String(chars[..<cursor]).utf16.count
        let result = ShadowEditPlanner.simulate(ops: plan.ops, shadow: field, cursor: utf16Cursor)
        return (result.text, result.cursor, plan)
    }

    @Test func rewritesOnlyTheScopeAboveTheCursorAndLeavesTheRestAlone() throws {
        let head = String(repeating: "Earlier text that was never shown to the model. ", count: 4)
        let scope = "hey can you come tomorrow we start at nine"
        let field = head + scope
        let edit = ScopedEdit(instructionID: "i", documentID: nil, before: scope, after: "",
                              target: "Hello, could you come tomorrow? We start at nine.")
        let r = try land(edit, field: field, cursor: field.count)
        #expect(r.text == head + "Hello, could you come tomorrow? We start at nine.")
        #expect(r.cursor == r.text.utf16.count)
        // Changes three words or fewer apart join: one replace inside the scope, the earlier text never deleted.
        #expect(r.plan.ops.count <= 4)
        #expect(r.plan.ops.allSatisfy { if case .deleteBackward(let n) = $0 { return n <= scope.count }; return true })
    }

    @Test func scopeAroundTheCursorKeepsTheCursorInPlace() throws {
        let field = "Intro.\nfirst half second half\nOutro."
        let cursor = "Intro.\nfirst half ".count
        let edit = ScopedEdit(instructionID: "i", documentID: nil, before: "first half ", after: "second half",
                              target: "First half, second half.")
        let r = try land(edit, field: field, cursor: cursor)
        #expect(r.text == "Intro.\nFirst half, second half.\nOutro.")
        #expect(r.cursor == "Intro.\n".utf16.count + r.plan.cursor)
        #expect(r.plan.targetBefore.hasPrefix("First half") && "First half, second half.".hasPrefix(r.plan.targetBefore))
    }

    @Test func refusesWhenTheFieldNoLongerShowsTheScope() throws {
        let edit = ScopedEdit(instructionID: "i", documentID: nil, before: "the scope text", after: "", target: "The scope text.")
        #expect(ScopedEditPlanner.plan(edit, windowBefore: "the scope text and a typed word", windowAfter: "", selected: nil) == .failure(.changed))
        #expect(ScopedEditPlanner.plan(edit, windowBefore: "", windowAfter: "", selected: nil) == .failure(.changed))
        #expect(ScopedEditPlanner.plan(edit, windowBefore: "scope text", windowAfter: "", selected: nil) != .failure(.changed),
                "A window cut short by the host still agrees")
        let selection = ScopedEdit(instructionID: "i", documentID: nil, before: "", after: "", selected: "old words", target: "new words")
        #expect(ScopedEditPlanner.plan(selection, windowBefore: "", windowAfter: "", selected: "other") == .failure(.selectionChanged))
        #expect(try ScopedEditPlanner.plan(selection, windowBefore: "", windowAfter: "", selected: "old words").get().ops == [.insert("new words")])
    }

    @Test func undoRestoresTheScopeFromWhereTheCursorEnded() throws {
        let scope = "we meet at nine"
        let field = "Note: " + scope
        let edit = ScopedEdit(instructionID: "i", documentID: nil, before: scope, after: "", target: "We meet at 9:00.")
        let landed = try land(edit, field: field, cursor: field.count)
        let undo = ScopedEditPlanner.undo(of: edit, cursor: landed.plan.cursor)
        let back = try land(undo, field: landed.text, cursor: landed.text.count)
        #expect(back.text == field)
    }

    private func inserted(_ plan: ScopedEditPlanner.Plan) -> Int {
        plan.ops.reduce(0) { if case .insert(let text) = $1 { return $0 + text.count }; return $0 }
    }

    @Test func aRewriteIsOneReplaceAndSoIsItsUndo() throws {
        let scope = "So The Plan For The Garden Is Pretty Simple. First We Move Two Big Pots, Then We Fix The Gate."
        let target = "The plan for the garden is quite simple. First, we move two large pots, then we repair the gate."
        let field = "Notes: " + scope
        let edit = ScopedEdit(instructionID: "i", documentID: nil, before: scope, after: "", target: target)
        let landed = try land(edit, field: field, cursor: field.count)
        #expect(landed.text == "Notes: " + target && landed.cursor == landed.text.utf16.count)
        #expect(landed.plan.ops.count <= 4, "Mostly rewritten: one delete and one insert, not word by word")
        let back = try land(ScopedEditPlanner.undo(of: edit, cursor: landed.plan.cursor), field: landed.text, cursor: landed.text.count)
        #expect(back.text == field && back.plan.ops.count <= 4)
    }

    @Test func nearbyChangesJoinAndASmallFixStaysWordLevel() throws {
        let scope = "We meet on monday at the old office. Bring the notes from last week and the slides. Lunch is on us."
        let target = "We meet on Monday at the new office. Bring the notes from last week and the slides. Lunch is on us."
        let edit = ScopedEdit(instructionID: "i", documentID: nil, before: scope, after: "", target: target)
        let r = try land(edit, field: scope, cursor: scope.count)
        #expect(r.text == target)
        // "monday" and "old" are three words apart: one replace of "monday at the old", nothing else retyped.
        #expect(r.plan.ops.filter { if case .insert = $0 { return true }; return false }.count == 1)
        #expect(inserted(r.plan) == "Monday at the new".count)
        let fine = ShadowEditPlanner.plan(shadow: scope, cursor: scope.utf16.count, target: target)
        #expect(r.plan.ops.count < fine.ops.count)
    }

    @Test func sessionSpanFollowsRunsAndEditsAndEndsWithTheUser() {
        var span = SessionSpan()
        span.track(runID: "a", anchor: "", region: "Hello there")
        #expect(span.text == "Hello there" && span.startsField)
        span.track(runID: "a", anchor: "", region: "Hello there, Anna.")
        span.edited(before: "Hello there, Anna.", newBefore: "Dear Anna,")
        #expect(span.text == "Dear Anna,")
        span.track(runID: "a", anchor: "Dear Anna,", region: " See you soon.")
        #expect(span.text == "Dear Anna, See you soon.", "The run goes on after the edit: still one session")
        // The field was emptied behind the keyboard's back: a new region does not continue the old session.
        span.edited(before: " See you soon.", newBefore: " See you soon.")
        span.track(runID: "c", anchor: "", region: "Fresh start")
        #expect(span.text == "Fresh start" && span.startsField)
        span.track(runID: "b", anchor: "x", region: "")
        span.broken()
        span.track(runID: "b", anchor: "Dear Anna, See you soon. typed", region: "New words")
        #expect(span.text == "New words" && !span.startsField)
    }
}

/// A host that shows each op only `lag` reports later (Safari's proxy): the queue must not send the next op before then.
private struct LaggingField {
    var text: String
    var cursor: Int
    var lag: Int
    private var pending: [(ShadowOp, Int)] = []
    private(set) var reported: (before: String, after: String)
    init(text: String, cursor: Int, lag: Int) {
        self.text = text; self.cursor = cursor; self.lag = lag
        let units = Array(text.utf16)
        reported = (String(decoding: units[..<cursor], as: UTF16.self), String(decoding: units[cursor...], as: UTF16.self))
    }
    var inFlight: Int { pending.count }
    mutating func perform(_ op: ShadowOp) { pending.append((op, lag)) }
    /// One report later; `lose` drops the op in flight (a host that never shows it).
    mutating func tick(lose: Bool = false) {
        if lose { pending.removeAll() }
        pending = pending.map { ($0.0, $0.1 - 1) }
        while let first = pending.first, first.1 <= 0 {
            (text, cursor) = ShadowEditPlanner.simulate(ops: [first.0], shadow: text, cursor: cursor)
            pending.removeFirst()
        }
        let units = Array(text.utf16)
        reported = (String(decoding: units[..<cursor], as: UTF16.self), String(decoding: units[cursor...], as: UTF16.self))
    }
}

@Suite struct ScopedEditQueueTests {
    private let head = "Earlier text. "
    private let scope = "hey can you send the file we need it by nine"
    private var edit: ScopedEdit {
        ScopedEdit(instructionID: "i", documentID: nil, before: scope, after: "", target: "Could you send the file? We need it by 9:00.")
    }

    /// Runs the queue against the field until it finishes; `loseAfter` loses the op sent after that many confirmed ones.
    private func run(_ edit: ScopedEdit, on field: inout LaggingField, loseAfter: Int? = nil) throws -> (ScopedEditQueue.Action, sent: Int) {
        let plan = try ScopedEditPlanner.plan(edit, windowBefore: field.reported.before, windowAfter: field.reported.after, selected: nil).get()
        var queue = ScopedEditQueue(edit, plan: plan, windowBefore: field.reported.before)
        var sent = 0
        for _ in 0..<2000 {
            let action = queue.step(reportedBefore: field.reported.before, reportedAfter: field.reported.after, hasSelection: false, elapsedMs: 33)
            switch action {
            case .send(let op):
                #expect(field.inFlight == 0, "Never a second op before the field showed the first")
                field.perform(op); sent += 1
            case .wait: break
            case .done, .stopped: return (action, sent)
            }
            field.tick(lose: loseAfter.map { sent == $0 + 1 } ?? false)
        }
        Issue.record("The queue never finished"); return (.wait, sent)
    }

    @Test func aLaggingFieldGetsOneConfirmedOpAtATimeAndEndsRight() throws {
        var field = LaggingField(text: head + scope, cursor: (head + scope).utf16.count, lag: 3)
        let (outcome, sent) = try run(edit, on: &field)
        #expect(outcome == .done && sent > 1)
        #expect(field.text == head + edit.target)
    }

    @Test func aLostOpStopsTheEditAndUndoStillRestoresTheScope() throws {
        let original = head + scope
        var field = LaggingField(text: original, cursor: original.utf16.count, lag: 2)
        let half = try ScopedEditPlanner.plan(edit, windowBefore: original, windowAfter: "", selected: nil).get().ops.count / 2
        let (outcome, sent) = try run(edit, on: &field, loseAfter: half)
        guard case .stopped(let partial?) = outcome else { Issue.record("Stopped with a known state, got \(outcome)"); return }
        #expect(sent == half + 1, "Nothing goes out after the op the field did not show")
        #expect(field.text == head + partial.text, "The partial text is what the field shows")
        #expect(partial.text != scope && partial.text != edit.target)
        // The app's undo of a stopped edit: from what landed back to the scope, through the same queue.
        let stranded = ScopedEdit(instructionID: "i", documentID: nil, before: scope, after: "", target: partial.text)
        let (back, _) = try run(ScopedEditPlanner.undo(of: stranded, cursor: partial.cursor), on: &field)
        #expect(back == .done && field.text == original)
    }

    @Test func aFieldThatShowsNeitherStateIsUnknown() throws {
        let plan = try ScopedEditPlanner.plan(edit, windowBefore: scope, windowAfter: "", selected: nil).get()
        var queue = ScopedEditQueue(edit, plan: plan, windowBefore: scope)
        guard case .send = queue.step(reportedBefore: scope, reportedAfter: "", hasSelection: false, elapsedMs: 0) else { Issue.record("First op"); return }
        var outcome = ScopedEditQueue.Action.wait
        while outcome == .wait { outcome = queue.step(reportedBefore: "the user typed this", reportedAfter: "", hasSelection: false, elapsedMs: 100) }
        #expect(outcome == .stopped(nil))
        #expect(queue.waits == 1)
    }
}
