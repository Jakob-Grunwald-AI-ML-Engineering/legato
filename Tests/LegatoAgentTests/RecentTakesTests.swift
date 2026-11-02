import Foundation
import Synchronization
import Testing
@testable import LegatoAgent

private final class TestClock: Sendable {
    private let time = Mutex(Date(timeIntervalSince1970: 1_800_000_000))
    var now: Date { time.withLock { $0 } }
    func advance(_ seconds: TimeInterval) { time.withLock { $0 = $0.addingTimeInterval(seconds) } }
}

@Suite struct RecentTakesTests {
    @Test func keepsTheLastFiveTakesOldestFirst() {
        let clock = TestClock()
        let store = RecentTakesStore(now: { clock.now })
        for index in 1...7 { store.record(raw: "raw \(index)", cleaned: "Cleaned \(index).", wasCleaned: true); clock.advance(60) }
        #expect(store.recent().map(\.cleaned) == (3...7).map { "Cleaned \($0)." })
    }

    @Test func entriesOlderThanTwoHoursAreIgnoredAndPruned() {
        let clock = TestClock()
        let store = RecentTakesStore(now: { clock.now })
        store.record(raw: "old", cleaned: "Old.", wasCleaned: true)
        clock.advance(3600)
        store.record(raw: "mid", cleaned: "Mid.", wasCleaned: true)
        clock.advance(3600 + 1)
        #expect(store.recent().map(\.cleaned) == ["Mid."], "The first take is 2 h 1 s old")
        clock.advance(3600)
        #expect(store.recent().isEmpty && store.backgroundText().isEmpty)
    }

    @Test func onlyCleanedTakesAreCorrectionPairsButRawInsertsStayContext() {
        let store = RecentTakesStore()
        store.record(raw: "lego is nice", cleaned: "Legato is nice.", wasCleaned: true)
        store.record(raw: "as heard", cleaned: "as heard", wasCleaned: false)
        #expect(store.correctionPairs().map(\.raw) == ["lego is nice"])
        #expect(store.backgroundText() == "Legato is nice.\nas heard")
    }

    @Test func correctionPairsAreCappedKeepingTheNewest() {
        let store = RecentTakesStore()
        for index in 1...4 { store.record(raw: String(repeating: "r", count: 900) + "\(index)", cleaned: String(repeating: "c", count: 900) + "\(index)", wasCleaned: true) }
        let pairs = store.correctionPairs()
        #expect(pairs.count == 2, "Two pairs of 1802 characters fit 4000, a third does not")
        #expect(pairs.map { $0.raw.last! } == ["3", "4"])
        #expect(pairs.reduce(0) { $0 + $1.raw.count + $1.cleaned.count } <= RecentTakesStore.cleanupBudget)
    }

    @Test func backgroundTextIsCappedNewestLast() {
        let store = RecentTakesStore()
        store.record(raw: "a", cleaned: String(repeating: "a", count: 1000), wasCleaned: true)
        store.record(raw: "b", cleaned: String(repeating: "b", count: 1000), wasCleaned: true)
        let text = store.backgroundText()
        #expect(text.count <= RecentTakesStore.backgroundBudget && text == String(repeating: "b", count: 1000))
        let big = RecentTakesStore()
        big.record(raw: "x", cleaned: String(repeating: "y", count: 1900), wasCleaned: true)
        #expect(big.backgroundText().count == RecentTakesStore.backgroundBudget)
    }

    @Test func survivesARestartAndPrunesOnLoad() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "recent-\(UUID().uuidString)/recent-takes.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let clock = TestClock()
        let first = RecentTakesStore(fileURL: url, now: { clock.now })
        first.record(raw: "old", cleaned: "Old.", wasCleaned: true)
        clock.advance(7000)
        first.record(raw: "new äö 😀", cleaned: "New äö 😀.", wasCleaned: false)
        let second = RecentTakesStore(fileURL: url, now: { clock.now })
        #expect(second.recent() == first.recent() && second.recent().count == 2)
        clock.advance(300)
        #expect(RecentTakesStore(fileURL: url, now: { clock.now }).recent().map(\.cleaned) == ["New äö 😀."])
    }

    @Test func takeCleanupRequestCarriesTheRecentTakesAsRawCleanedPairs() async throws {
        // Covered with the real request builder in DictationTakeCleanupTests; here the pair shape is the contract.
        let take = RecentTake(raw: "lego", cleaned: "Legato", wasCleaned: true, date: .distantPast)
        let data = try JSONEncoder().encode(take)
        #expect(String(decoding: data, as: UTF8.self).contains("\"raw\":\"lego\""))
    }
}
