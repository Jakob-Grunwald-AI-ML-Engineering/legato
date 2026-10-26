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
                else if duration == .seconds(LinkChannel.finalTextRetention) { try await env.retention.sleep(duration) }
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
    func report(_ cursor: AppliedCursor) { store.write(cursor, forKey: LinkChannel.Key.applied) }
    var applied: AppliedCursor? { store.read(AppliedCursor.self, forKey: LinkChannel.Key.applied) }
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
    // MARK: a fresh link

    @Test func startingTheLinkOverwritesAStateThatAnEarlierProcessLeftBehind() {
        // The app died mid-run: `link.host` still says "listening" with the run's text. A new process must
        // not leave that for a keyboard to type into some later field.
        let backing = MemoryLinkStore()
        let old = Rig(backing: backing)
        old.link.runStarted(id: "dead-run", target: .keyboard)
        old.link.update(committed: "private words ", volatile: "more")
        #expect(old.host?.phase == .listening)

        let fresh = Rig(backing: backing)
        let host = fresh.host
        #expect(host?.phase == .idle && host?.runID == nil)
        #expect(host?.committed == "" && host?.volatile == "")
        #expect(host?.leaseUntil == nil && host?.acceptsRemoteStart == false)
        #expect(fresh.initialPosts == [LinkChannel.Note.host]) // keyboards are told
    }

    @Test func startingTheLinkRemovesTheDeadRunsAppliedCursor() {
        let backing = MemoryLinkStore()
        let old = Rig(backing: backing)
        old.report(cursor(runID: "dead-run", committedCount: 5, volatile: "private"))
        let fresh = Rig(backing: backing)
        #expect(fresh.applied == nil)
    }

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

    // MARK: text does not outlive the run

    private func finishedRun(_ r: Rig) {
        r.link.runStarted(id: "run-1", target: .keyboard)
        r.link.update(committed: "secret words ", volatile: "")
        r.link.runEnded(committed: "secret words ")
        r.report(cursor(runID: "run-1", committedCount: 13, volatile: "", finalApplied: true))
    }

    @Test func theFinalTextIsKeptForTheKeyboardThenScrubbedFromHostAndApplied() async {
        let r = Rig()
        finishedRun(r)
        #expect(r.host?.committed == "secret words " && r.host?.isFinal == true) // the keyboard may still read it
        #expect(r.applied != nil)
        let posts = r.env.count(LinkChannel.Note.host)
        r.env.retention.tick() // the retention window ends
        #expect(await eventually { r.host?.committed == "" })
        #expect(r.host?.volatile == "" && r.host?.runID == nil && r.host?.phase == .idle)
        #expect(r.applied == nil)
        #expect(r.env.count(LinkChannel.Note.host) == posts + 1) // and the keyboard is told
    }

    @Test func aLeaseSurvivesTheScrub() async {
        let r = Rig()
        let until = t0.addingTimeInterval(30)
        finishedRun(r)
        r.link.leaseChanged(until: until)
        r.env.retention.tick()
        #expect(await eventually { r.host?.committed == "" })
        #expect(r.host?.leaseUntil == until && r.host?.acceptsRemoteStart == true)
    }

    @Test func aNewRunCancelsThePendingScrub() async throws {
        let r = Rig()
        finishedRun(r)
        r.link.runStarted(id: "run-2", target: .keyboard)
        r.link.update(committed: "second ", volatile: "")
        r.report(cursor(runID: "run-2", committedCount: 7))
        r.env.retention.tick() // the old window ends: it must not wipe the new run
        try await Task.sleep(for: .milliseconds(50))
        #expect(r.host?.runID == "run-2" && r.host?.committed == "second ")
        #expect(r.applied?.runID == "run-2")
    }

    @Test func deletingHistoryScrubsAnIdleLinkAtOnce() {
        let r = Rig()
        finishedRun(r)
        r.link.scrubText()
        #expect(r.host?.committed == "" && r.host?.runID == nil)
        #expect(r.applied == nil)
    }

    @Test func deletingHistoryDuringARunLeavesTheRunAlone() {
        let r = Rig()
        r.link.runStarted(id: "run-1", target: .keyboard)
        r.link.update(committed: "live ", volatile: "words")
        r.link.scrubText()
        #expect(r.host?.runID == "run-1" && r.host?.committed == "live " && r.host?.volatile == "words")
    }

    // MARK: insert (the Live Activity's Insert button)

    @Test func anInsertPublishesTheTextAsAFinalKeyboardStateFlaggedAsRequested() {
        let r = Rig()
        #expect(r.link.publishInsert(runID: "ins-1", text: "hello world"))
        #expect(r.host?.runID == "ins-1" && r.host?.committed == "hello world" && r.host?.volatile == "")
        #expect(r.host?.target == .keyboard && r.host?.isFinal == true)
        #expect(r.host?.insertAt == r.env.now)
        #expect(r.env.count(LinkChannel.Note.host) == 1) // the keyboard is woken once
    }

    @Test func anInsertDuringARunIsRefusedAndLeavesTheRunAlone() {
        let r = Rig()
        r.link.runStarted(id: "run-1", target: .keyboard)
        r.link.update(committed: "live ", volatile: "words")
        #expect(!r.link.publishInsert(runID: "ins-1", text: "other"))
        #expect(r.host?.runID == "run-1" && r.host?.committed == "live " && r.host?.insertAt == nil)
    }

    @Test func theInsertedTextIsScrubbedWithItsFlagAfterTheRetentionWindow() async {
        let r = Rig()
        _ = r.link.publishInsert(runID: "ins-1", text: "hello world")
        r.env.retention.tick()
        #expect(await eventually { r.host?.committed == "" })
        #expect(r.host?.insertAt == nil && r.host?.runID == nil)
    }

    @Test func aNewRunClearsTheInsertFlag() {
        let r = Rig()
        _ = r.link.publishInsert(runID: "ins-1", text: "hello world")
        r.link.runStarted(id: "run-2", target: .keyboard)
        #expect(r.host?.insertAt == nil)
    }

    @Test func theKeyboardsConfirmationOfAnInsertIsAwaitedLikeAnyFinalText() async {
        let r = Rig()
        _ = r.link.publishInsert(runID: "ins-1", text: "hello world")
        r.report(cursor(runID: "ins-1", committedCount: 11, finalApplied: true))
        #expect(await r.link.awaitFinalApplied(runID: "ins-1", timeout: 1))
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
        r.link.runStarted(id: "run-1", target: .keyboard)
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
