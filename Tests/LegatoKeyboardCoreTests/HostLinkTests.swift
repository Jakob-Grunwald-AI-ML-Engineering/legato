import Foundation
import Synchronization
import Testing
@testable import LegatoKeyboardCore

/// Mutable "now" and the Darwin posts, shared with the link under test.
private final class Env: Sendable {
    private let clock = Mutex(t0)
    private let notes = Mutex<[String]>([])
    /// One tick fires one pending beat (`sleep(1 s)`), another clock the throttle's and timeouts' sleeps.
    let beat = TickClock()
    let other = TickClock()
    /// The retention window of a finished run's text.
    let retention = TickClock()

    var now: Date { clock.withLock { $0 } }
    func advance(_ seconds: TimeInterval) { clock.withLock { $0 = $0.addingTimeInterval(seconds) } }
    func post(_ name: String) { notes.withLock { $0.append(name) } }
    func clearPosts() { notes.withLock { $0.removeAll() } }
    var posts: [String] { notes.withLock { $0 } }
    func count(_ name: String) -> Int { posts.filter { $0 == name }.count }
}

/// Manually driven sleep: each sleep waits for one `tick()`; a cancelled sleeper throws and the clock lives on.
private struct TickClock: Sendable {
    private final class Source: Sendable {
        private struct State {
            var pending = 0
            var nextID = 0
            var cancelled = 0
            var waiters: [Int: CheckedContinuation<Void, any Error>] = [:]
        }
        private let state = Mutex(State())
        var pendingCount: Int { state.withLock { $0.waiters.count } }
        var cancelledCount: Int { state.withLock { $0.cancelled } }

        func tick() {
            let waiter = state.withLock { s -> CheckedContinuation<Void, any Error>? in
                if let id = s.waiters.keys.min() { return s.waiters.removeValue(forKey: id) }
                s.pending += 1
                return nil
            }
            waiter?.resume()
        }

        func wait() async throws {
            let id = state.withLock { s -> Int in s.nextID += 1; return s.nextID }
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, any Error>) in
                    enum Next { case resume, cancel, wait }
                    let next = state.withLock { s -> Next in
                        if Task.isCancelled { return .cancel }
                        if s.pending > 0 { s.pending -= 1; return .resume }
                        s.waiters[id] = c
                        return .wait
                    }
                    switch next {
                    case .resume: c.resume()
                    case .cancel: c.resume(throwing: CancellationError())
                    case .wait: break
                    }
                }
            } onCancel: {
                let waiter = state.withLock { s in
                    let waiter = s.waiters.removeValue(forKey: id)
                    if waiter != nil { s.cancelled += 1 }
                    return waiter
                }
                waiter?.resume(throwing: CancellationError())
            }
        }
    }

    private let source = Source()
    func tick() { source.tick() }
    var pendingCount: Int { source.pendingCount }
    var cancelledCount: Int { source.cancelledCount }
    var sleep: @Sendable (Duration) async throws -> Void {
        let source = self.source
        return { _ in try await source.wait() }
    }
}

@MainActor
private struct Rig {
    let env = Env()
    let backing: MemoryLinkStore
    let store: LinkStore
    let link: HostLink
    let received = Received()
    /// What building the link posted (it announces its idle state); cleared so tests count their own publishes.
    let initialPosts: [String]

    init(backing: MemoryLinkStore = MemoryLinkStore()) {
        self.backing = backing
        store = LinkStore(backing)
        let env = self.env
        link = HostLink(
            store: store, post: { env.post($0) }, now: { env.now },
            sleep: { duration in
                if duration == .seconds(LinkChannel.beatInterval) { try await env.beat.sleep(duration) }
                else { try await env.other.sleep(duration) }
            })
        initialPosts = env.posts
        env.clearPosts()
        let received = self.received
        link.onRequest = { received.requests.append($0); return true }
    }

    var host: HostState? { store.read(HostState.self, forKey: LinkChannel.Key.host) }
    var ack: KeyboardAck? { store.read(KeyboardAck.self, forKey: LinkChannel.Key.ack) }

    func send(_ command: RequestCommand, id: String = "req-1", age: TimeInterval = 0) {
        store.write(KeyboardRequest(id: id, command: command, at: env.now.addingTimeInterval(-age)), forKey: LinkChannel.Key.request)
    }

}

@MainActor
private final class Received {
    var requests: [KeyboardRequest] = []
}

@MainActor
/// Polls until `condition` holds or a generous 30 s deadline passes (a hang guard, not a speed bound).
private func eventually(_ condition: @MainActor () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + .seconds(30)
    while ContinuousClock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return condition()
}

@MainActor
@Suite struct HostLinkTests {
    // MARK: a fresh link

    @Test func startingTheLinkOverwritesAStateThatAnEarlierProcessLeftBehind() {
        // The app died mid-run: `link.host` still says "listening" with the run's text. A new process must
        // not leave that for a keyboard to type into some later field.
        let backing = MemoryLinkStore()
        let old = Rig(backing: backing)
        old.link.listeningChanged(true)
        #expect(old.host?.phase == .listening)

        let fresh = Rig(backing: backing)
        let host = fresh.host
        #expect(host?.phase == .idle)
        #expect(host?.leaseUntil == nil && host?.acceptsRemoteStart == false)
        #expect(fresh.initialPosts == [LinkChannel.Note.host]) // keyboards are told
    }

    // MARK: publishing

    @Test func aLeaseKeepsTheBeatGoingAndAllowsRemoteStart() async {
        let r = Rig()
        r.link.listeningChanged(true)
        r.link.listeningChanged(false)
        let until = t0.addingTimeInterval(30)
        r.link.leaseChanged(until: until)
        #expect(r.host?.leaseUntil == until && r.host?.acceptsRemoteStart == true)
        r.env.advance(1)
        r.env.beat.tick()
        #expect(await eventually { r.host?.beatAt == t0.addingTimeInterval(1) })
    }

    @Test func endingTheLeaseStopsRemoteStartAndTheBeat() async throws {
        let r = Rig()
        r.link.leaseChanged(until: t0.addingTimeInterval(30))
        #expect(r.host?.acceptsRemoteStart == true)
        #expect(await eventually { r.env.beat.pendingCount == 1 })
        r.link.leaseChanged(until: nil)
        #expect(await eventually { r.env.beat.cancelledCount == 1 })
        #expect(r.host?.acceptsRemoteStart == false && r.host?.leaseUntil == nil)
        let seq = r.host?.seq
        r.env.advance(1)
        r.env.beat.tick()
        await Task.yield()
        #expect(r.host?.seq == seq)
    }

    @Test func aMeetingIsPublishedAndKeepsTheBeatGoing() async throws {
        let r = Rig()
        #expect(r.host?.meetingRecording == nil)
        r.link.meetingChanged(active: true)
        #expect(r.host?.meetingRecording == true)
        r.env.advance(1)
        r.env.beat.tick()
        #expect(await eventually { r.host?.beatAt == t0.addingTimeInterval(1) })
        #expect(await eventually { r.env.beat.pendingCount == 1 })
        r.link.meetingChanged(active: false)
        #expect(await eventually { r.env.beat.cancelledCount == 1 })
        #expect(r.host?.meetingRecording == nil)
        let seq = r.host?.seq
        r.env.advance(1)
        r.env.beat.tick()
        await Task.yield()
        #expect(r.host?.seq == seq)
    }

    @Test func aStartWhileAMeetingRecordsAsksTheKeyboardToHopSoTheAppCanSayWhy() async {
        let r = Rig()
        r.link.meetingChanged(active: true)
        r.send(.start)
        await r.link.processInbox()
        #expect(r.ack?.result == .hop)
        #expect(r.received.requests.isEmpty)
    }

    // MARK: text does not outlive the run

    @Test func earlyAppCancellationPublishesDurableCompletionForAllAcceptedStartRequests() async throws {
        let r = Rig()
        r.link.leaseChanged(until: t0.addingTimeInterval(30))
        let (gate, release) = AsyncStream<Void>.makeStream()
        var entered = false
        r.link.onRequest = { _ in
            entered = true
            for await _ in gate { break }
            return false
        }
        r.send(.start, id: "first")
        let start = Task { await r.link.processInbox() }
        #expect(await eventually { entered })
        r.send(.start, id: "duplicate")
        await r.link.processInbox()
        r.link.cancelPreparingStart() // App Stop can happen before the keyboard ever reads preparing.
        release.yield(()); release.finish()
        await start.value
        r.env.advance(3)
        r.env.beat.tick()
        #expect(await eventually { r.host?.beatAt == r.env.now })
        let payload = try JSONSerialization.jsonObject(with: JSONEncoder().encode(r.link.state)) as? [String: Any]
        let completion = payload?["startCompletion"] as? [String: Any]
        #expect(completion?["requestIDs"] as? [String] == ["duplicate", "first"])
        #expect(completion?["needsForeground"] as? Bool == false)
        #expect(r.ack == KeyboardAck(id: "duplicate", result: .accepted))
    }

    @Test func aFailedPendingStartPublishesTheResultForItsAcceptedDuplicate() async throws {
        let r = Rig()
        r.link.leaseChanged(until: t0.addingTimeInterval(30))
        let (gate, release) = AsyncStream<Void>.makeStream()
        var entered = false
        r.link.onRequest = { _ in
            entered = true
            for await _ in gate { break }
            return false
        }
        r.send(.start, id: "first")
        let start = Task { await r.link.processInbox() }
        #expect(await eventually { entered })
        r.send(.start, id: "duplicate")
        await r.link.processInbox()
        release.yield(()); release.finish()
        await start.value
        let payload = try JSONSerialization.jsonObject(with: JSONEncoder().encode(r.link.state)) as? [String: Any]
        let completion = payload?["startCompletion"] as? [String: Any]
        #expect(completion?["requestIDs"] as? [String] == ["duplicate", "first"])
        #expect(completion?["needsForeground"] as? Bool == true)
    }

    @Test func preparingAStartPublishesACancellableStateWithoutClaimingToListen() async throws {
        let r = Rig()
        r.link.leaseChanged(until: t0.addingTimeInterval(30))
        let (gate, release) = AsyncStream<Void>.makeStream()
        var entered = false
        r.link.onRequest = { _ in
            entered = true
            for await _ in gate { break }
            return true
        }
        r.send(.start)
        let start = Task { await r.link.processInbox() }
        #expect(await eventually { entered })
        let payload = try JSONSerialization.jsonObject(with: JSONEncoder().encode(r.link.state)) as? [String: Any]
        #expect(payload?["preparingRequestID"] as? String == "req-1")
        #expect(r.host?.phase == .idle)
        #expect(r.host?.phase == .idle)
        #expect(MicKeyMode.resolve(host: r.host, now: r.env.now, fullAccess: true) == .remote(.stop))
        release.yield(()); release.finish()
        await start.value
        #expect(MicKeyMode.resolve(host: r.host, now: r.env.now, fullAccess: true) == .remote(.start))
    }

    @Test func stoppingPreparationKeepsTheStopAckWhenTheCancelledStartReturnsLate() async {
        let r = Rig()
        r.link.leaseChanged(until: t0.addingTimeInterval(30))
        let (gate, release) = AsyncStream<Void>.makeStream()
        var commands: [RequestCommand] = []
        r.link.onRequest = { request in
            commands.append(request.command)
            if request.command == .start {
                for await _ in gate { break }
                return false // cancellation reaches the pending start after the stop was acknowledged
            }
            return true
        }
        r.send(.start)
        let start = Task { await r.link.processInbox() }
        #expect(await eventually { commands == [.start] })
        r.send(.stop, id: "cancel")
        await r.link.processInbox()
        #expect(commands == [.start, .stop])
        #expect(r.ack == KeyboardAck(id: "cancel", result: .accepted))
        release.yield(()); release.finish()
        await start.value
        #expect(r.ack == KeyboardAck(id: "cancel", result: .accepted))
        #expect(MicKeyMode.resolve(host: r.host, now: r.env.now, fullAccess: true) == .remote(.start))
    }

    @Test func aSecondStartWhilePreparationIsPendingDoesNotCreateAnotherAdmissionOrHop() async {
        let r = Rig()
        r.link.leaseChanged(until: t0.addingTimeInterval(30))
        let (gate, release) = AsyncStream<Void>.makeStream()
        var admissions = 0
        r.link.onRequest = { _ in
            admissions += 1
            for await _ in gate { break }
            return true
        }
        r.send(.start)
        let start = Task { await r.link.processInbox() }
        #expect(await eventually { admissions == 1 })
        r.send(.start, id: "second")
        let duplicate = Task { await r.link.processInbox() }
        #expect(await eventually { r.ack?.id == "second" })
        #expect(admissions == 1)
        #expect(r.ack == KeyboardAck(id: "second", result: .accepted))
        release.yield(()); release.finish()
        await start.value; await duplicate.value
    }

    @Test func aStopRacingTheFirstStartNoteIsSafeWhileTheMicrophoneLeaseIsHeld() async {
        let r = Rig()
        r.link.leaseChanged(until: t0.addingTimeInterval(30))
        r.send(.stop)
        await r.link.processInbox()
        #expect(r.ack == KeyboardAck(id: "req-1", result: .accepted))
        #expect(r.received.requests.map(\.command) == [.stop])
    }

    @Test func aRemoteStartWithALeaseIsActedOnAndAccepted() async {
        let r = Rig()
        r.link.leaseChanged(until: t0.addingTimeInterval(30))
        r.send(.start)
        await r.link.processInbox()
        #expect(r.received.requests.map(\.command) == [.start])
        #expect(r.ack == KeyboardAck(id: "req-1", result: .accepted))
        #expect(r.env.count(LinkChannel.Note.ack) == 1)
    }

    @Test func theAckIsWrittenBeforeTheActionRunsSoTheKeyboardIsNotKeptWaiting() async {
        // Starting a dictation takes longer than the keyboard's ack timeout; it must not wait for it.
        let r = Rig()
        r.link.leaseChanged(until: t0.addingTimeInterval(30))
        var ackWhenActing: KeyboardAck?
        r.link.onRequest = { _ in ackWhenActing = r.ack; return true }
        r.send(.start)
        await r.link.processInbox()
        #expect(ackWhenActing == KeyboardAck(id: "req-1", result: .accepted))
    }

    @Test func aRemoteStartWithoutALeaseAsksTheKeyboardToHopAndIsStillAdmittableByURL() async {
        let r = Rig()
        r.send(.start)
        await r.link.processInbox()
        #expect(r.received.requests.isEmpty)
        #expect(r.ack == KeyboardAck(id: "req-1", result: .hop))
        #expect(r.link.admitURL(requestID: "req-1", command: .start) == .act) // the URL that opens the app still goes through
    }

    @Test func theSameRequestTwiceIsActedOnOnceAndAckedBothTimes() async {
        let r = Rig()
        r.link.leaseChanged(until: t0.addingTimeInterval(30))
        r.send(.start)
        await r.link.processInbox()
        await r.link.processInbox()
        #expect(r.received.requests.count == 1)
        #expect(r.ack == KeyboardAck(id: "req-1", result: .accepted))
    }

    @Test func aURLThatWasHandledBlocksTheMatchingInboxRequest() async {
        let r = Rig()
        r.send(.start) // the keyboard wrote its request, then the Link opened the app
        #expect(r.link.admitURL(requestID: "req-1", command: .start) == .act)
        #expect(r.link.admitURL(requestID: "req-1", command: .start) == .alreadyHandled)
        await r.link.processInbox()
        #expect(r.received.requests.isEmpty) // the URL path acts; the inbox must not start a second run
        #expect(r.ack == KeyboardAck(id: "req-1", result: .accepted))
    }

    @Test func aURLForARequestTheInboxAlreadyHandledDoesNotActAgain() async {
        let r = Rig()
        r.link.leaseChanged(until: t0.addingTimeInterval(30))
        r.send(.start)
        await r.link.processInbox()
        #expect(r.received.requests.count == 1)
        #expect(r.link.admitURL(requestID: "req-1", command: .start) == .alreadyHandled)
    }

    // MARK: URL start needs the keyboard's own request

    @Test func aURLStartWithoutAnyRequestFromTheKeyboardIsRejected() {
        // Anything can open `legato://keyboard?cmd=start&req=x` (a web page, another app): without a request
        // that our keyboard wrote, the app may open but must not start the microphone.
        let r = Rig()
        #expect(r.link.admitURL(requestID: "forged", command: .start) == .rejected)
        // A rejected URL leaves no trace: the same id is still rejected, and a real request later still works.
        #expect(r.link.admitURL(requestID: "forged", command: .start) == .rejected)
    }

    @Test func aURLWhoseIdDiffersFromTheKeyboardsRequestIsRejected() {
        let r = Rig()
        r.send(.start, id: "real")
        #expect(r.link.admitURL(requestID: "forged", command: .start) == .rejected)
        #expect(r.link.admitURL(requestID: "real", command: .start) == .act)
    }

    @Test func aURLWithAStaleRequestIsRejected() {
        let r = Rig()
        r.send(.start, age: LinkChannel.requestMaxAge + 1)
        #expect(r.link.admitURL(requestID: "req-1", command: .start) == .rejected)
    }

    @Test func aURLWhoseCommandDiffersFromTheRequestIsRejected() {
        let r = Rig()
        r.send(.stop)
        #expect(r.link.admitURL(requestID: "req-1", command: .start) == .rejected)
    }

    @Test func aRejectedURLDoesNotBlockTheRealRequest() async {
        let r = Rig()
        r.link.leaseChanged(until: t0.addingTimeInterval(30))
        #expect(r.link.admitURL(requestID: "req-1", command: .start) == .rejected)
        r.send(.start)
        await r.link.processInbox()
        #expect(r.received.requests.map(\.id) == ["req-1"])
    }

    @Test func aStaleRequestIsIgnoredWithoutAnAck() async {
        let r = Rig()
        r.link.leaseChanged(until: t0.addingTimeInterval(30))
        r.send(.start, age: LinkChannel.requestMaxAge + 1)
        await r.link.processInbox()
        #expect(r.received.requests.isEmpty && r.ack == nil)
    }

    @Test func aRemoteStartThatFailsIsAckedHopAfterTheAcceptance() async {
        // The ack goes out first (the keyboard waits 0.6 s); when the start then fails, the keyboard must
        // still learn that the app has to be opened.
        let r = Rig()
        r.link.leaseChanged(until: t0.addingTimeInterval(30))
        var ackWhenActing: KeyboardAck?
        r.link.onRequest = { _ in ackWhenActing = r.ack; return false }
        r.send(.start)
        await r.link.processInbox()
        #expect(ackWhenActing == KeyboardAck(id: "req-1", result: .accepted))
        #expect(r.ack == KeyboardAck(id: "req-1", result: .hop))
        #expect(r.env.count(LinkChannel.Note.ack) == 2)
    }

    @Test func aRemoteStartThatSucceedsStaysAccepted() async {
        let r = Rig()
        r.link.leaseChanged(until: t0.addingTimeInterval(30))
        r.send(.start)
        await r.link.processInbox()
        #expect(r.ack == KeyboardAck(id: "req-1", result: .accepted))
        #expect(r.env.count(LinkChannel.Note.ack) == 1)
    }

    @Test func aRemoteStopThatFailsIsNotAckedHop() async {
        // A stop that did nothing leaves the user where they are; there is nothing to open the app for.
        let r = Rig()
        r.link.listeningChanged(true)
        r.link.onRequest = { _ in false }
        r.send(.stop)
        await r.link.processInbox()
        #expect(r.ack == KeyboardAck(id: "req-1", result: .accepted))
    }

    @Test func aRemoteStopIsAcceptedOnlyWhileARunIsInProgress() async {
        let r = Rig()
        r.send(.stop, id: "a")
        await r.link.processInbox()
        #expect(r.ack == KeyboardAck(id: "a", result: .hop) && r.received.requests.isEmpty)
        r.link.listeningChanged(true)
        r.send(.stop, id: "b")
        await r.link.processInbox()
        #expect(r.ack == KeyboardAck(id: "b", result: .accepted))
        #expect(r.received.requests.map(\.command) == [.stop])
    }

    @Test func endKeepAliveIsAcceptedOnlyWithALease() async {
        let r = Rig()
        r.send(.endKeepAlive, id: "a")
        await r.link.processInbox()
        #expect(r.ack == KeyboardAck(id: "a", result: .hop) && r.received.requests.isEmpty)
        r.link.leaseChanged(until: t0.addingTimeInterval(30))
        r.send(.endKeepAlive, id: "b")
        await r.link.processInbox()
        #expect(r.ack == KeyboardAck(id: "b", result: .accepted))
        #expect(r.received.requests.map(\.command) == [.endKeepAlive])
    }

    @Test func aStartWhileARunIsInProgressIsAcceptedWithoutActing() async {
        let r = Rig()
        r.link.listeningChanged(true)
        r.send(.start)
        await r.link.processInbox()
        #expect(r.ack == KeyboardAck(id: "req-1", result: .accepted))
        #expect(r.received.requests.isEmpty)
    }

    // MARK: arming (the hop)

    @Test func anArmRequestOverTheLinkIsAlwaysAnsweredHopBecauseArmingNeedsTheAppInFront() async {
        let r = Rig()
        r.send(.arm, id: "a")
        await r.link.processInbox()
        #expect(r.ack == KeyboardAck(id: "a", result: .hop) && r.received.requests.isEmpty)
        // Even with a lease held (a remote start failed and the mic may be dead): arm from the front.
        r.link.leaseChanged(until: t0.addingTimeInterval(30))
        r.send(.arm, id: "b")
        await r.link.processInbox()
        #expect(r.ack == KeyboardAck(id: "b", result: .hop) && r.received.requests.isEmpty)
    }

    @Test func theURLThatOpensTheAppAdmitsTheArmOnceAndTheLedgerBlocksTheCopy() async {
        let r = Rig()
        r.send(.arm)
        #expect(r.link.admitURL(requestID: "req-1", command: .arm) == .act)
        #expect(r.link.admitURL(requestID: "req-1", command: .arm) == .alreadyHandled)
        await r.link.processInbox()
        #expect(r.received.requests.isEmpty) // the URL path acts; the inbox must not arm a second time
    }

    @Test func anArmURLWithoutTheKeyboardsOwnRequestIsRejected() {
        let r = Rig()
        #expect(r.link.admitURL(requestID: "forged", command: .arm) == .rejected)
    }

    @Test func anArmURLDoesNotMatchAStartRequest() {
        let r = Rig()
        r.send(.start)
        #expect(r.link.admitURL(requestID: "req-1", command: .arm) == .rejected)
    }

    // MARK: keyboard presence

    @Test func theKeyboardIsVisibleOnlyWhilePresenceIsFresh() {
        let r = Rig()
        #expect(!r.link.keyboardIsVisible())
        r.store.write(KeyboardPresence(visible: true, at: t0), forKey: LinkChannel.Key.presence)
        #expect(r.link.keyboardIsVisible())
        r.env.advance(LinkChannel.presenceFreshness + 0.1)
        #expect(!r.link.keyboardIsVisible())
    }

}
