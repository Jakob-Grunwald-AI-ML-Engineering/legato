import Foundation
import Testing
@testable import LegatoCore

struct StyleDiagnosticEventTests {
    @Test func emojiChangesCountVisibleGlyphsAndTheWireContainsOnlyMetadata() throws {
        let take = UUID(), id = UUID()
        let event = StyleDiagnosticEvent(takeID: take, platform: .macOS, action: .magic,
            before: "Private draft 2026. 👩🏽‍💻 🇩🇪 🇩🇪", after: "Private draft #1. 👩🏽‍💻 🇩🇪 1️⃣ ♥️",
            instruction: "Add an emoji!", eventID: id, at: Date(timeIntervalSince1970: 12))
        #expect(event.emojiAdded == 2)
        #expect(event.emojiRemoved == 1)
        #expect(event.instruction == .addEmoji)
        let data = try JSONEncoder().encode(event)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(object.keys) == ["v", "takeID", "platform", "action", "atMs", "eventID", "context",
                                     "emojiAdded", "emojiRemoved", "instruction"])
        #expect(try JSONDecoder().decode(StyleDiagnosticEvent.self, from: data) == event)
        #expect(!String(decoding: data, as: UTF8.self).contains("Private"))
    }

    @Test func disabledLearningSkipsObservationsAndDeletionStillRetractsEarlierEvidence() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = CorrectionStore(root: root)
        let log = StyleDiagnosticLog(directory: root, platform: .macOS, settingsRoot: root)
        let file = root.appendingPathComponent("style-diag.jsonl")
        let take = UUID()
        func through(_ action: StyleDiagnosticEvent.Action) async throws -> [StyleDiagnosticEvent] {
            // The log writes on a utility queue, which a loaded runner can starve for seconds (release real-deps run).
            let until = ContinuousClock.now + .seconds(30)
            while ContinuousClock.now < until {
                let lines = (try? Data(contentsOf: file))?.split(separator: 10) ?? []
                let rows = try lines.map { try JSONDecoder().decode(StyleDiagnosticEvent.self, from: $0) }
                if rows.last?.action == action { return rows }
                try await Task.sleep(for: .milliseconds(10))
            }
            throw CocoaError(.fileReadUnknown)
        }
        let request = UUID()
        log.record(takeID: take, action: .request, instruction: "no emoji", eventID: request, mode: .send)
        log.record(takeID: take, action: .magic, before: "Hi 🙂", after: "Hi", requestID: request)
        let prior = try await through(.magic)
        #expect(prior.map(\.action) == [.request, .magic])
        #expect(prior.first?.mode == .send)
        #expect(prior.last?.requestID == prior.first?.eventID)

        try await store.setPersonalizationEnabled(false)
        log.record(takeID: take, action: .typed, after: "🙂")
        log.record(takeID: take, action: .deleted)
        let afterDeletion = try await through(.deleted)
        #expect(afterDeletion.map(\.action) == [.request, .magic, .deleted])
    }

    @Test func instructionAttributionAbstainsOnAmbiguousWording() {
        #expect(StyleDiagnosticEvent.Instruction(nil) == .none)
        #expect(StyleDiagnosticEvent.Instruction("Ohne Emojis.") == .avoidEmoji)
        #expect(StyleDiagnosticEvent.Instruction("Quote the words 'add an emoji'") == .other)
        #expect(StyleDiagnosticEvent.Instruction("Don't add an emoji unless I ask") == .other)
        #expect(!StyleDiagnosticEvent.containsEmoji("Call #123 *"))
    }
}
