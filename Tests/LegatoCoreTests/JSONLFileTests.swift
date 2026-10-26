import Foundation
import Testing
@testable import LegatoCore

@Suite struct JSONLFileTests {
    struct Row: Codable, Sendable, Equatable {
        var id: Int
        var text: String
        var at: Date
    }

    func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("legato-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("rows.jsonl")
    }

    func row(_ id: Int, _ text: String = "x") -> Row { Row(id: id, text: text, at: Date(timeIntervalSince1970: 100)) }

    @Test func appendThenElementsInOrder() async throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let file = JSONLFile<Row>(fileURL: url)
        for i in 1...3 { try await file.append(row(i)) }
        #expect(try await file.elements() == [row(1), row(2), row(3)])
    }

    @Test func missingFileIsEmpty() async throws {
        #expect(try await JSONLFile<Row>(fileURL: tempURL()).elements().isEmpty)
    }

    @Test func datesAreWrittenAsMilliseconds() async throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let file = JSONLFile<Row>(fileURL: url)
        try await file.append(Row(id: 1, text: "a", at: Date(timeIntervalSince1970: 1.5)))
        #expect(try String(contentsOf: url, encoding: .utf8).contains("\"at\":1500"))
    }

    @Test func partialLineIsRepairedBeforeNextAppend() async throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let file = JSONLFile<Row>(fileURL: url)
        try await file.append(row(1))
        let h = try FileHandle(forWritingTo: url)
        try h.seekToEnd()
        try h.write(contentsOf: Data("{\"id\":".utf8))
        try h.close()
        try await file.append(row(2))
        #expect(try await file.elements() == [row(1), row(2)])
    }

    @Test func removeKeepsCorruptLines() async throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let file = JSONLFile<Row>(fileURL: url)
        try await file.append(row(1))
        let h = try FileHandle(forWritingTo: url)
        try h.seekToEnd()
        try h.write(contentsOf: Data("not json\n".utf8))
        try h.close()
        try await file.append(row(2))
        try await file.remove { $0.id == 1 }
        #expect(try await file.elements() == [row(2)])
        #expect(try String(contentsOf: url, encoding: .utf8).contains("not json"))
    }

    @Test func removeWithNoMatchLeavesFileUntouched() async throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let file = JSONLFile<Row>(fileURL: url)
        try await file.append(row(1))
        let before = try Data(contentsOf: url)
        try await file.remove { $0.id == 9 }
        #expect(try Data(contentsOf: url) == before)
    }

    @Test func replaceAllRewritesTheFile() async throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let file = JSONLFile<Row>(fileURL: url)
        for i in 1...3 { try await file.append(row(i)) }
        try await file.replaceAll([row(7), row(8)])
        #expect(try await file.elements() == [row(7), row(8)])
        try await file.append(row(9))
        #expect(try await file.elements() == [row(7), row(8), row(9)])
    }
}
