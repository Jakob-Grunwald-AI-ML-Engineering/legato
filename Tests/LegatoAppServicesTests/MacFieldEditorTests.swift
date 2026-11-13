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
    var startsWithNativeWrites = false
    var nativeWriteLandsBeforeThrowing = false
    var nativeWriteThrowsWithoutLanding = false
    var nativeWrites = 0
    var recoveryChecks = 0
    var focused = true
    var loseFocusAfterBackspace = false
    var readable = true
    var loseReadsAfterBackspace = false
    private var recovered = false
    init(_ value: String) { self.value = value; selection = .init(location: value.utf16.count, length: 0) }
    var editsInPlace: Bool { startsWithNativeWrites && !recovered }
    var typesKeys: Bool { true }
    func isFocused() -> Bool { focused }
    func selectedRange() throws -> UTF16Range { selection }
    func textLength() throws -> Int {
        guard readable else { throw TextTargetReadError.unsupported }
        return value.utf16.count
    }
    func text(in range: UTF16Range) throws -> String {
        guard readable, range.location >= 0, range.end <= value.utf16.count else { throw TextTargetReadError.unsupported }
        return (value as NSString).substring(with: NSRange(location: range.location, length: range.length))
    }
    func replace(_ range: UTF16Range, with text: String) throws {
        nativeWrites += 1
        if nativeWriteThrowsWithoutLanding { throw TextTargetReadError.unsupported }
        if nativeWriteLandsBeforeThrowing {
            value = (value as NSString).replacingCharacters(in: NSRange(location: range.location, length: range.length), with: text)
            selection = .init(location: range.location + text.utf16.count, length: 0)
            throw TextTargetReadError.unsupported
        }
    }
    func recoverWriteFailure() -> Bool {
        recoveryChecks += 1
        guard startsWithNativeWrites, !recovered else { return false }
        recovered = true
        return true
    }
    func press(_ key: FieldKey, mark: Int, selection planned: UTF16Range) throws {
        guard planned == selection else { throw FieldKeyRefusal.selectionMoved }
        if case .hop = key { throw FieldKeyRefusal.unavailable }
        keys.append(key)
        let ns = value as NSString
        switch key {
        case .left: selection = .init(location: max(0, selection.location - 1), length: 0)
        case .right: selection = .init(location: min(ns.length, selection.end + 1), length: 0)
        case .backspace:
            value = ns.replacingCharacters(in: NSRange(location: selection.location - 1, length: 1), with: "")
            selection = .init(location: selection.location - 1, length: 0)
            if loseFocusAfterBackspace { focused = false }
            if loseReadsAfterBackspace { readable = false }
        case .text(let character):
            value = ns.replacingCharacters(in: NSRange(location: selection.location, length: 0), with: String(character))
            selection = .init(location: selection.location + String(character).utf16.count, length: 0)

        case .arrows(let left, let count):
            selection = .init(location: left ? max(0, selection.location - count) : min(ns.length, selection.end + count), length: 0)
        case .hop: break
        }
    }
}

@MainActor private enum SnapshotVersion { static var value = 0 }

@MainActor struct MacFieldEditorTests {
    private func snapshot(_ text: String, run: String = "one", complete: Bool = false) -> LiveDictationSnapshot {
        SnapshotVersion.value += 1
        return .init(runID: run, version: SnapshotVersion.value, segments: [.init(id: 0, text: text, final: complete)], complete: complete)
    }
    @Test func idleObserverRunsAfterFinalWritesBeforeWaitersResume() async {
        let target = EditorTarget("Draft:")
        let queue = MacFieldQueue(target: target)
        queue.paced = { false }
        var observed: String?
        var pendingAtObservation = true
        queue.onIdle = {
            observed = target.value
            pendingAtObservation = queue.hasWork
        }
        queue.live(runID: "take", version: 1, text: "Hello John.", complete: true)
        await queue.whenIdle()
        #expect(observed == "Draft: Hello John.")
        #expect(!pendingAtObservation)
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
        #expect(copied.isEmpty)
        #expect(editor.panel.recoveryText == "Hello world.")
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
    @Test func passwordOrUnreadableTargetsNeverReceiveBlindWrites() async throws {
        let password = MacFieldEditor(capture: { .password })
        password.begin(); password.beginInstruction()
        await #expect(throws: (any Error).self) { try await password.read(.context, instructionID: "x", reading: {}) }
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
    @Test func aScopeTheUserChangedKeepsItsSuggestionInThePanelWithoutCopying() async throws {
        let target = EditorTarget("draft")
        let editor = MacFieldEditor(capture: { .target(target) })
        var reports: [String] = [], copies: [String] = []
        editor.report = { reports.append($0) }
        editor.recover = { copies.append($0) }
        editor.begin(); editor.beginInstruction()
        let read = try await editor.read(.context, instructionID: "magic", reading: {})
        target.value = "drift"
        let edit = ScopedEdit(instructionID: "magic", documentID: read.documentID, before: "draft", after: "", target: "DRAFT")
        #expect(await editor.apply(edit)?.applied == false)
        #expect(target.value == "drift")
        #expect(editor.panel.recoveryText == "DRAFT")
        #expect(reports.isEmpty && copies.isEmpty)
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
        // Real input during the take: retained in the panel, never typed or copied automatically.
        editor.begin(); editor.relinquish()
        await editor.applyLive(snapshot("Keep this.", run: "fresh", complete: true))
        await editor.finish()
        #expect(inserts == ["Ready."])
        #expect(copies.isEmpty)
        #expect(editor.panel.recoveryText == "Keep this.")
    }
    /// Jakob's tight list in Edge: the field bound, then stopped reading. The take is never dropped and shows no notice:
    /// what went in live stays, the rest grows and is cleaned in the panel, and it is typed once at the end.
    @Test(arguments: [false, true]) func aFieldThatStopsReadingGoesOnInThePanelWithoutANotice(midTake: Bool) async {
        let target = EditorTarget("Plan: ")
        let editor = MacFieldEditor(capture: { .target(target) })
        editor.typewriter = { false }
        var inserts: [String] = [], notices: [String] = [], copies: [String] = []
        editor.insert = { inserts.append($0); return .typed }
        editor.report = { notices.append($0) }
        editor.recover = { copies.append($0) }
        target.readable = midTake
        editor.begin()
        #expect(!editor.panel.active)
        await editor.applyLive(snapshot("Urgent", run: "take"))
        if midTake {
            #expect(target.value == "Plan: Urgent")
            target.readable = false
            await editor.applyLive(snapshot("Urgent callback", run: "take"))
            #expect(editor.panel.active && editor.panel.take.text == " callback")
        } else {
            #expect(editor.panel.active && editor.panel.take.text == "Urgent")
        }
        await editor.applyLive(snapshot("Urgent callback.", run: "take", complete: true))
        await editor.finish()
        #expect(inserts == [midTake ? " callback." : "Urgent callback."])
        #expect(target.value == (midTake ? "Plan: Urgent" : "Plan: "))
        #expect(notices.isEmpty && copies.isEmpty, "\(notices) \(copies)")
        // The next take binds afresh: a readable field is edited live again.
        target.readable = true
        editor.begin()
        #expect(!editor.panel.active)
        await editor.applyLive(snapshot("Next.", run: "next", complete: true))
        await editor.finish()
        #expect(target.value.hasSuffix("Next."))
    }
    @Test func aPasswordFieldDictatesThroughThePanelLikeAnyUnreadableFieldWithoutANotice() async {
        for mode in PanelDictationSetting.Mode.allCases {
            let editor = MacFieldEditor(capture: { .password })
            var inserts: [String] = [], copies: [String] = [], notices: [String] = []
            editor.insert = { inserts.append($0); return .typed }
            editor.recover = { copies.append($0) }
            editor.report = { notices.append($0) }
            editor.panelMode = { mode }
            editor.begin()
            #expect(editor.panel.active)
            #expect(editor.passwordField)
            await editor.applyLive(snapshot("hunter two", complete: true))
            #expect(editor.panel.take.text == "hunter two")
            await editor.finish()
            #expect(inserts == ["hunter two"])
            #expect(copies.isEmpty)
            #expect(notices.isEmpty)
        }
    }
    @Test func aPasswordTakeThatCannotBeTypedStaysInThePanelUntilExplicitlyCopied() async {
        let editor = MacFieldEditor(capture: { .password })
        var copies: [String] = [], notices: [String] = []
        editor.insert = { _ in .retained(message: "The field changed.") }
        editor.recover = { copies.append($0) }
        editor.report = { notices.append($0) }
        editor.begin(); await editor.applyLive(snapshot("words", complete: true))
        await editor.finish()
        #expect(copies.isEmpty && notices.isEmpty)
        #expect(editor.panel.recoveryText == "words")
        editor.copyRecovery()
        #expect(copies == ["words"])
        #expect(editor.panel.recoveryText == "words")
    }

    @Test func anInterruptedPanelInsertRetainsOnlyTheRemainderAcrossTheNextTake() async {
        let editor = MacFieldEditor(capture: { .none })
        var inserts: [String] = [], copies: [String] = []
        editor.recover = { copies.append($0) }
        editor.insert = { text in
            inserts.append(text)
            return .interrupted(remainder: "untyped remainder", message: "Stopped")
        }
        editor.begin()
        await editor.applyLive(snapshot("typed prefix untyped remainder", run: "old", complete: true))
        await editor.finish()
        #expect(editor.panel.recoveryText == "untyped remainder")
        editor.insert = { inserts.append($0); return .typed }
        editor.begin()
        await editor.applyLive(snapshot("New take.", run: "new", complete: true))
        await editor.applyLive(snapshot("Late old cleanup.", run: "old", complete: true))
        await editor.finish()
        #expect(inserts == ["typed prefix untyped remainder", "New take."])
        #expect(editor.panel.recoveryText == "untyped remainder")
        #expect(copies.isEmpty)
        editor.copyRecovery()
        #expect(copies == ["untyped remainder"])
        editor.dismissRecovery()
        #expect(editor.panel.recoveryText.isEmpty)
    }

    @Test func ignoredLiveWritesHandTheWholeTakeToThePanelAndKeepItsCleanup() async {
        let target = EditorTarget("First take.")
        target.ignoreWrites = true
        let editor = MacFieldEditor(capture: { .target(target) })
        editor.typewriter = { false }
        editor.sleep = { _ in }
        var inserts: [String] = [], copies: [String] = []
        editor.insert = { inserts.append($0); return .typed }
        editor.recover = { copies.append($0) }
        editor.begin()
        await editor.applyLive(snapshot("second local dictation", run: "second"))
        #expect(editor.panel.active)
        #expect(editor.panel.take.text == "second local dictation")
        await editor.applyLive(snapshot("Second local dictation test.", run: "second", complete: true))
        #expect(editor.panel.take.text == "Second local dictation test.")
        await editor.finish()
        #expect(target.value == "First take.")
        #expect(inserts == [" Second local dictation test."])
        #expect(editor.panel.recoveryText.isEmpty && copies.isEmpty)
    }

    @Test(arguments: [false, true]) func confirmedIgnoredNativeWritesReassessOnceAndContinueLiveWithVerifiedKeys(throwsWithoutLanding: Bool) async {
        let target = KeyTarget("First take.")
        target.startsWithNativeWrites = true
        target.nativeWriteThrowsWithoutLanding = throwsWithoutLanding
        let editor = MacFieldEditor(capture: { .target(target) })
        editor.typewriter = { false }
        editor.sleep = { _ in }
        var inserts: [String] = [], copies: [String] = []
        editor.insert = { inserts.append($0); return .typed }
        editor.recover = { copies.append($0) }
        editor.begin()
        await editor.applyLive(snapshot("second local dictation", run: "second"))
        #expect(target.value == "First take. second local dictation")
        #expect(target.recoveryChecks == 1)
        #expect(target.nativeWrites == MacFieldQueue.retryLimit)
        #expect(!target.keys.isEmpty)
        #expect(!editor.panel.active)
        await editor.applyLive(snapshot("Second local dictation test.", run: "second", complete: true))
        await editor.finish()
        #expect(target.value == "First take. Second local dictation test.")
        #expect(target.recoveryChecks == 1)
        #expect(editor.panel.recoveryText.isEmpty && copies.isEmpty && inserts.isEmpty)
    }

    @Test func aThrowingWriteThatLandedNeverReassessesOrReplaysThroughKeys() async {
        let target = KeyTarget("First take.")
        target.startsWithNativeWrites = true
        target.nativeWriteLandsBeforeThrowing = true
        let editor = MacFieldEditor(capture: { .target(target) })
        editor.typewriter = { false }
        editor.sleep = { _ in }
        editor.begin()
        await editor.applyLive(snapshot("Second take.", run: "second", complete: true))
        await editor.finish()
        #expect(target.value == "First take. Second take.")
        #expect(target.recoveryChecks == 0 && target.keys.isEmpty)
        #expect(!editor.panel.active && editor.panel.recoveryText.isEmpty)
    }

    @Test(arguments: [false, true]) func interruptedCleanupRetainsTheWholeSuggestionAndItsLateRevision(unreadable: Bool) async {
        let target = KeyTarget("")
        let editor = MacFieldEditor(capture: { .target(target) })
        editor.typewriter = { false }
        var clock = ContinuousClock.now
        editor.sleep = { clock += $0 }
        var copies: [String] = []
        editor.recover = { copies.append($0) }
        editor.begin()
        editor.queue.now = { clock }
        await editor.applyLive(snapshot("safe unchanged tail", run: "interrupted"))
        #expect(target.value == "safe unchanged tail")
        target.loseFocusAfterBackspace = !unreadable
        target.loseReadsAfterBackspace = unreadable
        await editor.applyLive(snapshot("Safe unchanged tail", run: "interrupted", complete: true))
        #expect(target.value == "afe unchanged tail")
        #expect(editor.panel.recoveryText == "Safe unchanged tail")
        await editor.applyLive(snapshot("Safe unchanged tail.", run: "interrupted", complete: true))
        await editor.finish()
        #expect(editor.panel.recoveryText == "Safe unchanged tail.")
        #expect(target.value == "afe unchanged tail")
        editor.dismissRecovery()
        await editor.applyLive(snapshot("Dismissed late cleanup.", run: "interrupted", complete: true))
        #expect(editor.panel.recoveryText.isEmpty && editor.panel.take.isEmpty)
        #expect(copies.isEmpty)
    }
    @Test func onlyAPasswordBindKeepsTakesOutOfHistory() {
        var field: FocusedField = .password
        let editor = MacFieldEditor(capture: { field })
        editor.begin()
        #expect(editor.passwordField)
        field = .none
        editor.begin()
        #expect(!editor.passwordField)
    }
    @Test func panelModeAlwaysLeavesAReadableFieldUntouchedUntilTheEndThenInsertsThroughTheQueue() async {
        let target = EditorTarget("Hi")
        let editor = MacFieldEditor(capture: { .target(target) })
        editor.sleep = { _ in }
        var inserts: [String] = []
        editor.insert = { inserts.append($0); return .typed }
        editor.panelMode = { .always }
        editor.begin()
        #expect(editor.panel.active)
        await editor.applyLive(snapshot("there"))
        #expect(editor.panel.take.text == "there")
        await editor.applyLive(snapshot("there.", complete: true))
        #expect(target.writes.isEmpty)
        await editor.finish()
        // One insert at the caret, after the field's own "Hi", typed one grapheme per write by the field's queue.
        #expect(target.value == "Hi there.")
        #expect(target.writes.count == " there.".count)
        #expect(inserts.isEmpty)
    }
    @Test func switchingThePanelModeTakesEffectAtTheNextTake() async {
        var mode = PanelDictationSetting.Mode.whenNeeded
        let target = EditorTarget("")
        let editor = MacFieldEditor(capture: { .target(target) })
        editor.sleep = { _ in }
        editor.panelMode = { mode }
        editor.begin()
        #expect(!editor.panel.active)
        await editor.applyLive(snapshot("live", run: "a"))
        #expect(target.value == "live")
        await editor.finish()
        mode = .always
        editor.begin()
        #expect(editor.panel.active)
        await editor.applyLive(snapshot("held", run: "b"))
        #expect(target.value == "live")
        await editor.applyLive(snapshot("held back.", run: "b", complete: true))
        await editor.finish()
        #expect(target.value == "live held back.")
        // A keystroke field in the panel mode gets the same one insert, with verified keys.
        let keys = KeyTarget("Hi")
        let keyed = MacFieldEditor(capture: { .target(keys) })
        keyed.sleep = { _ in }
        keyed.panelMode = { .always }
        keyed.begin()
        await keyed.applyLive(snapshot("there.", run: "c", complete: true))
        #expect(keys.keys.isEmpty)
        await keyed.finish()
        #expect(keys.value == "Hi there.")
    }
    @Test func anElementThatReadsButTakesNoWritesOrKeysKeepsTextInThePanel() async throws {
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
        #expect(inserts.isEmpty && copied.isEmpty)
        #expect(editor.panel.recoveryText == "more")
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
        // The trial keeps a 5 ms gap between typed characters, with none after the last one.
        #expect(pauses == [.milliseconds(5)])
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
        #expect(copied.isEmpty)
        #expect(editor.panel.recoveryText == "cXYZ unchanged tail")
    }

}
#endif
