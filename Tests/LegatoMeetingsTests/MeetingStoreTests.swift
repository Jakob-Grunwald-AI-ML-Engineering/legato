import Foundation
import Testing
import LegatoCore
@testable import LegatoMeetings

@Suite struct MeetingStoreTests {
    func meeting(_ title: String, at t: TimeInterval) -> Meeting {
        Meeting(title: title, date: Date(timeIntervalSince1970: t), engineID: "fake")
    }

    func seg(_ text: String, _ start: TimeInterval) -> MeetingSegment {
        MeetingSegment(stream: .mic, text: text, start: start, end: start + 1)
    }

    @Test func createThenReadBack() async throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(root: root)
        let m = meeting("Sync", at: 1)
        try await store.create(m)
        #expect(try await store.meeting(id: m.id) == m)
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent(m.id.uuidString).appendingPathComponent("meeting.json").path))
    }

    @Test func unknownMeetingIsNil() async throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(try await MeetingStore(root: root).meeting(id: UUID()) == nil)
    }

    @Test func meetingsListNewestFirst() async throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(root: root)
        let a = meeting("a", at: 1), b = meeting("b", at: 3), c = meeting("c", at: 2)
        for m in [a, b, c] { try await store.create(m) }
        #expect(try await store.meetings().map(\.title) == ["b", "c", "a"])
    }

    @Test func updateReplacesMeeting() async throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(root: root)
        var m = meeting("Sync", at: 1)
        try await store.create(m)
        m.state = .finished
        m.duration = 90
        try await store.update(m)
        #expect(try await store.meeting(id: m.id) == m)
    }

    @Test func segmentsSurviveAReopenInTheMiddleOfAMeeting() async throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let m = meeting("Sync", at: 1)
        let first = MeetingStore(root: root)
        try await first.create(m)
        let a = seg("one", 1), b = seg("two", 5)
        try await first.appendSegment(a, to: m.id)
        try await first.appendSegment(b, to: m.id)

        let reopened = MeetingStore(root: root)
        #expect(try await reopened.segments(for: m.id) == [a, b])
        let c = seg("three", 9)
        try await reopened.appendSegment(c, to: m.id)
        #expect(try await reopened.segments(for: m.id) == [a, b, c])
    }

    @Test func segmentsComeBackOrderedByStart() async throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(root: root)
        let m = meeting("Sync", at: 1)
        try await store.create(m)
        for s in [seg("late", 9), seg("early", 1), seg("mid", 5)] { try await store.appendSegment(s, to: m.id) }
        #expect(try await store.segments(for: m.id).map(\.text) == ["early", "mid", "late"])
    }

    @Test func replaceSegmentsRewritesThem() async throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(root: root)
        let m = meeting("Sync", at: 1)
        try await store.create(m)
        try await store.appendSegment(seg("old", 1), to: m.id)
        let fresh = [seg("new", 2)]
        try await store.replaceSegments(fresh, for: m.id)
        #expect(try await store.segments(for: m.id) == fresh)
    }

    @Test func segmentsOfAMeetingWithNoneAreEmpty() async throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(root: root)
        let m = meeting("Sync", at: 1)
        try await store.create(m)
        #expect(try await store.segments(for: m.id).isEmpty)
    }
}
