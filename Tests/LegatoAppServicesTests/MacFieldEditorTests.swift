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
        selection = .init(location: range.location + text.utf16.count, length: 0)
        if throwAfterWrite { throw TextTargetReadError.unsupported }
    }
}

@MainActor private enum SnapshotVersion { static var value = 0 }

@MainActor struct MacFieldEditorTests {
    private func snapshot(_ text: String, run: String = "one", complete: Bool = false) -> LiveDictationSnapshot {
        SnapshotVersion.value += 1
        return .init(runID: run, version: SnapshotVersion.value, segments: [.init(id: 0, text: text, final: complete)], complete: complete)
    }
    @Test func rawPartialReplacementsAndCleanupStayInsideTheOwnedSpan() {
        let target = EditorTarget("Hello 🐈", .init(location: 8, length: 0))
        let editor = MacFieldEditor(capture: { .target(target) })
        editor.begin()
        editor.applyLive(snapshot("small cab"))
        #expect(target.value == "Hello 🐈 small cab")
        editor.applyLive(snapshot("small cat"))
        #expect(target.value == "Hello 🐈 small cat")
        editor.applyLive(snapshot("Small cat.", complete: true))
        #expect(target.value == "Hello 🐈 Small cat.")
        #expect(target.selection.location == target.value.utf16.count)
        #expect(target.writes.allSatisfy { $0.location >= 8 })
    }
    @Test func movingTheCursorBeforeFirstWordsNeverRedirectsTheRun() {
        let target = EditorTarget("Keep this")
        let editor = MacFieldEditor(capture: { .target(target) })
        var copied = ""
        editor.recover = { copied = $0 }
        editor.begin()
        target.selection = .init(location: 0, length: 0)
        editor.applyLive(snapshot("new words", complete: true))
        #expect(target.value == "Keep this")
        #expect(target.writes.isEmpty)
        #expect(copied == "new words")
    }
    @Test func focusLossNeverRebindsToAnotherFieldAndFinalTextIsRecovered() {
        let target = EditorTarget("")
        let other = EditorTarget("Untouched")
        var current = target
        let editor = MacFieldEditor(capture: { .target(current) })
        var copied = ""
        editor.recover = { copied = $0 }
        editor.begin(); editor.applyLive(snapshot("hello"))
        target.focused = false; current = other
        editor.applyLive(snapshot("Hello world.", complete: true))
        #expect(target.value == "hello")
        #expect(other.value == "Untouched")
        #expect(copied == "Hello world.")
    }
    @Test func userTypingFreezesLaterCleanup() {
        let target = EditorTarget("")
        let editor = MacFieldEditor(capture: { .target(target) })
        editor.begin(); editor.applyLive(snapshot("hello"))
        target.value = "hello user"; target.selection = .init(location: 10, length: 0)
        editor.applyLive(snapshot("Hello.", complete: true))
        #expect(target.value == "hello user")
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
        #expect(target.writes == [.init(location: 7, length: 2), .init(location: 7, length: 3)])
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
        editor.begin(); editor.applyLive(snapshot("new", complete: true))
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
    @Test func realInputRelinquishesOwnershipEvenWhenTextAndCaretReturn() async throws {
        let target = EditorTarget("draft")
        let editor = MacFieldEditor(capture: { .target(target) })
        editor.begin(); editor.beginInstruction()
        let read = try await editor.read(.context, instructionID: "magic", reading: {})
        editor.relinquish()
        let edit = ScopedEdit(instructionID: "magic", documentID: read.documentID, before: "draft", after: "", target: "DRAFT")
        #expect(await editor.apply(edit)?.applied == false)
        #expect(target.value == "draft")
    }

    @Test func oldCleanupCannotFollowMagicIntoANewFieldOrSelection() async throws {
        let old = EditorTarget(""), fresh = EditorTarget("Leave this alone", .init(location: 0, length: 5))
        var focused = old
        let editor = MacFieldEditor(capture: { .target(focused) })
        editor.begin(); editor.applyLive(snapshot("raw dictation"))
        editor.relinquish(); old.focused = false; focused = fresh
        editor.beginInstruction()
        editor.applyLive(snapshot("Cleaned dictation.", complete: true))
        #expect(old.value == "raw dictation")
        #expect(fresh.value == "Leave this alone")
        #expect(fresh.writes.isEmpty)
        let read = try await editor.read(.contextInPlace, instructionID: "new-magic", reading: {})
        #expect(read.selection == "Leave")
    }
    @Test func initiallyUnreadableDictationFallsBackOnceAndNeverAfterRealInput() async {
        let editor = MacFieldEditor(capture: { .none })
        var deliveries: [String] = [], copies: [String] = []
        editor.fallback = { deliveries.append($0) }
        editor.recover = { copies.append($0) }
        editor.begin()
        editor.applyLive(snapshot("raw"))
        #expect(deliveries.isEmpty)
        editor.applyLive(snapshot("Ready.", complete: true))
        await editor.finish()
        editor.applyLive(snapshot("Late cleanup.", complete: true))
        await editor.finish()
        #expect(deliveries == ["Ready."])
        editor.begin(); editor.relinquish()
        editor.applyLive(snapshot("Keep this.", run: "fresh", complete: true))
        await editor.finish()
        #expect(deliveries == ["Ready."])
        #expect(copies == ["Keep this."])
    }
    @Test func secureFieldsNeverUseTheUnreadableFieldFallback() async {
        let editor = MacFieldEditor(capture: { .secure })
        var deliveries: [String] = [], copies: [String] = []
        editor.fallback = { deliveries.append($0) }
        editor.recover = { copies.append($0) }
        editor.begin(); editor.applyLive(snapshot("words", complete: true))
        await editor.finish()
        #expect(deliveries.isEmpty)
        #expect(copies == ["words"])
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
        #expect(target.value == "Before old after")
        editor.deliver("final")
        #expect(target.value == "Before final after")
    }

    @Test func browserLiveCorrectionsLeaveTheCaretAtTheTailWithoutASecondJump() {
        let target = EditorTarget("")
        let editor = MacFieldEditor(capture: { .target(target) })
        editor.begin(); editor.applyLive(snapshot("small cab is here"))
        editor.applyLive(snapshot("small cat is here"))
        #expect(target.value == "small cat is here")
        #expect(target.selection == .init(location: 17, length: 0))
        #expect(target.selections.isEmpty)
        #expect(target.writes.last == .init(location: 8, length: 9))
    }
    @Test func aPartiallySuccessfulHostWriteStopsRecoveryFromWritingAgain() async throws {
        let target = EditorTarget("draft")
        let editor = MacFieldEditor(capture: { .target(target) })
        editor.begin(); editor.beginInstruction()
        let read = try await editor.read(.context, instructionID: "magic", reading: {})
        let edit = ScopedEdit(instructionID: "magic", documentID: read.documentID, before: "draft", after: "", target: "Revised")
        target.throwAfterWrite = true
        let ack = await editor.apply(edit)
        #expect(ack?.applied == false)
        #expect(ack?.stopped == true)
        #expect(target.value == "Revised")
        #expect(await editor.apply(edit)?.applied == false)
        #expect(target.writes.count == 1)
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

    @Test func newerCleanupCanLandAfterTheTakeCompletesButOlderSnapshotsCannotRevertIt() {
        let target = EditorTarget("")
        let editor = MacFieldEditor(capture: { .target(target) })
        editor.begin()
        let raw = snapshot("raw words", complete: true)
        let cleaned = snapshot("Clean words.", complete: true)
        editor.applyLive(raw); editor.applyLive(cleaned); editor.applyLive(raw)
        #expect(target.value == "Clean words.")
        #expect(target.writes.count == 2)
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
        #expect(target.writes.count == 1)
    }

    @Test func retractedRunCleanupCannotFollowTheRetryIntoItsText() {
        let target = EditorTarget("")
        let editor = MacFieldEditor(capture: { .target(target) })
        editor.begin(); editor.applyLive(snapshot("partial", run: "failed"))
        #expect(editor.retractStreamed())
        editor.deliver("Retry words.")
        editor.applyLive(snapshot("Late failed cleanup.", run: "failed", complete: true))
        #expect(target.value == "Retry words.")
    }

}
#endif
