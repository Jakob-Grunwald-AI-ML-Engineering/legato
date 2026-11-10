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
    var cancelAfterMoves: Int?
    var isCancelled: Bool { cancelAfterMoves.map { moves >= $0 } ?? false }

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

/// Safari's `contenteditable` (measured on the simulator): blocks separated by one unit; a window before the cursor starts
/// at a word start, and one that starts right at a block's start begins with "\n " (the boundary, plus a space the text
/// does not hold); the window after the cursor stops at its block's end.
@MainActor private final class BlockField: FieldWindowProxy {
    var text: [Character]
    var cursor: Int
    var sizes: [Int]
    init(_ text: String, cursor: Int? = nil, sizes: [Int]) { self.text = Array(text); self.cursor = cursor ?? text.count; self.sizes = sizes }
    private var size: Int { sizes[cursor % sizes.count] }
    var windowBefore: String {
        var start = max(0, cursor - size)
        while start > 0, start < cursor, !text[start - 1].isWhitespace { start += 1 }
        let window = String(text[start..<cursor])
        return start > 0 && text[start - 1] == "\n" ? "\n " + window : window
    }
    var windowAfter: String {
        let end = text[cursor...].firstIndex(of: "\n") ?? text.count
        return String(text[cursor..<min(end, cursor + 100)])
    }
    func move(by units: Int) { cursor = min(text.count, max(0, cursor + units)) }
    func pause(milliseconds: Int) async {}
}

/// Safari's `contenteditable` with `<p>` paragraphs (measured): a paragraph break shows as "\n\n" in the windows but
/// the cursor moves over it as one unit. `text` holds one "\n" per break, as the field counts.
@MainActor private final class ParagraphField: FieldWindowProxy {
    var text: [Character]
    var cursor: Int
    var size: Int
    init(_ text: String, cursor: Int? = nil, size: Int) { self.text = Array(text); self.cursor = cursor ?? text.count; self.size = size }
    private func shown(_ part: ArraySlice<Character>) -> String { String(part).replacingOccurrences(of: "\n", with: "\n\n") }
    var windowBefore: String { String(shown(text[max(0, cursor - size)..<cursor]).suffix(size)) }
    var windowAfter: String { String(shown(text[cursor..<min(text.count, cursor + size)]).prefix(size)) }
    func move(by units: Int) { cursor = min(text.count, max(0, cursor + units)) }
    func pause(milliseconds: Int) async {}
}

/// Safari's text fields (measured): the cursor moves one unit per character, an emoji included.
@MainActor private final class CharacterField: FieldWindowProxy {
    var text: [Character]
    var cursor: Int
    var size: Int
    init(_ text: String, cursor: Int? = nil, size: Int) { self.text = Array(text); self.cursor = cursor ?? text.count; self.size = size }
    var windowBefore: String { String(text[max(0, cursor - size)..<cursor]) }
    var windowAfter: String { String(text[cursor..<min(text.count, cursor + size)]) }
    func move(by units: Int) { cursor = min(text.count, max(0, cursor + units)) }
    func pause(milliseconds: Int) async {}
}

@MainActor @Suite struct FieldReaderTests {
    @Test func cancellationRestoresBothDirectionsBeforeReturning() async {
        let text = String(repeating: "Safe original text around the insertion point. ", count: 20)
        for upward in [true, false] {
            let field = FakeField(text, cursor: 300, sizes: [70])
            field.cancelAfterMoves = 1
            let reader = FieldReader(settleMilliseconds: 0)
            let result = upward
                ? await reader.readUp(field, known: "", limit: .cap)
                : await reader.readDown(field, known: "", room: 10_000)
            guard case .failure(.cancelled) = result else { Issue.record("Expected restored cancellation, got \(result)"); continue }
            #expect(field.cursor == 300)
            #expect(field.moves == 2, "One exploratory move and its verified restoration")
        }
    }

    @Test func anAlreadyCancelledReadNeverMoves() async {
        let field = FakeField("Original text")
        field.cancelAfterMoves = 0
        let result = await FieldReader(settleMilliseconds: 0).readUp(field, known: "text", limit: .cap)
        guard case .failure(.cancelled) = result else { Issue.record("Expected cancellation"); return }
        #expect(field.moves == 0)
    }
    @Test func learnsThatAnEmojiIsOneUnitAndReadsOverIt() async throws {
        let scope = " Hey, could you take a look at the release notes? Thanks so much! Don't forget the screenshots 😊 one more thing, the demo is at noon."
        let text = "Hi team, the release is on friday. Thanks, Jakob" + scope
        // The emoji is beyond the 40-character window: the jump over the known scope finds it out.
        let far = CharacterField(text, size: 40)
        let above = try await FieldReader(settleMilliseconds: 0).readUp(far, known: scope, limit: .block).get()
        #expect(above.text == text && above.movesByCharacters == true && far.cursor == text.count)
        // In view: two small moves next to it tell.
        let near = CharacterField(text, size: 80)
        let read = try await FieldReader(settleMilliseconds: 0).readUp(near, known: "", limit: .cap).get()
        #expect(read.text == text && read.movesByCharacters == true && near.cursor == text.count)
        // UIKit's fields move by UTF-16 units: the same text reads the same, as two units.
        let uikit = FakeField(text, sizes: [80])
        let plain = try await FieldReader(settleMilliseconds: 0).readUp(uikit, known: "", limit: .cap).get()
        #expect(plain.text == text && plain.movesByCharacters == false)
    }

    @Test func readsParagraphsShownAsDoubledBreaksAsTheFieldCountsThem() async throws {
        let text = "First paragraph here about cats.\nSecond paragraph is about dogs and is rather long winded for what it says.\nThird paragraph about birds."
        for size in [62, 40, 100] {
            let middle = 60
            let field = ParagraphField(text, cursor: middle, size: size)
            let upResult = await FieldReader(settleMilliseconds: 0).readUp(field, known: "", limit: .cap)
            guard case .success(let up) = upResult else { Issue.record("up \(size) \(upResult) cursor=\(field.cursor)"); continue }
            #expect(up.text == String(text.prefix(middle)) && up.collapsesBreaks == true && field.cursor == middle, "size \(size)")
            let downResult = await FieldReader(settleMilliseconds: 0).readDown(field, known: "", room: 10_000)
            guard case .success(let down) = downResult else { Issue.record("down \(size) \(downResult) cursor=\(field.cursor)"); continue }
            #expect(down.text == String(text.dropFirst(middle)) && field.cursor == middle, "size \(size)")
        }
        // A text area's blank line is two real line breaks: read as it shows.
        let blank = "Dear Anna,\n\nthe plan is ready and the boat is fixed.\n\nBest, Jakob"
        let plain = FakeField(blank, sizes: [30])
        let read = try await FieldReader(settleMilliseconds: 0).readUp(plain, known: "", limit: .cap).get()
        #expect(read.text == blank && read.collapsesBreaks == false)
    }

    @Test func readsBlocksWhoseWindowsStartWithABoundaryArtifact() async throws {
        let text = "The garden plan is simple and we start on Saturday morning.\nWe need to move the two big pots away from the fence first, and then we can fix the gate.\n\nAfter that it is coffee and cake on the terrace."
        #expect(BlockField(text, sizes: [48]).windowBefore.hasPrefix("\n After"), "The host's window at the end, as measured")
        for sizes in [[48], [49], [50, 100, 55], [12, 30, 7], [200]] {
            let field = BlockField(text, sizes: sizes)
            let result = try await FieldReader(settleMilliseconds: 0).readUp(field, known: "", limit: .cap).get()
            #expect(result.text == text, "sizes \(sizes)")
            #expect(result.stop == .start && field.cursor == text.count)
        }
        // Down from the middle of a block, across blocks, to the field's end (whose window starts with "\n ").
        let middle = BlockField(text, cursor: 80, sizes: [48])
        let rest = try await FieldReader(settleMilliseconds: 0).readDown(middle, known: "", room: 10_000).get()
        #expect(rest.text == String(text.dropFirst(80)) && rest.stop == .start && middle.cursor == 80)
        // Down from the first block's end, across blocks, to the field's end.
        let start = BlockField(text, cursor: 59, sizes: [50, 100, 55])
        let below = try await FieldReader(settleMilliseconds: 0).readDown(start, known: "", room: 10_000).get()
        #expect(below.text == String(text.dropFirst(59)) && below.stop == .start && start.cursor == 59)
        // The echo of an edit and the scope check look past the artifact.
        #expect(OwnEditEcho.isSame(expected: "the gate.\n\nAfter that it is", reported: "\n After that it is"))
        #expect(!OwnEditEcho.isSame(expected: "the gate.\nBefore that it is", reported: "\n After that it is"))
    }

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
        #expect(failure.isLasting)
        #expect(field.cursor == text.count, "The cursor goes back even when the read fails")
        // Windows at the cursor that a move does not start from (Safari's hidden selection): the first move fails.
        let hidden = FakeField(text)
        hidden.brokenAt = [text.count]
        let lost = await FieldReader(settleMilliseconds: 0).readUp(hidden, known: "", limit: .cap)
        #expect(lost == .failure(.firstMove))
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

    @Test func readsDownFromTheCursorToTheFieldsEndAndReturns() async throws {
        let text = paragraphs(8)
        let field = FakeField(text, cursor: 0)
        field.staleReads = 1
        let known = String(text.prefix(65))
        let result = try await FieldReader(settleMilliseconds: 0).readDown(field, known: known, room: 10_000).get()
        #expect(result.text == text)
        #expect(result.stop == .start && !result.moreRemains, "The field's end")
        #expect(field.cursor == 0)
        let mid = text.count / 2
        let middle = FakeField(text, cursor: mid)
        let rest = try await FieldReader(settleMilliseconds: 0).readDown(middle, known: "", room: 10_000).get()
        #expect(rest.text == String(text.dropFirst(mid)) && middle.cursor == mid)
    }

    @Test func readingDownStopsAtTheRoomOrAQuoteBelow() async throws {
        let text = paragraphs(30)
        let capped = try await FieldReader(settleMilliseconds: 0).readDown(FakeField(text, cursor: 0), known: "", room: 1000).get()
        #expect(capped.stop == .cap && capped.moreRemains)
        #expect(capped.text.count <= 1000 && text.hasPrefix(capped.text) && text.dropFirst(capped.text.count).hasPrefix("\n"),
                "A capped read down ends at a line end")
        let mail = "Sounds good, see you then.\nJo\n\nOn Mon, 3 Nov 2026 at 10:12, Anna <anna@example.com> wrote:\n> Shall we meet at nine?\n"
        let quoted = try await FieldReader(settleMilliseconds: 0).readDown(FakeField(mail, cursor: 0), known: "", room: 3000).get()
        #expect(quoted.text == "Sounds good, see you then.\nJo\n\n" && quoted.stop == .quote && quoted.moreRemains)
        let changed = await FieldReader(settleMilliseconds: 0).readDown(FakeField(mail, cursor: 0), known: "Something else", room: 3000)
        #expect(changed == .failure(.changed))
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

private extension String {
    /// Characters before the UTF-16 offset.
    func utf16Offset(toCharacter offset: Int) -> Int { String(decoding: Array(utf16.prefix(offset)), as: UTF16.self).count }
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
        // Every mutation touches a single grapheme inside the scope; earlier text is never deleted.
        #expect(r.plan.ops.allSatisfy { if case .deleteBackward(let n) = $0 { return n == 1 }; if case .insert(let text) = $0 { return text.count == 1 }; return true })
        #expect(r.plan.ops.allSatisfy { if case .deleteBackward(let n) = $0 { return n <= scope.count }; return true })
    }

    @Test func isolatedSpacesAndEmojiEditsLeaveEveryOtherCharacterUntouched() throws {
        for (old, new, deleted, insertedCount) in [
            ("We  sail 👨‍👩‍👧 tomorrow.", "We sail 👨‍👩‍👧 tomorrow.", 1, 0),
            ("We sail👨‍👩‍👧 tomorrow.", "We sail 👨‍👩‍👧 tomorrow.", 0, 1),
            ("The weather is clear.", "The whether is clear.", 1, 1)
        ] {
            let edit = ScopedEdit(instructionID: "i", documentID: nil, before: old, after: "", target: new)
            let result = try land(edit, field: old, cursor: old.count, windowBefore: old)
            #expect(result.text == new)
            #expect(result.plan.ops.reduce(0) { if case .deleteBackward(let n) = $1 { return $0 + n }; return $0 } == deleted)
            #expect(inserted(result.plan) == insertedCount)
            #expect(result.plan.ops.allSatisfy { if case .insert(let text) = $0 { return text.count == 1 }; if case .deleteBackward(let n) = $0 { return n == 1 }; return true })
        }
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
        #expect(ScopedEditPlanner.plan(selection, windowBefore: "", windowAfter: "", selected: "old words") == .failure(.selectionNeedsCursor))
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

    @Test func aRewriteAndItsUndoBothUseIndividualCharacterEdits() throws {
        let scope = "So The Plan For The Garden Is Pretty Simple. First We Move Two Big Pots, Then We Fix The Gate."
        let target = "The plan for the garden is quite simple. First, we move two large pots, then we repair the gate."
        let field = "Notes: " + scope
        let edit = ScopedEdit(instructionID: "i", documentID: nil, before: scope, after: "", target: target)
        let landed = try land(edit, field: field, cursor: field.count, windowBefore: field)
        #expect(landed.text == "Notes: " + target && landed.cursor == landed.text.utf16.count)
        #expect(landed.plan.ops.allSatisfy { if case .deleteBackward(let n) = $0 { return n == 1 }; if case .insert(let text) = $0 { return text.count == 1 }; return true })
        let back = try land(ScopedEditPlanner.undo(of: edit, cursor: landed.plan.cursor), field: landed.text, cursor: landed.text.count, windowBefore: landed.text)
        #expect(back.text == field)
    }

    @Test func nearbyChangesPreserveTheUnchangedTextBetweenThem() throws {
        // Separate changes far from the cursor must still preserve the text between them.
        let tail = String(repeating: " Then we go through the plan together.", count: 12)
        let scope = "We meet on monday at the old office. Bring the notes from last week and the slides. Lunch is on us." + tail
        let target = "We meet on Monday at the new office. Bring the notes from last week and the slides. Lunch is on us." + tail
        let edit = ScopedEdit(instructionID: "i", documentID: nil, before: scope, after: "", target: target)
        let r = try land(edit, field: scope, cursor: scope.count, windowBefore: scope)
        #expect(r.text == target)
        // The unchanged phrase between these edits is never removed or inserted again.
        #expect(inserted(r.plan) == 4)
        #expect(r.plan.ops.allSatisfy { if case .deleteBackward(let n) = $0 { return n == 1 }; if case .insert(let text) = $0 { return text.count == 1 }; return true })
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
    /// A page that re-renders its text area: a move shows for a moment, then the caret is back where it was.
    var resetsCaret = false
    /// Characters reported before the cursor (a web view's short window).
    var window = Int.max
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
            if resetsCaret, case .move = first.0 { pending.removeFirst(); continue }
            (text, cursor) = ShadowEditPlanner.simulate(ops: [first.0], shadow: text, cursor: cursor)
            pending.removeFirst()
        }
        let units = Array(text.utf16)
        reported = (String(String(decoding: units[..<cursor], as: UTF16.self).suffix(window)), String(decoding: units[cursor...], as: UTF16.self))
    }
}

nonisolated(unsafe) private var lastQueue: ScopedEditQueue?

@Suite(.serialized) struct ScopedEditQueueTests {
    private let head = "Earlier text. "
    private let scope = "hey can you send the file we need it by nine"
    private var edit: ScopedEdit {
        ScopedEdit(instructionID: "i", documentID: nil, before: scope, after: "", target: "Could you send the file? We need it by 9:00.")
    }

    @Test func aLongRewriteKeepsEvidenceInSentenceBoundedHostWindows() throws {
        let original = "We Are Planning A Quiet Weekend At The Harbor. On Friday I Will Collect The Charts, Check The Batteries, And Make Sure The Cabin Is Ready For Two Guests. Please Keep The Morning Free Because The Weather May Change. On Saturday We Can Leave After Breakfast And Sail Toward The Small Island. Bring Coffee, Warm Clothes, And Enough Food For Everyone. If The Wind Becomes Too Strong, We Will Stay In Port And Spend The Afternoon Repairing The Cupboard Instead. There Is No Reason To Hurry; I Would Rather Arrive Rested And Enjoy The Conversation."
        let edit = ScopedEdit(instructionID: "i", documentID: "field", before: original, after: "", target: original.uppercased())
        // Safari's actual native proxy reported only the current sentence. Emptying it hid all earlier text even
        // though that text still existed, so a coarse whole-draft delete could no longer be confirmed safely.
        func report(_ text: [Character], _ cursor: Int) -> (String, String) {
            let start = text[..<cursor].lastIndex(of: ".").map { min(cursor, $0 + 2) } ?? 0
            let end = text[cursor...].firstIndex(of: ".").map { $0 + 1 } ?? text.count
            return (String(text[start..<cursor]), String(text[cursor..<end]))
        }
        var text = Array(original), cursor = original.count
        // At the actual caret after the final period, UIKit still reports the final sentence.
        func window() -> (String, String) {
            if cursor == text.count, text.last == "." {
                let start = text[..<max(0, cursor - 1)].lastIndex(of: ".").map { $0 + 2 } ?? 0
                return (String(text[start..<cursor]), "")
            }
            return report(text, cursor)
        }
        let initial = window()
        let plan = try ScopedEditPlanner.plan(edit, windowBefore: initial.0, windowAfter: initial.1, selected: nil).get()
        var queue = ScopedEditQueue(edit, plan: plan, windowBefore: initial.0)
        var outcome = ScopedEditQueue.Action.wait
        for _ in 0..<10_000 {
            let shown = window()
            outcome = queue.step(reportedBefore: shown.0, reportedAfter: shown.1, hasSelection: false, elapsedMs: 33)
            if outcome == .wait { continue }
            guard case .send(let op) = outcome else { break }
            let next = ShadowEditPlanner.simulate(ops: [op], shadow: String(text), cursor: String(text[..<cursor]).utf16.count)
            text = Array(next.text); cursor = next.cursor
        }
        #expect(outcome == .done)
        #expect(String(text) == edit.target)
        #expect(cursor == text.count)
    }

    @Test func anEmptyBeforeWindowRequiresASubstantialUniqueMatchingAfterAnchor() {
        for (after, report) in [("Repeated anchor text.", "Repeated anchor text."), (".", "."),
                                ("A unique remaining suffix.", "Different remaining suffix.")] {
            let before = "Repeated anchor text. X"
            let edit = ScopedEdit(instructionID: "i", documentID: "field", before: before, after: after,
                                  target: String(before.dropLast()) + "Y" + after)
            let plan = ScopedEditPlanner.Plan(ops: [.deleteBackward(1), .insert("Y")], cursor: before.utf16.count,
                                              targetBefore: String(before.dropLast()) + "Y")
            var queue = ScopedEditQueue(edit, plan: plan, windowBefore: before)
            let first = queue.step(reportedBefore: before, reportedAfter: after, hasSelection: false, elapsedMs: 0)
            #expect(first == .send(.deleteBackward(1)))
            let stopped = queue.step(reportedBefore: "", reportedAfter: report, hasSelection: false, elapsedMs: 1_000)
            #expect(stopped == .stopped(nil), "A repeated, punctuation-only, or mismatching anchor cannot authorize the insert")
        }
    }

    /// Runs the queue against the field until it finishes; `loseAfter` loses the op sent after that many confirmed ones.
    private func run(_ edit: ScopedEdit, on field: inout LaggingField, loseAfter: Int? = nil, avoidsMoves: Bool = false,
                     moves: UnsafeMutablePointer<Int>? = nil, plannedWith windows: (String, String)? = nil) throws -> (ScopedEditQueue.Action, sent: Int) {
        let (wb, wa) = windows ?? (field.reported.before, field.reported.after)
        let plan = try ScopedEditPlanner.plan(edit, windowBefore: wb, windowAfter: wa, selected: nil).get()
        var queue = ScopedEditQueue(edit, plan: plan, windowBefore: wb, avoidsMoves: avoidsMoves)
        var sent = 0
        defer { lastQueue = queue }
        for _ in 0..<2000 {
            let action = queue.step(reportedBefore: field.reported.before, reportedAfter: field.reported.after, hasSelection: false, elapsedMs: 33)
            switch action {
            case .send(let op):
                #expect(field.inFlight == 0, "Never a second op before the field showed the first")
                if case .move = op { moves?.pointee += 1 }
                field.perform(op); sent += 1
            case .wait: break
            case .done, .stopped: return (action, sent)
            }
            field.tick(lose: loseAfter.map { sent == $0 + 1 } ?? false)
        }
        Issue.record("The queue never finished"); return (.wait, sent)
    }

    @Test func aPageThatPutsItsCaretBackStopsWithoutRetyping() throws {
        // The first interior change needs a move; the page puts that caret back.
        let tail = String(repeating: " Then we go through the plan together.", count: 12)
        let scope = "we meet on monday at the office and bring the slides from last week" + tail
        let target = "We meet on Tuesday at the office and bring the slides from last week" + tail
        let edit = ScopedEdit(instructionID: "i", documentID: nil, before: scope, after: "", target: target)
        var field = LaggingField(text: head + scope, cursor: (head + scope).utf16.count, lag: 1)
        field.resetsCaret = true
        let (outcome, _) = try run(edit, on: &field)
        #expect(outcome == .stopped(nil) && field.text == head + scope)
        #expect(lastQueue?.caretReset == true && lastQueue?.retypes == false)
        // Once the host is known to reset moves, an interior edit refuses before issuing anything.
        var moves = 0
        let (again, count) = try run(edit, on: &field, avoidsMoves: true, moves: &moves)
        #expect(again == .stopped(.init(text: scope, cursor: scope.utf16.count)))
        #expect(count == 0 && moves == 0 && field.text == head + scope)
    }

    @Test func aChangeNearTheCursorStillUsesMinimalCharacterEdits() throws {
        let scope = "we meet at nine and bring the slides"
        let edit = ScopedEdit(instructionID: "i", documentID: nil, before: scope, after: "", target: "We meet at 9:00 and bring the slides.")
        let plan = try ScopedEditPlanner.plan(edit, windowBefore: scope, windowAfter: "", selected: nil).get()
        #expect(plan.cursor == edit.target.utf16.count)
        #expect(plan.ops.allSatisfy { if case .deleteBackward(let n) = $0 { return n == 1 }; if case .insert(let text) = $0 { return text.count == 1 }; return true })
    }

    @Test func unseenExternalChangesStopFurtherWritesWithoutBlindRollback() throws {
        // The scope as read; since then another keyboard typed "TYPED" into it, beyond the host's 20-character window.
        let scope = "the release is on friday please review the page before then"
        let field = "the release is on friday TYPED please review the page before then"
        let edit = ScopedEdit(instructionID: "i", documentID: nil, before: scope, after: "", target: "The release is Friday. Review the page before then.")
        var lagging = LaggingField(text: field, cursor: field.utf16.count, lag: 1)
        lagging.window = 20; lagging.tick()
        let (outcome, sent) = try run(edit, on: &lagging)
        #expect(lagging.text.contains("TYPED"), "The user's unseen change must survive")
        #expect(outcome == .stopped(nil), "The final outcome is unknown, never an invented restored state")
        #expect(sent > 0, "Confirmed nonoverlapping word edits may precede discovery of the unseen change")
        // Text typed at the cursor since the read: nothing goes out at all.
        let typed = scope + " ok"
        var atCursor = LaggingField(text: typed, cursor: typed.utf16.count, lag: 1)
        atCursor.window = 20; atCursor.tick()
        let (refused, none) = try run(edit, on: &atCursor, plannedWith: (String(scope.suffix(20)), ""))
        #expect(refused == .stopped(.init(text: scope, cursor: scope.utf16.count)) && none == 0 && atCursor.text == typed)
    }

    @Test func aScopeLongerThanTheWindowKeepsEveryEditPinned() throws {
        // A session of dictation longer than the host's 60-character window, edited in place.
        let head = "Hi team, the release is on friday. Thanks, Jakob"
        let scope = " Hey, could you please check the release notes before you start? Thanks so much! And remember to update the screenshots"
        let target = " Hey there! Could you check the release notes and update the screenshots before you start? Thanks so much!"
        let edit = ScopedEdit(instructionID: "i", documentID: nil, before: scope, after: "", target: target)
        var field = LaggingField(text: head + scope, cursor: (head + scope).utf16.count, lag: 1)
        field.window = 60; field.tick()
        let (outcome, _) = try run(edit, on: &field)
        #expect(outcome == .done && field.text == head + target)
    }

    @Test func aFieldThatMovesByCharactersGetsMovesInCharacters() throws {
        // A change before an emoji, far from the cursor: the plan moves over the emoji in UTF-16 units (two); this field
        // counts it as one, and the queue sends the move as such.
        let tail = String(repeating: " and we go through the plan together", count: 12)
        let scope = "we meet on monday 😊" + tail
        let edit = ScopedEdit(instructionID: "i", documentID: nil, before: scope, after: "", target: "We meet on Tuesday 😊" + tail)
        let plan = try ScopedEditPlanner.plan(edit, windowBefore: scope, windowAfter: "", selected: nil).get()
        #expect(plan.ops.contains { if case .move = $0 { return true }; return false })
        var queue = ScopedEditQueue(edit, plan: plan, windowBefore: scope, movesByCharacters: true)
        var field = Array(scope), cursor = field.count, outcome = ScopedEditQueue.Action.wait
        for _ in 0..<200 {
            outcome = queue.step(reportedBefore: String(field[..<cursor]), reportedAfter: String(field[cursor...]), hasSelection: false, elapsedMs: 33)
            guard case .send(let op) = outcome else { if outcome == .wait { continue }; break }
            switch op {
            case .move(let n): cursor = min(field.count, max(0, cursor + n))
            case .deleteBackward(let n): field.removeSubrange((cursor - n)..<cursor); cursor -= n
            case .insert(let t): field.insert(contentsOf: t, at: cursor); cursor += t.count
            }
        }
        #expect(outcome == .done && String(field) == edit.target && cursor == field.count)
    }

    @Test func withoutMovesAChangeAfterTheCursorIsNotMadeAtAll() throws {
        let edit = ScopedEdit(instructionID: "i", documentID: nil, before: "first half ", after: "second half", target: "First half, second half.")
        var field = LaggingField(text: "first half second half", cursor: "first half ".utf16.count, lag: 1)
        let (outcome, sent) = try run(edit, on: &field, avoidsMoves: true)
        #expect(outcome == .stopped(.init(text: "first half second half", cursor: "first half ".utf16.count)) && sent == 0)
        #expect(lastQueue?.needsMoves == true)
    }

    @Test func aBlockHostsBoundaryEchoStillPinsTheCursor() throws {
        // Safari's contenteditable: the window starts at the block's start with "\n "; the scope reaches into the block above.
        let text = Array("The plan is simple.\nWe need to move the pots first.")
        func report(_ chars: [Character], _ cursor: Int) -> (String, String) {
            let start = chars[..<cursor].lastIndex(of: "\n").map { $0 + 1 } ?? 0
            let end = chars[cursor...].firstIndex(of: "\n") ?? chars.count
            // At a block's very start the window reaches into the block above (measured); else it starts at the block.
            // An emptied block shows only its boundary.
            if cursor == start, start > 0, end == cursor { return ("\n ", "") }
            if cursor == start { return (String(chars[..<cursor]), String(chars[cursor..<end])) }
            return ((start > 0 ? "\n " : "") + String(chars[start..<cursor]), String(chars[cursor..<end]))
        }
        let (rb, ra) = report(text, text.count)
        #expect(RunShadow.confirms(expectedBefore: String(text), expectedAfter: "", reportedBefore: rb, reportedAfter: ra))
        #expect(!RunShadow.confirms(expectedBefore: String(text.dropLast(5)), expectedAfter: String(text.suffix(5)), reportedBefore: rb, reportedAfter: ra),
                "The echo pins the cursor at one place only")
        let edit = ScopedEdit(instructionID: "i", documentID: nil, before: String(text), after: "", target: "The plan is simple.\nFirst we move the pots.")
        let plan = try ScopedEditPlanner.plan(edit, windowBefore: rb, windowAfter: ra, selected: nil).get()
        var queue = ScopedEditQueue(edit, plan: plan, windowBefore: rb)
        var field = text, cursor = text.count, outcome = ScopedEditQueue.Action.wait
        for _ in 0..<100 {
            let (b, a) = report(field, cursor)
            outcome = queue.step(reportedBefore: b, reportedAfter: a, hasSelection: false, elapsedMs: 33)
            if outcome == .wait { continue }
            guard case .send(let op) = outcome else { break }
            let (t, c) = ShadowEditPlanner.simulate(ops: [op], shadow: String(field), cursor: String(field[..<cursor]).utf16.count)
            field = Array(t); cursor = String(t).utf16Offset(toCharacter: c)
        }
        #expect(outcome == .done && String(field) == edit.target, "\(outcome) \(String(field))")
    }

    @Test func aLaggingFieldGetsOneConfirmedOpAtATimeAndEndsRight() throws {
        var field = LaggingField(text: head + scope, cursor: (head + scope).utf16.count, lag: 3)
        let (outcome, sent) = try run(edit, on: &field)
        #expect(outcome == .done && sent > 1)
        #expect(field.text == head + edit.target)
    }

    @Test func anUnconfirmedOpStopsWithoutInventingAnUndoBaseline() throws {
        let original = head + scope
        var field = LaggingField(text: original, cursor: original.utf16.count, lag: 2)
        let half = try ScopedEditPlanner.plan(edit, windowBefore: original, windowAfter: "", selected: nil).get().ops.count / 2
        let (outcome, sent) = try run(edit, on: &field, loseAfter: half)
        #expect(outcome == .stopped(nil), "The queue cannot tell whether the last operation was dropped or delayed")
        #expect(sent == half + 1, "Nothing goes out after the op the field did not show")
        #expect(field.text != original && field.text != head + edit.target)
        #expect(lastQueue?.hasUnconfirmedOperation == true)
    }

    @Test func aFieldThatShowsNeitherStateIsUnknown() throws {
        let plan = try ScopedEditPlanner.plan(edit, windowBefore: scope, windowAfter: "", selected: nil).get()
        var queue = ScopedEditQueue(edit, plan: plan, windowBefore: scope)
        guard case .send = queue.step(reportedBefore: scope, reportedAfter: "", hasSelection: false, elapsedMs: 0) else { Issue.record("First op"); return }
        var outcome = ScopedEditQueue.Action.wait, sends: [ShadowOp] = []
        while true {
            outcome = queue.step(reportedBefore: "the user typed this", reportedAfter: "", hasSelection: false, elapsedMs: 100)
            if case .send(let op) = outcome { sends.append(op); continue }
            if outcome != .wait { break }
        }
        #expect(outcome == .stopped(nil))
        #expect(sends.isEmpty, "An uncertain delete must never trigger a blind insert rollback")
    }
}
