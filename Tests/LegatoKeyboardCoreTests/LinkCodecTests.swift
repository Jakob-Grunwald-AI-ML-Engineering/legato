import Foundation
import Testing
@testable import LegatoKeyboardCore

@Suite struct LinkCodecTests {
    @Test func hostStateRoundTripsThroughTheStore() {
        let store = LinkStore(MemoryLinkStore())
        let state = HostState(
            runID: "run-1", phase: .listening, target: .keyboard, committed: "hello ", volatile: "wor", seq: 7,
            beatAt: t0, leaseUntil: t0.addingTimeInterval(30), acceptsRemoteStart: true)
        store.write(state, forKey: LinkChannel.Key.host)
        #expect(store.read(HostState.self, forKey: LinkChannel.Key.host) == state)
    }

    @Test func aMissingOrCorruptValueReadsAsNil() {
        let backing = MemoryLinkStore()
        let store = LinkStore(backing)
        #expect(store.read(HostState.self, forKey: LinkChannel.Key.host) == nil)
        backing.set(Data("not json".utf8), forKey: LinkChannel.Key.host)
        #expect(store.read(HostState.self, forKey: LinkChannel.Key.host) == nil)
    }

    @Test func theStoredHostStateHasTheDocumentedKeys() throws {
        let backing = MemoryLinkStore()
        LinkStore(backing).write(hostState(committed: "a", volatile: "b"), forKey: LinkChannel.Key.host)
        let data = try #require(backing.data(forKey: LinkChannel.Key.host))
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        for key in ["v", "runID", "phase", "target", "committed", "volatile", "seq", "beatAt", "acceptsRemoteStart"] {
            #expect(json[key] != nil, "missing \(key)")
        }
        #expect(json["v"] as? Int == 1)
        #expect(json["phase"] as? String == "listening")
        #expect(json["leaseUntil"] == nil) // absent, not null
    }

    @Test func theMeetingFlagIsAbsentUnlessSetAndOldStatesStillDecode() throws {
        let backing = MemoryLinkStore()
        let store = LinkStore(backing)
        store.write(hostState(), forKey: LinkChannel.Key.host)
        let data = try #require(backing.data(forKey: LinkChannel.Key.host))
        let plain = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(plain["meetingRecording"] == nil) // absent, not null: an older keyboard reads the same state
        var meeting = hostState()
        meeting.meetingRecording = true
        store.write(meeting, forKey: LinkChannel.Key.host)
        #expect(store.read(HostState.self, forKey: LinkChannel.Key.host)?.meetingRecording == true)
        store.write(hostState(), forKey: LinkChannel.Key.host)
        #expect(store.read(HostState.self, forKey: LinkChannel.Key.host)?.meetingRecording == nil)
    }

    @Test func requestAckPresenceAndAppliedRoundTrip() {
        let store = LinkStore(MemoryLinkStore())
        let request = KeyboardRequest(id: "req-1", command: .endKeepAlive, at: t0)
        store.write(request, forKey: LinkChannel.Key.request)
        #expect(store.read(KeyboardRequest.self, forKey: LinkChannel.Key.request) == request)
        let ack = KeyboardAck(id: "req-1", result: .hop)
        store.write(ack, forKey: LinkChannel.Key.ack)
        #expect(store.read(KeyboardAck.self, forKey: LinkChannel.Key.ack) == ack)
        let presence = KeyboardPresence(visible: true, at: t0)
        store.write(presence, forKey: LinkChannel.Key.presence)
        #expect(store.read(KeyboardPresence.self, forKey: LinkChannel.Key.presence) == presence)
        let applied = cursor(committedCount: 3, volatile: "x", finalApplied: true)
        store.write(applied, forKey: LinkChannel.Key.applied)
        #expect(store.read(AppliedCursor.self, forKey: LinkChannel.Key.applied) == applied)
    }

    @Test func presenceIsFreshOnlyWhileVisibleAndRecent() {
        let now = t0.addingTimeInterval(1)
        #expect(KeyboardPresence(visible: true, at: t0).isFresh(now: now))
        #expect(!KeyboardPresence(visible: true, at: t0).isFresh(now: t0.addingTimeInterval(LinkChannel.presenceFreshness + 0.1)))
        #expect(!KeyboardPresence(visible: false, at: t0).isFresh(now: now))
    }

    @Test func theKeyboardURLRoundTripsItsCommandAndRequestId() throws {
        let url = KeyboardURL.make(command: .start, requestID: "req-1")
        #expect(url.absoluteString == "legato://keyboard?cmd=start&req=req-1")
        let parsed = try #require(KeyboardURL.parse(url))
        #expect(parsed.command == .start && parsed.requestID == "req-1")
    }

    @Test func theArmURLCarriesTheArmCommand() throws {
        let url = KeyboardURL.make(command: .arm, requestID: "req-1")
        #expect(url.absoluteString == "legato://keyboard?cmd=arm&req=req-1")
        let parsed = try #require(KeyboardURL.parse(url))
        #expect(parsed.command == .arm && parsed.requestID == "req-1")
    }

    @Test func foreignOrIncompleteURLsAreNotKeyboardURLs() {
        #expect(KeyboardURL.parse(URL(string: "legato://copy-last")!) == nil)
        #expect(KeyboardURL.parse(URL(string: "https://keyboard?cmd=start&req=1")!) == nil)
        #expect(KeyboardURL.parse(URL(string: "legato://keyboard?cmd=bogus&req=1")!) == nil)
        #expect(KeyboardURL.parse(URL(string: "legato://keyboard?cmd=start")!) == nil)
        #expect(KeyboardURL.parse(URL(string: "legato://keyboard?req=1")!) == nil)
    }

    @Test func aDarwinNoteReachesItsObserver() async throws {
        let name = "de.gruenwald.legato.link.test.\(UUID().uuidString)"
        let counter = Counter()
        let observer = DarwinObserver(name: name) { counter.bump() }
        DarwinObserver.post(name)
        // A hang guard, not a speed bound: the note arrives whenever the notification centre delivers it.
        let deadline = ContinuousClock.now + .seconds(30)
        while counter.value == 0, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(counter.value == 1)
        withExtendedLifetime(observer) {}
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func bump() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
}
