import Foundation
import Testing
import LegatoComposerDoc
@testable import LegatoComposerUI

struct DictationShineTests {
    @Test func newValidationTargetsOnlyItsWordsAndReopeningDoesNotReplay() {
        let old = DictationCommit(sequence: 1, wordIDs: ["earlier"], uptime: 10)
        let fresh = DictationCommit(sequence: 2, wordIDs: ["new-a", "new-b"], uptime: 10.1)
        var admission = DictationShineAdmission()
        admission.baseline(old)
        admission.accept(old, now: 10.2)
        #expect(admission.active == nil)
        admission.accept(fresh, now: 10.2)
        let plan = DictationShinePlan(admission.active, words: [Word(id: "earlier", text: "Earlier"), Word(id: "new-a", text: "New")], now: 10.2)
        #expect(plan?.ranks == ["new-a": 0])
        #expect(plan?.progress(for: "earlier", overall: 0.5) == nil)
        admission.accept(fresh, now: 10.3)
        #expect(admission.active == fresh)
        admission.baseline(fresh)
        admission.accept(fresh, now: 10.4)
        #expect(admission.active == nil)
    }
    @Test func longCommitKeepsRecentVisibleWordsAndOneSharedDurationBudget() {
        let ids = (0..<120).map { "w\($0)" }
        let commit = DictationCommit(sequence: 3, wordIDs: ids, uptime: 10)
        #expect(commit.wordIDs == Array(ids.suffix(64)))
        let words = commit.wordIDs.map { Word(id: $0, text: $0) }
        let plan = DictationShinePlan(commit, words: words, now: 10.2)
        #expect(plan?.ranks.count == 64)
        #expect(plan?.progress(for: "w0", overall: 0.5) == nil)
        #expect(plan?.progress(for: "w56", overall: 0.3) ?? 0 > plan?.progress(for: "w119", overall: 0.3) ?? 0)
        #expect(plan?.progress(for: "w119", overall: 1) == 1)
        #expect(DictationShinePlan.duration <= 0.7)
    }
    @Test func staleOrInvalidEventsCannotStartAnOffscreenReplay() {
        var admission = DictationShineAdmission()
        admission.accept(.init(sequence: 1, wordIDs: ["old"], uptime: 5), now: 10)
        #expect(admission.active == nil)
        #expect(DictationShinePlan(.init(sequence: 1, wordIDs: ["old"], uptime: 5), words: [Word(id: "old", text: "Old")], now: 10) == nil)
        admission.accept(.init(sequence: 2, wordIDs: ["future"], uptime: 11), now: 10)
        #expect(admission.active == nil)
        admission.accept(.init(sequence: 3, wordIDs: ["bad"], uptime: .nan), now: 10)
        #expect(admission.active == nil)
    }
}
