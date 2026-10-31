import Foundation
import Testing
@testable import LegatoCore

@Suite struct JSONLHistoryStoreTests {
    func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("legato-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("history.jsonl")
    }

    func entry(_ text: String, t: TimeInterval) -> DictationEntry {
        DictationEntry(date: Date(timeIntervalSince1970: t), text: text, localeIdentifier: "en_US", engineID: "fake", duration: 2)
    }

    @Test func appendThenRecentNewestFirst() async throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = JSONLHistoryStore(fileURL: url)
        let a = entry("a", t: 1), b = entry("b", t: 2), c = entry("c", t: 3)
        for e in [a, b, c] { try await store.append(e) }
        #expect(try await store.recent(limit: 10) == [c, b, a])
        #expect(try await store.recent(limit: 2) == [c, b])
    }

    @Test func recentOnMissingFileIsEmpty() async throws {
        let store = JSONLHistoryStore(fileURL: tempURL())
        #expect(try await store.recent(limit: 5).isEmpty)
    }

    @Test func oneJSONObjectPerLine() async throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = JSONLHistoryStore(fileURL: url)
        try await store.append(entry("a\nmultiline", t: 1))
        try await store.append(entry("b", t: 2))
        let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n")
        #expect(lines.count == 2)
    }

    @Test func deleteRemovesOnlyThatEntry() async throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = JSONLHistoryStore(fileURL: url)
        let a = entry("a", t: 1), b = entry("b", t: 2)
        try await store.append(a); try await store.append(b)
        try await store.delete(id: a.id)
        #expect(try await store.recent(limit: 10) == [b])
    }

    @Test func deleteUnknownIdIsNoOp() async throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = JSONLHistoryStore(fileURL: url)
        let a = entry("a", t: 1)
        try await store.append(a)
        try await store.delete(id: UUID())
        #expect(try await store.recent(limit: 10) == [a])
    }

    @Test func corruptLinesAreSkipped() async throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = JSONLHistoryStore(fileURL: url)
        let a = entry("a", t: 1), b = entry("b", t: 2)
        try await store.append(a)
        // Garbage line plus a truncated line without trailing newline.
        let h = try FileHandle(forWritingTo: url)
        try h.seekToEnd()
        try h.write(contentsOf: Data("not json\n{\"id\":".utf8))
        try h.close()
        try await store.append(b)
        #expect(try await store.recent(limit: 10) == [b, a])
        try await store.delete(id: a.id)
        #expect(try await store.recent(limit: 10) == [b])
    }
}

extension JSONLHistoryStoreTests {
    @Test func upsertPreservesOtherRecordsCorruptLinesAndCreatedTimestamp() async throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = JSONLHistoryStore(fileURL: url)
        let original = entry("First draft", t: 1), other = entry("Unrelated", t: 2)
        try await store.append(original); try await store.append(other)
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd(); try handle.write(contentsOf: Data("unreadable record\n".utf8)); try handle.close()
        var revised = original; revised.text = "Edited draft"
        try await store.upsert(revised)
        #expect(try await store.recent(limit: 10) == [revised, other])
        #expect(try String(contentsOf: url, encoding: .utf8).contains("unreadable record"))
        #expect(revised.date == original.date)
    }
}
