import Foundation
import Testing
import LegatoCore
@testable import LegatoMeetings

@Suite struct MeetingRecoveryTests {
    func meeting(_ state: Meeting.State, duration: TimeInterval = 0) -> Meeting {
        Meeting(title: "m", date: Date(timeIntervalSince1970: 1), duration: duration, engineID: "fake", state: state)
    }

    @Test func aRecordingMeetingIsMarkedInterruptedAndQueuedForTheChain() async throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(root: root)
        let m = meeting(.recording)
        try await store.create(m)

        let queued = try await MeetingRecovery.run(store: store)

        #expect(queued == [m.id])
        #expect(try await store.meeting(id: m.id)?.state == .interrupted)
    }

    @Test func durationBecomesTheEndOfTheLastSavedSegment() async throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(root: root)
        let m = meeting(.recording, duration: 10)
        try await store.create(m)
        try await store.appendSegment(MeetingSegment(stream: .mic, text: "hi", start: 40, end: 42), to: m.id)

        _ = try await MeetingRecovery.run(store: store)

        #expect(try await store.meeting(id: m.id)?.duration == 42)
    }

    @Test func otherStatesAreLeftAlone() async throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(root: root)
        let done = meeting(.finished), busy = meeting(.processing), old = meeting(.interrupted)
        for m in [done, busy, old] { try await store.create(m) }

        let queued = try await MeetingRecovery.run(store: store)

        #expect(queued.isEmpty)
        #expect(try await store.meeting(id: done.id)?.state == .finished)
        #expect(try await store.meeting(id: busy.id)?.state == .processing)
        #expect(try await store.meeting(id: old.id)?.state == .interrupted)
    }

    @Test func aSecondRunQueuesNothing() async throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(root: root)
        try await store.create(meeting(.recording))
        _ = try await MeetingRecovery.run(store: store)
        #expect(try await MeetingRecovery.run(store: store).isEmpty)
    }

    @Test func aMeetingOwnedByALiveSessionIsNotRecovered() async throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(root: root)
        let live = meeting(.recording), crashed = meeting(.recording)
        try await store.create(live)
        try await store.create(crashed)

        let queued = try await MeetingRecovery.run(store: store, excluding: [live.id])

        #expect(queued == [crashed.id])
        #expect(try await store.meeting(id: live.id)?.state == .recording)
        #expect(try await store.meeting(id: crashed.id)?.state == .interrupted)
    }
}
