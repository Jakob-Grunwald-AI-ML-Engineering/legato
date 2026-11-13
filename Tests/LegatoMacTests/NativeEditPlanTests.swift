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
        value = (value as NSString).replacingCharacters(in: NSRange(location: range.location, length: range.length), with: text)
        selection = .init(location: range.location + text.utf16.count, length: 0)
        writes += 1; snapshots.append(value)
        if let limit = loseFocusAfter, writes >= limit { focused = false }
    }
}

@MainActor @Suite struct NativePlanQueueTests {
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
