import Foundation
import Testing
import LegatoKeyboardCore
@testable import LegatoMac

@MainActor private final class RecoveryAXField: TextTarget {
    var value = "Prefix "
    var selection = UTF16Range(location: 7, length: 0)
    var staleOnce: String?
    var staleReads = 0
    var reads = 0
    func isFocused() -> Bool { true }
    func selectedRange() throws -> UTF16Range { selection }
    func textLength() throws -> Int { value.utf16.count }
    func text(in range: UTF16Range) throws -> String {
        reads += 1
        let source: String
        if staleReads > 0 { staleReads -= 1; source = "An unrelated stale observation" }
        else if let staleOnce { source = staleOnce; self.staleOnce = nil } else { source = value }
        let start = min(range.location, source.utf16.count)
        return (source as NSString).substring(with: NSRange(location: start, length: min(range.length, source.utf16.count - start)))
    }
    func replace(_ range: UTF16Range, with text: String) throws {
        value = (value as NSString).replacingCharacters(in: NSRange(location: range.location, length: range.length), with: text)
        selection = .init(location: range.location + text.utf16.count, length: 0)
    }
    func setSelectedRange(_ range: UTF16Range) throws { selection = range }
}

@MainActor @Suite struct DesktopRecoveryIntegrationTests {
    @Test func nearbyRecoveryCannotHideADuplicateAlreadySeenInTheBroaderDocument() async {
        let field = RecoveryAXField()
        let prefix = "Unchanged prefix "
        let phrase = "Keep three Stay"
        field.value = prefix
        field.selection = .init(location: prefix.utf16.count, length: 0)
        let queue = MacFieldQueue(target: field)
        queue.paced = { false }
        var clock = ContinuousClock.now
        queue.now = { clock }
        queue.sleep = { duration in clock += duration; await Task.yield() }
        queue.live(runID: "take", version: 1, text: phrase)
        await queue.whenIdle()
        let duplicated = "Moved " + prefix + phrase + String(repeating: " padding ", count: 80) + prefix + phrase
        field.value = duplicated
        field.selection = .init(location: duplicated.utf16.count, length: 0)
        var journal: [MacEditJournal.Entry] = []
        queue.journal = { journal.append($0) }
        queue.live(runID: "take", version: 2, text: "Keep four Stay", complete: true)
        await queue.whenIdle()
        #expect(field.value == duplicated, "Neither indistinguishable copy can be chosen for a destructive revision")
        #expect(journal.contains { $0.kind == .recovery && $0.reason == "changedOrAmbiguous" })
        #expect(!journal.contains { $0.kind == .recovery && $0.detail?.contains("unique replan") == true })
    }

    @Test func anUnexpectedAXMismatchUsesFreshEvidenceAndTheSharedRecoveryDecision() async {
        let field = RecoveryAXField()
        let bound = MacFieldQueue(target: field)
        bound.paced = { false }
        var journal: [MacEditJournal.Entry] = []
        bound.journal = { journal.append($0) }
        bound.live(runID: "take", version: 1, text: "Keep three Stay")
        await bound.whenIdle()
        field.value = "Added " + field.value
        field.selection = .init(location: field.value.utf16.count, length: 0)
        field.staleOnce = "An unrelated stale observation"
        bound.live(runID: "take", version: 2, text: "Keep four Stay", complete: true)
        await bound.whenIdle()
        #expect(field.value == "Added Prefix Keep four Stay")
        #expect(journal.contains { $0.kind == .recovery && $0.detail?.contains("unique replan") == true })
        #expect(field.reads > 2)
    }
    @Test func anUnplaceableMagicEditBuildsItsRegionOnlyFromTheFreshRecoveryObservation() async {
        let field = RecoveryAXField()
        field.value = "Prefix Keep three Stay"
        field.selection = .init(location: field.value.utf16.count, length: 0)
        field.staleReads = 9 // the old report persists through the place-grace window, then the recovery read is fresh
        let queue = MacFieldQueue(target: field)
        queue.paced = { false }
        var clock = ContinuousClock.now
        queue.now = { clock }
        queue.sleep = { duration in clock += duration; await Task.yield() }
        var journal: [MacEditJournal.Entry] = []
        queue.journal = { journal.append($0) }
        let result = await queue.edit(.init(id: "magic", range: .init(location: 7, length: 15), scope: "Keep three Stay",
                                            before: "Prefix ", target: "Keep four Stay"))
        guard case .applied = result else { Issue.record("freshly recovered Magic scope was dropped"); return }
        #expect(field.value == "Prefix Keep four Stay")
        #expect(journal.contains { $0.kind == .recovery && $0.detail?.contains("unique replan") == true })
    }

}
