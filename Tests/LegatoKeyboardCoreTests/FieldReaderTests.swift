import Testing
@testable import LegatoKeyboardCore

/// A field whose windows are small and ragged, like the hosts' (`documentContextBeforeInput` cut at varying sizes).
@MainActor private final class WindowField: FieldWindowProxy {
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
            let field = WindowField(text, cursor: 300, sizes: [70])
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
        let field = WindowField("Original text")
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
        let uikit = WindowField(text, sizes: [80])
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
        let plain = WindowField(blank, sizes: [30])
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
        let field = WindowField("Hello Anna, the meeting moved to Thursday. Can you make it?")
        let result = try await FieldReader(settleMilliseconds: 0).readUp(field, known: "", limit: .cap).get()
        #expect(result.text == "Hello Anna, the meeting moved to Thursday. Can you make it?")
        #expect(result.stop == .start)
        #expect(result.moreRemains == false)
        #expect(field.cursor == field.text.count)
    }

    @Test func stitchesRaggedWindowsWithEmojiAndAccents() async throws {
        let text = paragraphs(20)
        let field = WindowField(text, sizes: [87, 13, 118, 40, 547, 9])
        field.staleReads = 1
        let result = try await FieldReader(cap: 10_000, settleMilliseconds: 0).readUp(field, known: "", limit: .cap).get()
        #expect(result.text == text)
        #expect(result.stop == .start)
        #expect(field.cursor == field.text.count)
        #expect(result.rereads > 0, "A stale read is read again until two reads agree")
    }

    @Test func aWindowThatDoesNotTileFailsLoudlyAndTheCursorReturns() async throws {
        let text = paragraphs(6)
        let field = WindowField(text)
        // The second window position above the cursor reports a character short.
        let first = text.count - field.sizes[(text.count / 7) % field.sizes.count]
        field.brokenAt = [first]
        let result = await FieldReader(settleMilliseconds: 0).readUp(field, known: "", limit: .cap)
        guard case .failure(let failure) = result else { Issue.record("expected a failure, got \(result)"); return }
        guard case .stitch = failure else { Issue.record("expected a stitch failure, got \(failure)"); return }
        #expect(failure.isLasting)
        #expect(field.cursor == text.count, "The cursor goes back even when the read fails")
        // Windows at the cursor that a move does not start from (Safari's hidden selection): the first move fails.
        let hidden = WindowField(text)
        hidden.brokenAt = [text.count]
        let lost = await FieldReader(settleMilliseconds: 0).readUp(hidden, known: "", limit: .cap)
        #expect(lost == .failure(.firstMove))
    }

    @Test func capEndsAtALineStartAndSaysMoreRemains() async throws {
        let field = WindowField(paragraphs(60))
        let result = try await FieldReader(settleMilliseconds: 0).readUp(field, known: "", limit: .cap).get()
        #expect(result.stop == .cap)
        #expect(result.moreRemains)
        #expect(result.text.count <= FieldReader.defaultCap)
        #expect(result.text.hasPrefix("Paragraph "), "A capped read starts at a paragraph")
        #expect(paragraphs(60).hasSuffix(result.text))
    }

    @Test func readMoreExtendsByOneBlockFromWhatWasRead() async throws {
        let text = paragraphs(40)
        let field = WindowField(text)
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
        let field = WindowField("Something else entirely is before the cursor now.")
        let result = await FieldReader(settleMilliseconds: 0).readUp(field, known: "the text read earlier", limit: .block)
        #expect(result == .failure(.changed))
    }

    @Test func stopsAtTheNearestQuoteHeaderOrSignature() async throws {
        let mail = "Hi Max,\nthanks for the notes.\n\nOn Mon, 3 Nov 2026 at 10:12, Anna <anna@example.com> wrote:\n> Here are the notes.\n> Best, Anna\nI agree with all of it."
        let field = WindowField(mail)
        let result = try await FieldReader(settleMilliseconds: 0).readUp(field, known: "", limit: .cap).get()
        #expect(result.text == "I agree with all of it.")
        #expect(result.stop == .quote)
        #expect(result.moreRemains)
    }

    @Test func readsDownFromTheCursorToTheFieldsEndAndReturns() async throws {
        let text = paragraphs(8)
        let field = WindowField(text, cursor: 0)
        field.staleReads = 1
        let known = String(text.prefix(65))
        let result = try await FieldReader(settleMilliseconds: 0).readDown(field, known: known, room: 10_000).get()
        #expect(result.text == text)
        #expect(result.stop == .start && !result.moreRemains, "The field's end")
        #expect(field.cursor == 0)
        let mid = text.count / 2
        let middle = WindowField(text, cursor: mid)
        let rest = try await FieldReader(settleMilliseconds: 0).readDown(middle, known: "", room: 10_000).get()
        #expect(rest.text == String(text.dropFirst(mid)) && middle.cursor == mid)
    }

    @Test func readingDownStopsAtTheRoomOrAQuoteBelow() async throws {
        let text = paragraphs(30)
        let capped = try await FieldReader(settleMilliseconds: 0).readDown(WindowField(text, cursor: 0), known: "", room: 1000).get()
        #expect(capped.stop == .cap && capped.moreRemains)
        #expect(capped.text.count <= 1000 && text.hasPrefix(capped.text) && text.dropFirst(capped.text.count).hasPrefix("\n"),
                "A capped read down ends at a line end")
        let mail = "Sounds good, see you then.\nJo\n\nOn Mon, 3 Nov 2026 at 10:12, Anna <anna@example.com> wrote:\n> Shall we meet at nine?\n"
        let quoted = try await FieldReader(settleMilliseconds: 0).readDown(WindowField(mail, cursor: 0), known: "", room: 3000).get()
        #expect(quoted.text == "Sounds good, see you then.\nJo\n\n" && quoted.stop == .quote && quoted.moreRemains)
        let changed = await FieldReader(settleMilliseconds: 0).readDown(WindowField(mail, cursor: 0), known: "Something else", room: 3000)
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


@MainActor private final class StaleEmptyWindows: FieldWindowProxy {
    var refreshed = false
    var cancelled = false
    var moves: [Int] = []
    var windowBefore: String { refreshed ? "Keep this closing." : "" }
    var windowAfter: String { "" }
    var isCancelled: Bool { cancelled }
    func move(by units: Int) { moves.append(units) }
    func pause(milliseconds: Int) async { refreshed = true }
}

@MainActor @Suite struct FieldContextRefreshTests {
    @Test func staleEmptyContextRefreshesWithoutMovingToAnUnknownPosition() async throws {
        let proxy = StaleEmptyWindows()
        let refreshed = await FieldReader.refreshedWindow(proxy, settleMilliseconds: Int(FieldQueue.moveSettleMs))
        let window = try #require(refreshed)
        #expect(proxy.moves == [0], "Never probe backward/forward from an unknown empty context")
        #expect(window.before == "Keep this closing.")
        let insertion = DictationTypist.prepare("Please bring the charts", contextBefore: window.before, capitalization: .none)
        #expect(insertion == " Please bring the charts")
    }

    @Test func cancelledRefreshDoesNotProbeOrReturnAnEmptyInsertionAnchor() async {
        let proxy = StaleEmptyWindows()
        proxy.cancelled = true
        let refreshed = await FieldReader.refreshedWindow(proxy, settleMilliseconds: Int(FieldQueue.moveSettleMs))
        #expect(refreshed == nil)
        #expect(proxy.moves.isEmpty)
    }
}
