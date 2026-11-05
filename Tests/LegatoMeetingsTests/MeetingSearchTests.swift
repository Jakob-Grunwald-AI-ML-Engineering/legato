import Foundation
import Testing
@testable import LegatoMeetings

@Suite struct MeetingSearchTests {
    @Test func storeSearchReadsSummariesNotesAndTranscript() async throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(root: root)
        let m = Meeting(title: "Sync", date: Date(timeIntervalSince1970: 1), state: .finished)
        try await store.create(m)
        try await store.appendSegment(MeetingSegment(text: "Gespräch über Zürich", start: 1, end: 2), to: m.id)
        try await store.saveSummary("Pricing was settled.", backendID: "claude", for: m.id)
        try await store.saveNotes("Call the notary", for: m.id)
        for words in ["zurich", "PRICING", "notary", "sync", "notary zurich"] {
            #expect(await store.matches(words, meeting: m), "\(words)")
        }
        #expect(await !store.matches("invoice", meeting: m))
        #expect(await !store.matches("notary invoice", meeting: m))
    }
}
