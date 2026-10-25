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

    var now: Date { clock.withLock { $0 } }
    func advance(_ seconds: TimeInterval) { clock.withLock { $0 = $0.addingTimeInterval(seconds) } }
    func post(_ name: String) { notes.withLock { $0.append(name) } }
    var posts: [String] { notes.withLock { $0 } }
    func count(_ name: String) -> Int { posts.filter { $0 == name }.count }
}

/// Manually driven sleep: each sleep waits for one `tick()`; a cancelled sleeper throws and the clock lives on.
private struct TickClock: Sendable {
    private final class Source: Sendable {
        private struct State {
            var pending = 0
            var nextID = 0
            var waiters: [Int: CheckedContinuation<Void, any Error>] = [:]
        }
        private let state = Mutex(State())

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
                let waiter = state.withLock { $0.waiters.removeValue(forKey: id) }
                waiter?.resume(throwing: CancellationError())
            }
        }
    }

    private let source = Source()
    func tick() { source.tick() }
    var sleep: @Sendable (Duration) async throws -> Void {
        let source = self.source
        return { _ in try await source.wait() }
    }
}

@MainActor
private struct Rig {
    let env = Env()
    let backing = MemoryLinkStore()
    let store: LinkStore
    let link: HostLink
    let received = Received()

    init() {
        store = LinkStore(backing)
        let env = self.env
        link = HostLink(
            store: store, post: { env.post($0) }, now: { env.now },
            sleep: { duration in
                if duration == .seconds(LinkChannel.beatInterval) { try await env.beat.sleep(duration) }
                else { try await env.other.sleep(duration) }
            })
        let received = self.received
        link.onRequest = { received.requests.append($0) }
    }

    var host: HostState? { store.read(HostState.self, forKey: LinkChannel.Key.host) }
    var ack: KeyboardAck? { store.read(KeyboardAck.self, forKey: LinkChannel.Key.ack) }

    func send(_ command: RequestCommand, id: String = "req-1", age: TimeInterval = 0) {
        store.write(KeyboardRequest(id: id, command: command, at: env.now.addingTimeInterval(-age)), forKey: LinkChannel.Key.request)
    }
    func report(_ cursor: AppliedCursor) { store.write(cursor, forKey: LinkChannel.Key.applied) }
}

@MainActor
private final class Received {
    var requests: [KeyboardRequest] = []
}

@MainActor
private func eventually(_ condition: @MainActor () -> Bool) async -> Bool {
    for _ in 0..<400 {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return condition()
}

@MainActor
@Suite struct HostLinkTests {
    // MARK: publishing

    @Test func aRunStartIsPublishedAtOnce() {
        let r = Rig()
        r.link.runStarted(id: "run-1", target: .keyboard)
        let host = r.host
        #expect(host?.runID == "run-1" && host?.phase == .starting && host?.target == .keyboard)
        #expect(host?.committed == "" && host?.volatile == "" && host?.seq == 1)
        #expect(host?.beatAt == t0 && host?.v == 1)
        #expect(host?.acceptsRemoteStart == false && host?.leaseUntil == nil)
        #expect(r.env.posts == [LinkChannel.Note.host])
    }

    @Test func theFirstUpdateMovesToListeningAtOnce() {
        let r = Rig()
        r.link.runStarted(id: "run-1", target: .keyboard)
        r.link.update(committed: "hello ", volatile: "wor")
        #expect(r.host?.phase == .listening)
        #expect(r.host?.committed == "hello " && r.host?.volatile == "wor")
        #expect(r.host?.seq == 2)
    }

    @Test func updatesInsideTheWindowAreCoalescedIntoOneTrailingPublish() async {
        let r = Rig()
        r.link.runStarted(id: "run-1", target: .keyboard)
        r.link.update(committed: "", volatile: "a") // phase change: at once
        r.env.advance(0.01)
        r.link.update(committed: "", volatile: "ab")
        r.env.advance(0.01)
        r.link.update(committed: "", volatile: "abc")
        #expect(r.host?.volatile == "a") // held back
        #expect(r.env.count(LinkChannel.Note.host) == 2)
        r.env.advance(0.08)
        r.env.other.tick() // the window ends
        #expect(await eventually { r.host?.volatile == "abc" })
        #expect(r.host?.seq == 3) // one publish for both held updates
        #expect(r.env.count(LinkChannel.Note.host) == 3)
    }

    @Test func anUpdateAfterTheWindowIsPublishedAtOnce() {
        let r = Rig()
        r.link.runStarted(id: "run-1", target: .keyboard)
        r.link.update(committed: "", volatile: "a")
        r.env.advance(LinkChannel.minPublishInterval + 0.01)
        r.link.update(committed: "", volatile: "ab")
        #expect(r.host?.volatile == "ab")
    }

    @Test func theFinalStateIsPublishedAtOnceAndDropsThePendingUpdate() async throws {
        let r = Rig()
        r.link.runStarted(id: "run-1", target: .keyboard)
        r.link.update(committed: "", volatile: "a")
        r.env.advance(0.01)
        r.link.update(committed: "hello ", volatile: "wor") // held
        r.link.runEnded(committed: "hello world ")
        let host = try #require(r.host)
        #expect(host.phase == .idle && host.runID == "run-1" && host.isFinal)
        #expect(host.committed == "hello world " && host.volatile == "")
        let seq = host.seq
        r.env.advance(0.2)
        r.env.other.tick()
        try await Task.sleep(for: .milliseconds(50))
        #expect(r.host?.seq == seq) // the held update never lands after the end
    }

    @Test func everyPublishIsReportedToTheObserverWithTheWrittenState() {
        let r = Rig()
        var seen: [HostState] = []
        r.link.onPublish = { seen.append($0) }
        r.link.runStarted(id: "run-1", target: .keyboard)
        r.link.update(committed: "hi ", volatile: "")
        #expect(seen.map(\.seq) == [1, 2])
        #expect(seen.last == r.host)
    }

    // MARK: beat

    @Test func theBeatIsRefreshedWhileARunIsActive() async {
        let r = Rig()
        r.link.runStarted(id: "run-1", target: .keyboard)
        r.link.update(committed: "hi ", volatile: "")
        r.env.advance(1)
        r.env.beat.tick()
        #expect(await eventually { r.host?.beatAt == t0.addingTimeInterval(1) })
        #expect(r.host?.committed == "hi " && r.host?.phase == .listening)
        let seq = r.host?.seq ?? 0
        r.env.advance(1)
        r.env.beat.tick()
        #expect(await eventually { r.host?.beatAt == t0.addingTimeInterval(2) })
        #expect(r.host?.seq == seq + 1)
    }

    @Test func theBeatStopsWhenNothingIsRunningAndNoLeaseIsHeld() async throws {
        let r = Rig()
        r.link.runStarted(id: "run-1", target: .keyboard)
        r.link.runEnded(committed: "hi ")
        let seq = r.host?.seq
        r.env.advance(1)
        r.env.beat.tick()
        try await Task.sleep(for: .milliseconds(50))
        #expect(r.host?.seq == seq && r.host?.beatAt == t0)
    }

    @Test func aLeaseKeepsTheBeatGoingAndAllowsRemoteStart() async {
        let r = Rig()
        r.link.runStarted(id: "run-1", target: .keyboard)
        r.link.runEnded(committed: "hi ")
        let until = t0.addingTimeInterval(30)
        r.link.leaseChanged(until: until)
        #expect(r.host?.leaseUntil == until && r.host?.acceptsRemoteStart == true)
        #expect(r.host?.phase == .idle && r.host?.committed == "hi ")
        r.env.advance(1)
        r.env.beat.tick()
        #expect(await eventually { r.host?.beatAt == t0.addingTimeInterval(1) })
    }

    @Test func endingTheLeaseStopsRemoteStartAndTheBeat() async throws {
        let r = Rig()
        r.link.leaseChanged(until: t0.addingTimeInterval(30))
        #expect(r.host?.acceptsRemoteStart == true && r.host?.runID == nil)
        r.link.leaseChanged(until: nil)
        #expect(r.host?.acceptsRemoteStart == false && r.host?.leaseUntil == nil)
        let seq = r.host?.seq
        r.env.advance(1)
        r.env.beat.tick()
        try await Task.sleep(for: .milliseconds(50))
        #expect(r.host?.seq == seq)
    }

    @Test func aNewRunKeepsTheLeaseInTheState() {
        let r = Rig()
        r.link.leaseChanged(until: t0.addingTimeInterval(30))
        r.link.runStarted(id: "run-2", target: .keyboard)
        #expect(r.host?.leaseUntil == t0.addingTimeInterval(30) && r.host?.runID == "run-2")
    }

    // MARK: requests

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
        r.link.onRequest = { _ in ackWhenActing = r.ack }
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
        #expect(r.link.admitURL(requestID: "req-1")) // the URL that opens the app still goes through
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
        #expect(r.link.admitURL(requestID: "req-1"))
        #expect(!r.link.admitURL(requestID: "req-1"))
        r.send(.start)
        await r.link.processInbox()
        #expect(r.received.requests.isEmpty) // the URL path acts; the inbox must not start a second run
        #expect(r.ack == KeyboardAck(id: "req-1", result: .accepted))
    }

    @Test func aStaleRequestIsIgnoredWithoutAnAck() async {
        let r = Rig()
        r.link.leaseChanged(until: t0.addingTimeInterval(30))
        r.send(.start, age: LinkChannel.requestMaxAge + 1)
        await r.link.processInbox()
        #expect(r.received.requests.isEmpty && r.ack == nil)
    }

    @Test func aRemoteStopIsAcceptedOnlyWhileARunIsInProgress() async {
        let r = Rig()
        r.send(.stop, id: "a")
        await r.link.processInbox()
        #expect(r.ack == KeyboardAck(id: "a", result: .hop) && r.received.requests.isEmpty)
        r.link.runStarted(id: "run-1", target: .keyboard)
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
        r.link.runStarted(id: "run-1", target: .keyboard)
        r.send(.start)
        await r.link.processInbox()
        #expect(r.ack == KeyboardAck(id: "req-1", result: .accepted))
        #expect(r.received.requests.isEmpty)
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

    // MARK: applied

    @Test func theFinalConfirmationIsImmediateWhenTheKeyboardAlreadyReportedIt() async {
        let r = Rig()
        r.report(cursor(runID: "run-1", committedCount: 3, finalApplied: true))
        #expect(await r.link.awaitFinalApplied(runID: "run-1", timeout: 0.5))
    }

    @Test func theFinalConfirmationArrivesWithTheKeyboardsReport() async {
        let r = Rig()
        r.report(cursor(runID: "run-1", committedCount: 1, finalApplied: false))
        let waiting = Task { await r.link.awaitFinalApplied(runID: "run-1", timeout: 0.5) }
        try? await Task.sleep(for: .milliseconds(20))
        r.report(cursor(runID: "run-1", committedCount: 3, finalApplied: true))
        r.link.appliedDidChange()
        #expect(await waiting.value)
    }

    @Test func aReportForAnotherRunOrWithoutTheFinalFlagDoesNotConfirm() async {
        let r = Rig()
        let waiting = Task { await r.link.awaitFinalApplied(runID: "run-2", timeout: 0.5) }
        try? await Task.sleep(for: .milliseconds(20))
        r.report(cursor(runID: "run-1", finalApplied: true))
        r.link.appliedDidChange()
        r.report(cursor(runID: "run-2", finalApplied: false))
        r.link.appliedDidChange()
        try? await Task.sleep(for: .milliseconds(20))
        r.env.other.tick() // the timeout
        #expect(await waiting.value == false)
    }

    @Test func noReportWithinTheTimeoutMeansNotApplied() async {
        let r = Rig()
        let waiting = Task { await r.link.awaitFinalApplied(runID: "run-1", timeout: 0.5) }
        try? await Task.sleep(for: .milliseconds(20))
        r.env.other.tick()
        #expect(await waiting.value == false)
    }

    @Test func aStaleConfirmationFromAnEarlierRunIsNotMistakenForThisOne() async {
        let r = Rig()
        r.report(cursor(runID: "run-1", finalApplied: true))
        let waiting = Task { await r.link.awaitFinalApplied(runID: "run-2", timeout: 0.5) }
        try? await Task.sleep(for: .milliseconds(20))
        r.env.other.tick()
        #expect(await waiting.value == false)
    }
}
