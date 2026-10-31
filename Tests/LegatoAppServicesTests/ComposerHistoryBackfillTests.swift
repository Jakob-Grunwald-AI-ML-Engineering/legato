import Foundation
import Testing
import LegatoCore
@testable import LegatoAppServices

/// Synthetic session directories only; no recorded user data.
@MainActor struct ComposerHistoryBackfillTests {
    private func root() -> URL { FileManager.default.temporaryDirectory.appending(path: "backfill-" + UUID().uuidString) }

    @discardableResult
    private func session(_ root: URL, id: UUID = UUID(), source: String? = "microphone.soniox", done: Bool = true,
                         text: String = "Synthetic draft", age: TimeInterval = 0, filler: Int = 0) throws -> UUID {
        let dir = root.appending(path: id.uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var lines: [String] = []
        if let source { lines.append(#"{"seq":1,"channel":"session","payload":{"event":"input.source","inputSource":"\#(source)"}}"#) }
        for n in 0..<filler { lines.append(#"{"seq":\#(n + 2),"channel":"agent.status","payload":{"event":"response.delta","data":"\#(String(repeating: "x", count: 400))"}}"#) }
        lines.append(#"{"seq":900,"channel":"session","payload":{"event":"paused","state":"paused"}}"#)
        if done { lines.append(#"{"seq":901,"channel":"session","payload":{"event":"done","state":"done","reason":"insert"}}"#) }
        try (lines.joined(separator: "\n") + "\n").write(to: dir.appending(path: "room.jsonl"), atomically: true, encoding: .utf8)
        let final = dir.appending(path: "final.md")
        try text.write(to: final, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-age)], ofItemAtPath: final.path)
        return id
    }

    @Test func importsOnlyCompletedMicrophoneSessionsAndIsIdempotent() async throws {
        let sessions = root(); defer { try? FileManager.default.removeItem(at: sessions) }
        let store = JSONLHistoryStore(fileURL: sessions.appending(path: "history.jsonl"))
        let good = try session(sessions, filler: 1_000)   // log far larger than the head and tail windows
        try session(sessions, source: "debug.transcriber")
        try session(sessions, source: "debug.seed")
        try session(sessions, source: nil)
        try session(sessions, done: false)                // paused: final.md exists but no done event
        try session(sessions, text: "  \n")
        let current = try session(sessions)
        try FileManager.default.createDirectory(at: sessions.appending(path: "not-a-uuid"), withIntermediateDirectories: true)
        let marker = sessions.appending(path: "marker")
        let imported = await ComposerHistoryBackfill.run(sessionsRoot: sessions, history: store, excluding: [current], markerURL: marker)
        #expect(imported == 1)
        let rows = try await store.recent(limit: 10)
        #expect(rows.map(\.id) == [good] && rows[0].engineID == "composer.recovered" && rows[0].text == "Synthetic draft")
        try FileManager.default.removeItem(at: marker)
        #expect(await ComposerHistoryBackfill.run(sessionsRoot: sessions, history: store, excluding: [current], markerURL: marker) == 0)
        #expect(try await store.recent(limit: 10).count == 1)
    }

    @Test func existingEntriesAreSkippedAndAtMostFiftyNewestAreConsidered() async throws {
        let sessions = root(); defer { try? FileManager.default.removeItem(at: sessions) }
        let store = JSONLHistoryStore(fileURL: sessions.appending(path: "history.jsonl"))
        let ids = try (0..<60).map { try session(sessions, text: "Draft \($0)", age: TimeInterval(60 - $0)) }
        let existing = DictationEntry(id: ids[59], date: Date(), text: "Already here", localeIdentifier: "en", engineID: "composer", duration: 1)
        try await store.upsert(existing)
        #expect(await ComposerHistoryBackfill.run(sessionsRoot: sessions, history: store, excluding: [], markerURL: nil) == 49)
        let rows = try await store.recent(limit: 100)
        #expect(rows.count == 50)
        #expect(rows.first { $0.id == ids[59] }?.text == "Already here")
        #expect(!rows.contains { $0.id == ids[0] })
    }

    @Test func markerStopsLaterRunsSoDeletedEntriesStayDeleted() async throws {
        let sessions = root(); defer { try? FileManager.default.removeItem(at: sessions) }
        let store = JSONLHistoryStore(fileURL: sessions.appending(path: "history.jsonl"))
        let id = try session(sessions)
        let marker = sessions.appending(path: "marker")
        #expect(await ComposerHistoryBackfill.run(sessionsRoot: sessions, history: store, excluding: [], markerURL: marker) == 1)
        try await store.delete(id: id)
        #expect(await ComposerHistoryBackfill.run(sessionsRoot: sessions, history: store, excluding: [], markerURL: marker) == 0)
        #expect(try await store.recent(limit: 10).isEmpty)
    }
}
