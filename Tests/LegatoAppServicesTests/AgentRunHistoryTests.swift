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

    @Test func anEntryTheFieldDidNotFullyGetShowsTheFieldsTextWithTheCleanedTextAsItsOtherVersion() throws {
        let saved = entry("The cat sat. A dog ran.", raw: "teh cat sat. a dgo ran.")  // a Replace run: the session's cleaned text
        let shown = try #require(AgentRunHistory.shown(saved, field: "teh cat sat. A dog ran.", cleaned: "The cat sat. A dog ran."))
        #expect(shown.text == "teh cat sat. A dog ran.")
        #expect(shown.rawText == "The cat sat. A dog ran.")
        #expect(shown.id == saved.id)
        #expect(AgentRunHistory.shown(saved, field: "The cat sat. A dog ran.", cleaned: "The cat sat. A dog ran.") == nil)
        #expect(AgentRunHistory.shown(shown, field: "teh cat sat. A dog ran.", cleaned: "The cat sat. A dog ran.") == nil)
    }

    @Test func replaceSwapsTheSavedEntryForTheFieldsVersion() async {
        let history = MemoryHistory()
        let saved = entry("Send the report.", raw: "Send teh report.")
        try? await history.append(saved)
        let result = await AgentRunHistory.replace(saved, field: "Send teh report.", cleaned: "Send the report.", in: history)
        #expect(result.text == "Send teh report." && result.rawText == "Send the report.")
        #expect(await history.entries == [result])
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
