import Foundation
import LegatoCore
import Testing
@testable import LegatoAppServices

private actor MemoryHistory: HistoryStore {
    private(set) var entries: [DictationEntry] = []
    private var failNext = false

    func failNextAppend() { failNext = true }

    func append(_ entry: DictationEntry) async throws {
        if failNext {
            failNext = false
            throw CancellationError()
        }
        entries.append(entry)
    }

    func recent(limit: Int) async throws -> [DictationEntry] { Array(entries.reversed().prefix(limit)) }
    func delete(id: UUID) async throws { entries.removeAll { $0.id == id } }
}

@Suite struct AgentRunHistoryTests {
    private func entry(_ text: String, raw: String? = nil) -> DictationEntry {
        DictationEntry(date: Date(timeIntervalSince1970: 1), text: text, rawText: raw, localeIdentifier: "en", engineID: "e", duration: 2)
    }

    @Test func theEntryKeepsTheCleanedTextAndTheEnginesAsRaw() throws {
        let saved = entry("Send teh report.")
        let corrected = try #require(AgentRunHistory.corrected(saved, cleaned: " Send the report.\n"))
        #expect(corrected.text == "Send the report.")
        #expect(corrected.rawText == "Send teh report.")
        #expect(corrected.id == saved.id)
        #expect(corrected.duration == saved.duration)
    }

    @Test func nothingChangesWhenCleaningChangedNothingOrFoundNothing() {
        #expect(AgentRunHistory.corrected(entry("Fine."), cleaned: "Fine.") == nil)
        #expect(AgentRunHistory.corrected(entry("Fine."), cleaned: "  ") == nil)
    }

    @Test func replaceSwapsTheSavedEntryForTheCorrectedOne() async {
        let history = MemoryHistory()
        let saved = entry("Send teh report.")
        try? await history.append(saved)
        let result = await AgentRunHistory.replace(saved, cleaned: "Send the report.", in: history)
        #expect(result.rawText == "Send teh report.")
        let stored = await history.entries
        #expect(stored.count == 1)
        #expect(stored.first == result)
    }

    @Test func aFailedReplacementPutsTheOriginalBack() async {
        let history = MemoryHistory()
        let saved = entry("Send teh report.")
        try? await history.append(saved)
        await history.failNextAppend()
        let result = await AgentRunHistory.replace(saved, cleaned: "Send the report.", in: history)
        #expect(result == saved)
        #expect(await history.entries == [saved])
    }
}
