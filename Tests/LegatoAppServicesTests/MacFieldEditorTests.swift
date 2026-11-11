#if os(macOS)
import Foundation
import Testing
import LegatoKeyboardCore
import LegatoCore
import LegatoMac
@testable import LegatoAppServices

@MainActor private final class EditorTarget: TextTarget {
    var value: String
    var selection: UTF16Range
    var focused = true
    var readable = true
    var ignoreWrites = false
    var throwAfterWrite = false
    var normalizeTrailingNBSP = false
    var corruptPrefixAfterWrite = false
    var inPlace = true
    var editsInPlace: Bool { inPlace }
    var selections: [UTF16Range] = []
    var writes: [UTF16Range] = []
    init(_ value: String, _ selection: UTF16Range? = nil) {
        self.value = value; self.selection = selection ?? .init(location: value.utf16.count, length: 0)
    }
    func isFocused() -> Bool { focused }
    func selectedRange() throws -> UTF16Range { selection }
    func setSelectedRange(_ range: UTF16Range) throws { selections.append(range); selection = range }
    func textLength() throws -> Int { value.utf16.count }
    func text(in range: UTF16Range) throws -> String {
        guard readable, range.location >= 0, range.end <= value.utf16.count else { throw TextTargetReadError.unsupported }
        return (value as NSString).substring(with: NSRange(location: range.location, length: range.length))
    }
    func replace(_ range: UTF16Range, with text: String) throws {
        writes.append(range)
        guard !ignoreWrites else { return }
        value = (value as NSString).replacingCharacters(in: NSRange(location: range.location, length: range.length), with: text)
        if normalizeTrailingNBSP, range.length == 0, range.location > 0, !text.isEmpty,
           (value as NSString).substring(with: NSRange(location: range.location - 1, length: 1)) == "\u{00A0}" {
            value = (value as NSString).replacingCharacters(in: NSRange(location: range.location - 1, length: 1), with: " ")
        }
        if corruptPrefixAfterWrite, !value.isEmpty {
            value = (value as NSString).replacingCharacters(in: NSRange(location: 0, length: 1), with: "X")
        }
        selection = .init(location: range.location + text.utf16.count, length: 0)
        if throwAfterWrite { throw TextTargetReadError.unsupported }
    }
}

/// A Chromium-like field: Accessibility writes are ignored; keys land at once.
@MainActor private final class KeyTarget: TextTarget {
    var value: String
    var selection: UTF16Range
    var keys: [FieldKey] = []
    init(_ value: String) { self.value = value; selection = .init(location: value.utf16.count, length: 0) }
    var editsInPlace: Bool { false }
    var typesKeys: Bool { true }
    func isFocused() -> Bool { true }
    func selectedRange() throws -> UTF16Range { selection }
    func textLength() throws -> Int { value.utf16.count }
    func text(in range: UTF16Range) throws -> String {
        guard range.location >= 0, range.end <= value.utf16.count else { throw TextTargetReadError.unsupported }
        return (value as NSString).substring(with: NSRange(location: range.location, length: range.length))
    }
    func replace(_ range: UTF16Range, with text: String) throws {}
    func press(_ key: FieldKey, mark: Int, selection planned: UTF16Range) throws {
        guard planned == selection else { throw FieldKeyRefusal.selectionMoved }
        keys.append(key)
        let ns = value as NSString
        switch key {
        case .left: selection = .init(location: max(0, selection.location - 1), length: 0)
        case .right: selection = .init(location: min(ns.length, selection.end + 1), length: 0)
        case .backspace:
            value = ns.replacingCharacters(in: NSRange(location: selection.location - 1, length: 1), with: "")
            selection = .init(location: selection.location - 1, length: 0)
        case .text(let character):
            value = ns.replacingCharacters(in: NSRange(location: selection.location, length: 0), with: String(character))
            selection = .init(location: selection.location + String(character).utf16.count, length: 0)
        }
    }
}

@MainActor private enum SnapshotVersion { static var value = 0 }

@MainActor struct MacFieldEditorTests {
    private func snapshot(_ text: String, run: String = "one", complete: Bool = false) -> LiveDictationSnapshot {
        SnapshotVersion.value += 1
        return .init(runID: run, version: SnapshotVersion.value, segments: [.init(id: 0, text: text, final: complete)], complete: complete)
    }
    @Test func rawPartialReplacementsAndCleanupStayInsideTheOwnedSpan() async {
        let target = EditorTarget("Hello 🐈", .init(location: 8, length: 0))
        let editor = MacFieldEditor(capture: { .target(target) })
        editor.begin()
        await editor.applyLive(snapshot("small cab"))
        #expect(target.value == "Hello 🐈 small cab")
        await editor.applyLive(snapshot("small cat"))
        #expect(target.value == "Hello 🐈 small cat")
        await editor.applyLive(snapshot("Small cat.", complete: true))
        #expect(target.value == "Hello 🐈 Small cat.")
        #expect(target.selection.location == target.value.utf16.count)
        #expect(target.writes.allSatisfy { $0.location >= 8 })
    }
    @Test func richFieldTrailingSpaceNormalizationDoesNotDetachTheNextPartial() async {
        for prefix in ["Draft:", "Sailing ⛵️:"] {
            let target = EditorTarget(prefix + "\u{00A0}")
            target.normalizeTrailingNBSP = true
            let editor = MacFieldEditor(capture: { .target(target) })
            var reports: [String] = []
            editor.report = { reports.append($0) }
            editor.begin()
            await editor.applyLive(snapshot("hello there"))
            await editor.applyLive(snapshot("hello there friend"))
            await editor.applyLive(snapshot("Hello there friend.", complete: true))
            #expect(target.value == prefix + " Hello there friend.")
            #expect(target.selection == .init(location: target.value.utf16.count, length: 0))
            #expect(target.writes.allSatisfy { $0.length <= 1 })
            #expect(reports.isEmpty)
        }
    }
    @Test func aLiteralNBSPCanRemainUnchangedAndOtherPrefixChangesStillStopEditing() async {
        let target = EditorTarget("Draft:\u{00A0}")
        let editor = MacFieldEditor(capture: { .target(target) })
        editor.begin()
        await editor.applyLive(snapshot("hello"))
        await editor.applyLive(snapshot("hello there", complete: true))
        #expect(target.value == "Draft:\u{00A0}hello there")
        #expect(target.writes.allSatisfy { $0.length <= 1 })

        let corrupted = EditorTarget("Draft:\u{00A0}")
        corrupted.normalizeTrailingNBSP = true; corrupted.corruptPrefixAfterWrite = true
        let guarded = MacFieldEditor(capture: { .target(corrupted) })
        guarded.begin()
        await guarded.applyLive(snapshot("hello"))
        await guarded.applyLive(snapshot("hello there", complete: true))
        // A change outside the run's words (here, the field's own text) never stops the run: it is rebased.
        #expect(corrupted.value == "Xraft: hello there")
    }
    @Test func movingTheCursorBeforeFirstWordsStartsTheRunAtTheUsersCaret() async {
        let target = EditorTarget("Keep this")
        let editor = MacFieldEditor(capture: { .target(target) })
        var copied = ""
        editor.recover = { copied = $0 }
        editor.begin()
        target.selection = .init(location: 0, length: 0)
        await editor.applyLive(snapshot("new words", complete: true))
        #expect(target.value == "new wordsKeep this")
        #expect(copied.isEmpty)
    }
    @Test func focusLossNeverRebindsToAnotherFieldAndFinalTextIsRecovered() async {
        let target = EditorTarget("")
        let other = EditorTarget("Untouched")
        var current = target
        let editor = MacFieldEditor(capture: { .target(current) })
        var copied = ""
        editor.recover = { copied = $0 }
        editor.begin(); await editor.applyLive(snapshot("hello"))
        target.focused = false; current = other
        await editor.applyLive(snapshot("Hello world.", complete: true))
        #expect(target.value == "hello")
        #expect(other.value == "Untouched")
        #expect(copied == "Hello world.")
    }
    @Test func userTypingAfterTheWordsClosesTheRegionAndItsCleanupStillLands() async {
        let target = EditorTarget("")
        let editor = MacFieldEditor(capture: { .target(target) })
        editor.begin(); await editor.applyLive(snapshot("hello"))
        target.value = "hello user"; target.selection = .init(location: 10, length: 0)
        await editor.applyLive(snapshot("Hello.", complete: true))
        #expect(target.value == "Hello. user")
        #expect(target.selection == .init(location: 11, length: 0))
    }
    @Test func selectedInstructionAndUndoTouchExactlyTheirVerifiedScope() async throws {
        let target = EditorTarget("Before 🐈 after", .init(location: 7, length: 2))
        let editor = MacFieldEditor(capture: { .target(target) })
        editor.begin(); editor.beginInstruction()
        let read = try await editor.read(.contextInPlace, instructionID: "magic", reading: {})
        #expect(read.selection == "🐈")
        let edit = ScopedEdit(instructionID: "magic", documentID: read.documentID, before: "", after: "", selected: "🐈", target: "cat")
        let ack = await editor.apply(edit)
        #expect(ack?.applied == true)
        #expect(target.value == "Before cat after")
        let undo = ScopedEditPlanner.undo(of: edit, cursor: try #require(ack?.cursor))
        #expect(await editor.apply(undo)?.applied == true)
        #expect(target.value == "Before 🐈 after")
        #expect(target.writes.allSatisfy { $0.location >= 7 && $0.location <= 9 && $0.length <= 2 })
    }
    @Test func anEditOrAppSwitchWhileTheModelWorksRefusesTheResult() async throws {
        let target = EditorTarget("Prefix. Draft")
        let editor = MacFieldEditor(capture: { .target(target) })
        editor.begin(); editor.beginInstruction()
        let read = try await editor.read(.context, instructionID: "magic", reading: {})
        let edit = ScopedEdit(instructionID: "magic", documentID: read.documentID, before: "Draft", after: "", target: "Revised")
        target.value = "Edited. Draft" // same caret and requested span, but user changed the read context
        #expect(await editor.apply(edit)?.applied == false)
        #expect(target.writes.isEmpty)
        target.value = "Prefix. Draft"; target.focused = false
        #expect(await editor.apply(edit)?.applied == false)
    }
    @Test func undoRefusesChangedTextOrMovedCursor() async throws {
        let target = EditorTarget("draft")
        let editor = MacFieldEditor(capture: { .target(target) })
        editor.begin(); editor.beginInstruction()
        let read = try await editor.read(.context, instructionID: "magic", reading: {})
        let edit = ScopedEdit(instructionID: "magic", documentID: read.documentID, before: "draft", after: "", target: "DRAFT")
        let ack = await editor.apply(edit)
        let undo = ScopedEditPlanner.undo(of: edit, cursor: try #require(ack?.cursor))
        target.value = "CRAFT"
        #expect(await editor.apply(undo)?.applied == false)
        #expect(target.value == "CRAFT")
    }
    @Test func secureOrUnreadableTargetsNeverReceiveBlindWrites() async throws {
        let secure = MacFieldEditor(capture: { .secure })
        secure.begin(); secure.beginInstruction()
        await #expect(throws: (any Error).self) { try await secure.read(.context, instructionID: "x", reading: {}) }
        let target = EditorTarget("private"); target.readable = false
        let editor = MacFieldEditor(capture: { .target(target) })
        editor.begin(); await editor.applyLive(snapshot("new", complete: true))
        #expect(target.writes.isEmpty)
        #expect(target.value == "private")
    }
    @Test func paragraphInTheMiddleOfUnicodeTextAndUndoPreserveBothSides() async throws {
        let target = EditorTarget("🐈 Header\nhello middle world\nFooter", .init(location: 16, length: 0))
        let editor = MacFieldEditor(capture: { .target(target) })
        editor.begin(); editor.beginInstruction()
        let read = try await editor.read(.context, instructionID: "magic", reading: {})
        #expect(read.above == "🐈 Header\nhello ")
        let edit = ScopedEdit(instructionID: "magic", documentID: read.documentID, before: "hello ", after: "middle world", target: "Rewritten paragraph")
        let ack = await editor.apply(edit)
        #expect(ack?.applied == true)
        #expect(target.value == "🐈 Header\nRewritten paragraph\nFooter")
        let undo = ScopedEditPlanner.undo(of: edit, cursor: try #require(ack?.cursor))
        #expect(await editor.apply(undo)?.applied == true)
        #expect(target.value == "🐈 Header\nhello middle world\nFooter")
    }
    @Test func theMacReadUsesTheSharedBudgetAndQuoteSignatureBoundaries() async throws {
        let target = EditorTarget("On Tuesday, Alex wrote:\n> Their words\nMy reply\n-- \nPrivate signature", .init(location: 45, length: 0))
        let editor = MacFieldEditor(capture: { .target(target) })
        editor.begin(); editor.beginInstruction()
        let read = try await editor.read(.context, instructionID: "magic", reading: {})
        #expect(read.stop == .quote)
        #expect(!read.above.contains("Their words"))
        #expect(read.stopBelow == .signature)
        #expect(!read.below.contains("Private signature"))
        let longTarget = EditorTarget(String(repeating: "word ", count: 1000))
        let longEditor = MacFieldEditor(capture: { .target(longTarget) })
        longEditor.begin(); longEditor.beginInstruction()
        let capped = try await longEditor.read(.toCap, instructionID: "magic", reading: {})
        #expect(capped.above.count + capped.below.count <= FieldReader.defaultCap)
        #expect(capped.stop == .cap)
        #expect(capped.moreAbove)
    }
    @Test func realInputThatLeavesTheScopeAloneIsRebasedNotRefused() async throws {
        let target = EditorTarget("draft")
        let editor = MacFieldEditor(capture: { .target(target) })
        editor.begin(); editor.beginInstruction()
        let read = try await editor.read(.context, instructionID: "magic", reading: {})
        editor.relinquish()
        target.value = "Note: draft"; target.selection = .init(location: 11, length: 0)
        let edit = ScopedEdit(instructionID: "magic", documentID: read.documentID, before: "draft", after: "", target: "DRAFT")
        #expect(await editor.apply(edit)?.applied == true)
        #expect(target.value == "Note: DRAFT")
    }
    @Test func aScopeTheUserChangedIsDroppedAndReported() async throws {
        let target = EditorTarget("draft")
        let editor = MacFieldEditor(capture: { .target(target) })
        var reports: [String] = []
        editor.report = { reports.append($0) }
        editor.begin(); editor.beginInstruction()
        let read = try await editor.read(.context, instructionID: "magic", reading: {})
        target.value = "drift"
        let edit = ScopedEdit(instructionID: "magic", documentID: read.documentID, before: "draft", after: "", target: "DRAFT")
        #expect(await editor.apply(edit)?.applied == false)
        #expect(target.value == "drift")
        #expect(!reports.isEmpty)
    }

    @Test func oldCleanupCannotFollowMagicIntoANewFieldOrSelection() async throws {
        let old = EditorTarget(""), fresh = EditorTarget("Leave this alone", .init(location: 0, length: 5))
        var focused = old
        let editor = MacFieldEditor(capture: { .target(focused) })
        editor.begin(); await editor.applyLive(snapshot("raw dictation"))
        editor.relinquish(); old.focused = false; focused = fresh
        editor.beginInstruction()
        await editor.applyLive(snapshot("Cleaned dictation.", complete: true))
        #expect(old.value == "raw dictation")
        #expect(fresh.value == "Leave this alone")
        #expect(fresh.writes.isEmpty)
        let read = try await editor.read(.contextInPlace, instructionID: "new-magic", reading: {})
        #expect(read.selection == "Leave")
    }
    @Test func anUnreadableFieldDictatesThroughThePanelAndTypesOnceAtTheEnd() async {
        let editor = MacFieldEditor(capture: { .none })
        var inserts: [String] = [], copies: [String] = [], notices: [String] = []
        editor.insert = { inserts.append($0); return .typed }
        editor.recover = { copies.append($0) }
        editor.report = { notices.append($0) }
        editor.begin()
        #expect(editor.panel.active)
        #expect(notices.isEmpty)
        await editor.applyLive(snapshot("raw words"))
        #expect(editor.panel.take.text == "raw words")
        #expect(inserts.isEmpty)
        await editor.applyLive(snapshot("Ready.", complete: true))
        #expect(editor.panel.take.text == "Ready.")
        await editor.finish()
        // A late cleanup of the run already typed is never typed again.
        await editor.applyLive(snapshot("Late cleanup.", complete: true))
        await editor.finish()
        #expect(inserts == ["Ready."])
        // Real input during the take: copied, never typed.
        editor.begin(); editor.relinquish()
        await editor.applyLive(snapshot("Keep this.", run: "fresh", complete: true))
        await editor.finish()
        #expect(inserts == ["Ready."])
        #expect(copies == ["Keep this."])
    }
    @Test func secureFieldsNeverUseThePanel() async {
        let editor = MacFieldEditor(capture: { .secure })
        var inserts: [String] = [], copies: [String] = []
        editor.insert = { inserts.append($0); return .typed }
        editor.recover = { copies.append($0) }
        editor.panelMode = { .always }
        editor.begin(); await editor.applyLive(snapshot("words", complete: true))
        await editor.finish()
        #expect(!editor.panel.active)
        #expect(inserts.isEmpty)
        #expect(copies == ["words"])
    }
    @Test func panelModeAlwaysLeavesAReadableFieldUntouchedUntilTheEnd() async {
        let target = EditorTarget("Hi")
        let editor = MacFieldEditor(capture: { .target(target) })
        var inserts: [String] = []
        editor.insert = { inserts.append($0); return .typed }
        editor.panelMode = { .always }
        editor.begin()
        await editor.applyLive(snapshot("there"))
        await editor.applyLive(snapshot("there.", complete: true))
        #expect(target.writes.isEmpty)
        await editor.finish()
        #expect(inserts == [" there."]) // after the field's own "Hi"
    }
    @Test func anElementThatReadsButTakesNoWritesOrKeysUsesThePanelAndOnlyCopies() async throws {
        let target = EditorTarget("Some text")
        target.inPlace = false
        let editor = MacFieldEditor(capture: { .target(target) })
        var inserts: [String] = [], copied: [String] = []
        editor.insert = { inserts.append($0); return .typed }
        editor.recover = { copied.append($0) }
        editor.begin()
        #expect(editor.panel.active)
        await editor.applyLive(snapshot("more", complete: true))
        #expect(target.writes.isEmpty)
        editor.beginInstruction()
        let read = try await editor.read(.contextInPlace, instructionID: "magic", reading: {})
        #expect(read.above == "Some text")
        await editor.finish()
        // A page is not a field: its letters could be the site's shortcuts, so nothing is typed.
        #expect(inserts.isEmpty && copied == ["more"])
    }
    @Test func aKeystrokeFieldIsEditedLiveWithoutThePanel() async {
        let target = KeyTarget("Hi")
        let editor = MacFieldEditor(capture: { .target(target) })
        editor.typewriter = { false }
        editor.begin()
        #expect(!editor.panel.active)
        await editor.applyLive(snapshot("there"))
        await editor.applyLive(snapshot("There.", complete: true))
        #expect(target.value == "Hi There.")
        #expect(target.keys.allSatisfy { $0 != .text("\n") && $0 != .text("\t") })
        #expect(target.selection == .init(location: 9, length: 0))
    }
    @Test func aStalledPanelTakeWaitsForTheUsersChoiceAndThenTypesOnce() async {
        let editor = MacFieldEditor(capture: { .none })
        var inserts: [String] = []
        editor.insert = { inserts.append($0); return .typed }
        editor.begin()
        editor.deliver("First line.")
        var polls = 0
        let stalled = await editor.stream {
            polls += 1
            return .init(text: "Partly clean", isFinal: false, stalled: polls > 1)
        }
        #expect(stalled)
        await editor.finish()
        // The finished line before the held take goes in; the held take waits.
        #expect(inserts == ["First line."])
        #expect(editor.panel.take.text == "Partly clean")
        // Insert as-is: the partial is taken back and the raw take arrives as one final delivery.
        editor.retractStreamed()
        _ = await editor.stream { .init(text: "partly raw", isFinal: true) }
        await editor.finish()
        #expect(inserts == ["First line.", " partly raw"])
    }

    @Test func retractingAFailedStreamRestoresOnlyItsOriginalSelection() async {
        let target = EditorTarget("Before old after", .init(location: 7, length: 3))
        let editor = MacFieldEditor(capture: { .target(target) })
        editor.begin()
        var polls = 0
        _ = await editor.stream {
            polls += 1
            return polls == 1 ? .init(text: "partial", isFinal: false) : .init(text: "partial", isFinal: true, retracted: true)
        }
        await editor.queue.whenIdle()
        #expect(target.value == "Before old after")
        #expect(target.selection == .init(location: 7, length: 3))
        editor.deliver("final")
        await editor.finish()
        #expect(target.value == "Before final after")
    }

    @Test func browserLiveCorrectionsPreserveTheUnchangedTailAndRestoreTheCaret() async {
        let target = EditorTarget("")
        let editor = MacFieldEditor(capture: { .target(target) })
        editor.begin(); await editor.applyLive(snapshot("small cab is here"))
        await editor.applyLive(snapshot("small cat is here"))
        #expect(target.value == "small cat is here")
        #expect(target.selection == .init(location: 17, length: 0))
        #expect(target.selections.last == .init(location: 17, length: 0))
        #expect(Array(target.writes.suffix(2)) == [.init(location: 8, length: 1), .init(location: 8, length: 0)])
    }
    @Test func aHostWriteThatThrowsButLandedCounts() async throws {
        let target = EditorTarget("draft")
        let editor = MacFieldEditor(capture: { .target(target) })
        editor.begin(); editor.beginInstruction()
        let read = try await editor.read(.context, instructionID: "magic", reading: {})
        let edit = ScopedEdit(instructionID: "magic", documentID: read.documentID, before: "draft", after: "", target: "Revised")
        target.throwAfterWrite = true
        // The readback decides: a host that throws after writing has still written.
        #expect(await editor.apply(edit)?.applied == true)
        #expect(target.value == "Revised")
    }
    @Test func aHostThatIgnoresWritesStopsAfterBoundedRetries() async throws {
        let target = EditorTarget("draft")
        let editor = MacFieldEditor(capture: { .target(target) })
        editor.sleep = { _ in }
        editor.begin(); editor.beginInstruction()
        let read = try await editor.read(.context, instructionID: "magic", reading: {})
        target.ignoreWrites = true
        let edit = ScopedEdit(instructionID: "magic", documentID: read.documentID, before: "draft", after: "", target: "Revised")
        let ack = await editor.apply(edit)
        #expect(ack?.applied == false)
        #expect(ack?.stopped == true)
        #expect(target.value == "draft")
        #expect(target.writes.count == MacFieldQueue.retryLimit)
    }
    @Test func aNewInstructionInTheSameFieldCannotApplyThePreviousResult() async throws {
        let target = EditorTarget("draft")
        let editor = MacFieldEditor(capture: { .target(target) })
        editor.begin(); editor.beginInstruction()
        let old = try await editor.read(.context, instructionID: "old", reading: {})
        editor.beginInstruction()
        let fresh = try await editor.read(.context, instructionID: "fresh", reading: {})
        let stale = ScopedEdit(instructionID: "old", documentID: old.documentID, before: "draft", after: "", target: "Old")
        #expect(await editor.apply(stale)?.applied == false)
        editor.cancel(instructionID: "old")
        let current = ScopedEdit(instructionID: "fresh", documentID: fresh.documentID, before: "draft", after: "", target: "Fresh")
        #expect(await editor.apply(current)?.applied == true)
        #expect(target.value == "Fresh")
    }

    @Test func newerCleanupCanLandAfterTheTakeCompletesButOlderSnapshotsCannotRevertIt() async {
        let target = EditorTarget("")
        let editor = MacFieldEditor(capture: { .target(target) })
        editor.begin()
        let raw = snapshot("raw words", complete: true)
        let cleaned = snapshot("Clean words.", complete: true)
        await editor.applyLive(raw); await editor.applyLive(cleaned); await editor.applyLive(raw)
        #expect(target.value == "Clean words.")
        #expect(target.writes.allSatisfy { $0.length <= 1 })
    }
    @Test func rapidBrowserHypothesesCoalesceAndFinishFlushesTheLatestWords() async {
        let target = EditorTarget("")
        let editor = MacFieldEditor(capture: { .target(target) })
        editor.begin()
        editor.enqueueLive(snapshot("one"))
        editor.enqueueLive(snapshot("one two"))
        editor.enqueueLive(snapshot("One two three.", complete: true))
        await editor.finish()
        #expect(target.value == "One two three.")
        #expect(target.writes.count == "One two three.".count)
    }

    @Test func retractedRunCleanupCannotFollowTheRetryIntoItsText() async {
        let target = EditorTarget("")
        let editor = MacFieldEditor(capture: { .target(target) })
        editor.begin(); await editor.applyLive(snapshot("partial", run: "failed"))
        #expect(editor.retractStreamed())
        editor.deliver("Retry words.")
        await editor.finish()
        await editor.applyLive(snapshot("Late failed cleanup.", run: "failed", complete: true))
        #expect(target.value == "Retry words.")
    }

    @Test func typewriterCorrectionsPauseBetweenIndividualCharactersAndKeepTheTail() async {
        let target = EditorTarget("")
        let editor = MacFieldEditor(capture: { .target(target) })
        editor.begin(); await editor.applyLive(snapshot("abc unchanged tail"))
        target.writes = []
        var pauses: [Duration] = []
        var frames: [String] = []
        editor.typewriter = { true }
        editor.sleep = { duration in pauses.append(duration); frames.append(target.value) }
        await editor.applyLive(snapshot("aXYc unchanged tail", complete: true))
        #expect(target.value == "aXYc unchanged tail")
        #expect(target.writes.count == 3)
        #expect(target.writes.allSatisfy { $0.length <= 1 })
        #expect(pauses.count == 2 && pauses.allSatisfy { $0 >= .milliseconds(20) })
        #expect(frames.allSatisfy { $0.hasSuffix("c unchanged tail") })
    }

    @Test func realTypingDuringAnAnimationKeepsTheKeyAfterTheWord() async {
        let target = EditorTarget("")
        let editor = MacFieldEditor(capture: { .target(target) })
        var copied = ""
        editor.recover = { copied = $0 }
        editor.typewriter = { true }
        editor.sleep = { _ in
            // The user types after the first letter: the word is finished first, their key stays after it.
            if target.value == "h" { editor.relinquish(); target.value = "hX"; target.selection = .init(location: 2, length: 0) }
        }
        editor.begin()
        await editor.applyLive(snapshot("hello", complete: true))
        #expect(target.value == "helloX")
        #expect(target.selection == .init(location: 6, length: 0))
        #expect(copied.isEmpty)
    }

    @Test func queuedSeparateTakesAreNeverCoalescedAway() async {
        let target = EditorTarget("")
        let editor = MacFieldEditor(capture: { .target(target) })
        editor.begin()
        editor.deliver("First.")
        editor.deliver("Second.")
        await editor.finish()
        #expect(target.value == "First. Second.")
    }

    @Test func anEditInsideTheRunsWordsDropsOnlyItsPendingRevision() async {
        let target = EditorTarget("")
        let editor = MacFieldEditor(capture: { .target(target) })
        var copied = ""
        editor.recover = { copied = $0 }
        editor.begin(); await editor.applyLive(snapshot("cab unchanged tail"))
        target.writes = []
        editor.typewriter = { true }
        editor.sleep = { _ in if target.value.hasPrefix("c") { target.value = "Q" + target.value.dropFirst() } }
        await editor.applyLive(snapshot("cXYZ unchanged tail", complete: true))
        #expect(target.value == "QX unchanged tail")
        #expect(copied == "cXYZ unchanged tail", "copied: \(copied) journal: \(editor.queue.debugState)")
    }

}
#endif
