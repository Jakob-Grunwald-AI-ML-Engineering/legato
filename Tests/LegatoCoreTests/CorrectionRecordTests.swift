import Foundation
import Testing
@testable import LegatoCore

struct CorrectionRecordTests {
    private let start = Date(timeIntervalSince1970: 100)
    private func tracker(_ inserted: String = "Hello John.", snapshot: String = "Before Hello John. After") throws -> CorrectionTracker {
        try #require(CorrectionTracker(dictationID: "take-1", rawText: "hello john", insertedText: inserted,
            snapshot: snapshot, platform: "test", localeIdentifier: "en", now: start))
    }

    @Test func groupsBackspacesAndReplacementIntoOneSettledCorrection() throws {
        var value = try tracker()
        value.observe("Before Hello Joh. After", origin: .keyboard, now: start.addingTimeInterval(0.1))
        value.observe("Before Hello Joan. After", origin: .keyboard, now: start.addingTimeInterval(0.4))
        let noRecordvalue = value.settle(now: start.addingTimeInterval(1))
        #expect(noRecordvalue == nil)
        let settled = value.settle(now: start.addingTimeInterval(1.5))
        let record = try #require(settled)
        #expect(record.beforeText == "Hello John.")
        #expect(record.afterText == "Hello Joan.")
        #expect(record.rawText == "hello john")
        #expect(record.insertedText == "Hello John.")
        #expect(record.removed == "John.")
        #expect(record.replacement == "Joan.")
        #expect(record.origin == .keyboard)
        let noFurtherRecord = value.settle(now: start.addingTimeInterval(3))
        #expect(noFurtherRecord == nil)
    }

    @Test func styleRewritesAndUnicodeRemainExact() throws {
        var value = try tracker("Grüße 👩🏽‍💻!", snapshot: "Grüße 👩🏽‍💻!")
        value.observe("Hallo 👩🏽‍💻.\nBis bald!", origin: .observedHost, now: start)
        let settled = value.settle(now: start.addingTimeInterval(2))
        let record = try #require(settled)
        #expect(record.afterText == "Hallo 👩🏽‍💻.\nBis bald!")
        #expect(record.origin == .observedHost)
    }

    @Test func unchangedSnapshotsDoNotGenerateCorrections() throws {
        var value = try tracker()
        value.observe("Before Hello John. After", origin: .observedHost, now: start)
        let noRecordvalue = value.settle(now: start.addingTimeInterval(3))
        #expect(noRecordvalue == nil)
    }

    @Test func shiftingWindowOrUnrelatedTextRetiresCapture() throws {
        var value = try tracker()
        value.observe("Hello Joan. After", origin: .observedHost, now: start)
        #expect(!value.active)
        let noRecordvalue = value.settle(now: start.addingTimeInterval(2))
        #expect(noRecordvalue == nil)
    }

    @Test func clearSendAndExpiryAreNotCorrections() throws {
        var clear = try tracker("Hello", snapshot: "Hello")
        clear.observe("", origin: .keyboard, now: start)
        #expect(!clear.active)
        var expired = try tracker()
        expired.observe("Before Hello Joan. After", origin: .observedHost, now: start.addingTimeInterval(601))
        #expect(!expired.active)
    }

    @Test func fieldCapitalizationIsPartOfDeliveredBaseline() throws {
        var value = try tracker("hello John.", snapshot: "Hello John.")
        value.observe("Hello Joan.", origin: .keyboard, now: start)
        let settled = value.settle(now: start.addingTimeInterval(2))
        let record = try #require(settled)
        #expect(record.insertedText == "Hello John.")
    }

    @Test func ambiguousScopeIsNotArmed() {
        #expect(CorrectionTracker(dictationID: "x", rawText: "hi", insertedText: "hi", snapshot: "hi hi",
                                  platform: "test", localeIdentifier: "en") == nil)
    }

    @Test func revertingBeforeSettlingTeachesNothing() throws {
        var value = try tracker()
        value.observe("Before Hello Joan. After", origin: .keyboard, now: start)
        value.observe("Before Hello John. After", origin: .keyboard, now: start.addingTimeInterval(0.5))
        let noRecordvalue = value.settle(now: start.addingTimeInterval(2))
        #expect(noRecordvalue == nil)
    }

    @Test func independentWritersAndDeletePreserveOtherEvidence() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = CorrectionStore(root: root), second = CorrectionStore(root: root)
        var value = try tracker()
        value.observe("Before Hello Joan. After", origin: .observedHost, now: start)
        let settled = value.settle(now: start.addingTimeInterval(2))
        let record = try #require(settled)
        var other = record; other.id = UUID(); other.date = record.date.addingTimeInterval(1)
        try await store.append(record)
        try await second.append(other)
        #expect(try await store.recent().map(\.id) == [other.id, record.id])
        try await second.delete(id: record.id)
        #expect(try await store.recent().map(\.id) == [other.id])
    }
}
