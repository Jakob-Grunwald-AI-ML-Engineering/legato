import Foundation
import Testing
import LegatoKeyboardCore
@testable import LegatoMac

@Suite struct NativeEditPlanTests {
    @Test func anInterruptedUppercaseReplacementRetainsEveryUnprocessedOriginalLetter() {
        let original = "return before sunset and keep every remaining word"
        var plan = NativeEditPlan(current: Array(original), desired: Array(original.uppercased()), paced: true)
        for _ in 0..<9 {
            guard let step = plan.next, let after = plan.afterNext else { Issue.record("plan ended early"); return }
            #expect(step.range.count == 1 && step.replacement.count == 1)
            #expect(String(after).lowercased() == original, "An interrupted replacement never leaves a deleted-word gap")
            let advanced = plan.confirm(after)
            #expect(advanced)
        }
        #expect(plan.expected.count == original.count)
    }

    @Test(arguments: [("a colour boat", "a color boat"), ("abc", "x"), ("x", "abc"), ("a⛵️b", "a🌊b"), ("old tail", ""), ("", "new tail")])
    func cachedStepsReachTheExactTarget(old: String, target: String) {
        var plan = NativeEditPlan(current: Array(old), desired: Array(target), paced: true)
        while let after = plan.afterNext {
            let confirmed = plan.confirm(after)
            #expect(confirmed)
        }
        #expect(String(plan.expected) == target)
        #expect(plan.remainingInsertions == 0)
        #expect(!plan.matches(current: Array("external text"), desired: Array(target), paced: true))
        #expect(!plan.matches(current: plan.expected, desired: Array(target + "changed"), paced: true))
    }
}

@MainActor private final class NativePlanField: TextTarget {
    var value: String
    var selection: UTF16Range
    var focused = true
    var writes = 0
    var snapshots: [String] = []
    var loseFocusAfter: Int?
    var readsFailAfterWrite = false
    var ignoreWrites = false
    init(_ text: String) { value = text; selection = .init(location: text.utf16.count, length: 0) }
    func isFocused() -> Bool { focused }
    func selectedRange() throws -> UTF16Range { selection }
    func textLength() throws -> Int { value.utf16.count }
    func text(in range: UTF16Range) throws -> String {
        if readsFailAfterWrite, writes > 0 { throw TextTargetReadError.unsupported }
        let at = min(range.location, value.utf16.count)
        return (value as NSString).substring(with: NSRange(location: at, length: min(range.length, value.utf16.count - at)))
    }
    func setSelectedRange(_ range: UTF16Range) throws { selection = range }
    func replace(_ range: UTF16Range, with text: String) throws {
        if ignoreWrites { writes += 1; return }
        value = (value as NSString).replacingCharacters(in: NSRange(location: range.location, length: range.length), with: text)
        selection = .init(location: range.location + text.utf16.count, length: 0)
        writes += 1; snapshots.append(value)
        if let limit = loseFocusAfter, writes >= limit { focused = false }
    }
}

@MainActor @Suite struct NativePlanQueueTests {
    @Test func stoppingATakeCannotReactivateARunAlreadyHandedToThePanel() async {
        let field = NativePlanField("")
        field.ignoreWrites = true
        let queue = MacFieldQueue(target: field)
        queue.paced = { false }
        var clock = ContinuousClock.now
        queue.now = { clock }
        queue.sleep = { duration in clock += duration; await Task.yield() }
        var handovers: [MacFieldQueue.Handover] = []
        queue.onUnreadable = { handovers += $0 }
        queue.live(runID: "failed", version: 1, text: "new speech", speaking: true)
        await queue.whenIdle()
        #expect(handovers.count == 1)
        #expect(handovers.first?.text == "new speech")
        let writes = field.writes
        queue.takeStopped("failed")
        let reactivated = queue.hasWork
        // Keep even a failing regression bounded: a reactivated terminal run must not starve the entire actor.
        if reactivated { queue.reset() }
        await queue.whenIdle()
        #expect(!reactivated)
        queue.live(runID: "failed", version: 2, text: "New speech.", complete: true)
        await queue.whenIdle()
        #expect(field.writes == writes)
        #expect(handovers.count == 1)
    }

    @Test func aStaleBackgroundRegionDoesNotReadAroundBeforeReadableNewSpeech() async {
        let field = NativePlanField("")
        let queue = MacFieldQueue(target: field)
        queue.paced = { false }
        queue.live(runID: "old", version: 1, text: "old fragment", complete: true)
        await queue.whenIdle()
        field.value = "unrelated replacement"
        field.selection = .init(location: field.value.utf16.count, length: 0)
        var recoveryReads = 0
        queue.journal = { if $0.kind == .recovery { recoveryReads += 1 } }
        queue.live(runID: "old", version: 2, text: "OLD FRAGMENT", complete: true)
        queue.live(runID: "new", version: 1, text: "fresh words", speaking: true)
        await queue.whenIdle()
        #expect(field.value == "unrelated replacement fresh words")
        #expect(recoveryReads == 0)
        queue.takeStopped("new")
        await queue.whenIdle()
        #expect(field.value == "unrelated replacement fresh words")
        #expect(recoveryReads > 0)
    }

    @Test func liveSpeechExtendsBeforeItsCoalescedCorrectionsAndMicOffReleasesThem() async {
        let field = NativePlanField("")
        let queue = MacFieldQueue(target: field)
        queue.paced = { false }
        queue.live(runID: "speech", version: 1, text: "we saw a boat", speaking: true)
        await queue.whenIdle()
        queue.live(runID: "speech", version: 2, text: "We saw a boat today", speaking: true)
        await queue.whenIdle()
        #expect(field.value == "we saw a boat today")
        #expect(!queue.hasWork)
        queue.live(runID: "speech", version: 3, text: "WE saw a boat today", speaking: true)
        await queue.whenIdle()
        #expect(field.value == "we saw a boat today")
        queue.takeStopped("speech")
        await queue.whenIdle()
        #expect(field.value == "WE saw a boat today")
    }

    @Test func magicWaitsThroughASpeechPauseWithoutTheParkTimeoutDroppingIt() async {
        let field = NativePlanField("Header old. ")
        let queue = MacFieldQueue(target: field)
        queue.paced = { false }
        queue.live(runID: "speech", version: 1, text: "fresh words", speaking: true)
        await queue.whenIdle()
        var clock = ContinuousClock.now
        queue.now = { clock }
        queue.sleep = { duration in clock += duration; await Task.yield() }
        var admitted = false
        queue.journal = { if $0.kind == .edit { admitted = true } }
        async let result = queue.edit(.init(id: "magic", range: .init(location: 0, length: 12), scope: "Header old. ", target: "Header new. "))
        for _ in 0..<100 where !admitted { await Task.yield() }
        #expect(admitted)
        await queue.whenIdle()
        clock += .seconds(5)
        queue.live(runID: "speech", version: 2, text: "fresh words today", speaking: true)
        await queue.whenIdle()
        #expect(field.value == "Header old. fresh words today")
        queue.takeStopped("speech")
        guard case .applied = await result else { Issue.record("deferred Magic was dropped"); return }
        await queue.whenIdle()
        #expect(field.value == "Header new. fresh words today")
    }

    @Test func aLongVerifiedRewriteBuildsOneDiffInsteadOfDiffingEveryGrapheme() async {
        let original = String(repeating: "return before sunset and keep these words. ", count: 20)
        let field = NativePlanField(original)
        let bound = MacFieldQueue(target: field)
        bound.sleep = { _ in await Task.yield() }
        let result = await bound.edit(.init(range: .init(location: 0, length: original.utf16.count), scope: original, target: original.uppercased()))
        guard case .applied = result else { Issue.record("rewrite did not finish"); return }
        #expect(field.value == original.uppercased())
        #expect(bound.nativePlanBuilds == 1)
        #expect(field.snapshots.allSatisfy { $0.lowercased() == original })
    }

    @Test func focusLossReportsPartialConfirmedWorkAndLeavesUnprocessedLettersIntact() async {
        let original = "return before sunset"
        let field = NativePlanField(original)
        field.loseFocusAfter = 3
        let queue = MacFieldQueue(target: field)
        var clock = ContinuousClock.now
        queue.now = { clock }
        queue.sleep = { duration in clock += duration; await Task.yield() }
        let result = await queue.edit(.init(range: .init(location: 0, length: original.utf16.count), scope: original, target: original.uppercased()))
        #expect(result == .stopped(.focusLost))
        #expect(field.writes == 3)
        #expect(field.value.lowercased() == original)
        #expect(field.value.count == original.count)
    }

    @Test func anOutsidePrefixInvalidatesThePlanAndRemainsUntouched() async {
        let original = "return before sunset"
        let field = NativePlanField("Header " + original)
        let bound = MacFieldQueue(target: field)
        var prefixed = false
        bound.sleep = { [weak bound] _ in
            if field.writes == 3, !prefixed {
                prefixed = true
                field.value = "OUTSIDE " + field.value
                field.selection = .init(location: 8, length: 0)
                bound?.userActed()
            }
            await Task.yield()
        }
        let result = await bound.edit(.init(range: .init(location: 7, length: original.utf16.count), scope: original,
                                            before: "Header ", target: original.uppercased()))
        guard case .applied = result else { Issue.record("prefix interrupted the unchanged owned scope"); return }
        #expect(field.value == "OUTSIDE Header " + original.uppercased())
        #expect(bound.nativePlanBuilds == 2)
        #expect(field.selection == .init(location: 8, length: 0))
    }
    @Test func anUnconfirmedFirstWriteRemainsUncertainWhenFocusIsLost() async {
        let original = "return before sunset"
        let field = NativePlanField(original)
        field.loseFocusAfter = 1
        field.readsFailAfterWrite = true
        let queue = MacFieldQueue(target: field)
        var clock = ContinuousClock.now
        queue.now = { clock }
        queue.sleep = { duration in clock += duration; await Task.yield() }
        let result = await queue.edit(.init(range: .init(location: 0, length: original.utf16.count), scope: original, target: original.uppercased()))
        #expect(field.value != original)
        #expect(result == .dropped(.failed), "An issued but unconfirmed write cannot claim the field was untouched")
        #expect(field.value.lowercased() == original)
    }

}
