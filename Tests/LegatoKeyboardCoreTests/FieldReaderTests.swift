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
        #expect(r.plan.ops.contains { if case .move = $0 { return true }; return false }, "Edited word by word, not retyped")
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
