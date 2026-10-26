import Foundation

/// The decision logic behind one "dictate" button (Action Button, control, Live Activity stop, the
/// keyboard's mic key): each `toggle()` starts a dictation or stops the running one, and keeps the
/// Live Activity, the transcript sink and the clipboard in step. Pure policy: ActivityKit, the
/// pasteboard and the system checks are ports.
///
/// Order matters. With `.required` the activity is requested *before* the session starts, because iOS
/// stops a recording intent that has no Live Activity. By default every start builds a fresh
/// `DictationSession` (and so a fresh mic) and nothing stays armed afterwards. With a keep-alive the
/// session's mic lease outlives the run: the next start inside the window reuses that session, and the
/// consumer of its edits keeps running between the runs.
///
/// A start is always attempted where the press arrived, also in the background next to other audio.
/// A background start the system refuses under a non-default audio policy is retried once under the
/// default (same activity). A foreground start whose mic reports no input yet (`isInputNotReady`) is
/// retried with a fresh session after a short settle wait. Only a start still refused ends in
/// `.needsForeground` with nothing left behind; the app brings itself to the foreground and toggles again.
/// A press that lands while a start is wrapping up (a retry's teardown, the release of an old lease)
/// cancels it: such a start ends `.stopped(nil)`, never hops, and never activates audio.
///
/// Nothing starts over a teardown still in flight: a start waits for the release of a lease
/// (`endKeepAlive`) and for the session's own abort teardown, because the old teardown's deactivation
/// would otherwise land on the new session's audio session.
@MainActor
public final class DictationCoordinator {
    public enum Outcome: Sendable, Equatable {
        /// Listening; the next toggle stops.
        case started
        /// Finished and idle again. The run's text (on the clipboard unless the sink says it landed in
        /// the target field), or nil when nothing was recognized (or the start was cancelled).
        case stopped(String?)
        /// Not started: resolve `ReadinessIssue` in the foreground first.
        case needsOnboarding(ReadinessIssue)
        /// Not started, and nothing is left behind (no activity, no audio): the app must come to the
        /// foreground and press again. The press in the foreground starts normally.
        case needsForeground(ForegroundReason)
        /// The start failed (description of the error); the activity ended `failed`.
        case failed(String)
        /// A stop or abort is already being wrapped up; the press did nothing.
        case busy
    }

    /// While listening, the activity is refreshed this often so a pause in speech never looks stale.
    public static let heartbeatInterval: Duration = .seconds(10)
    /// How long a start waits before its retry after the mic reported no input (`isInputNotReady`).
    public nonisolated static let settleDelay: Duration = .milliseconds(300)
    /// How long after an update the system may treat the activity as stale.
    public static let staleAfter: TimeInterval = 30

    /// Fires after a run is over and its activity has ended (stopped, aborted or failed to start), with
    /// the coordinator idle again. The app decides what to do with the quiet moment (e.g. leave the
    /// background). Not fired when a press ends in `.needsOnboarding`: no run happened.
    public var onIdle: (@MainActor () -> Void)?

    /// Receives each run's text and the lease state; set once after `init`.
    public var sink: (any TranscriptSink)?

    /// No run is starting, listening or being wrapped up, and no lease is being released (a held lease
    /// doesn't count).
    public var isIdle: Bool { phase == .idle && pendingRelease == nil }
    /// A mic lease is held between runs (keep-alive), ready for the next start.
    public var holdsLease: Bool { held != nil }

    /// Fires when a start is retried: a refused background start under the default audio policy, or a
    /// foreground start whose mic had no input yet (same policy first, then the default). Gives the
    /// policy that failed, the one tried next (equal for a same-policy retry) and the error. For diagnostics.
    public var onStartFallback: (@MainActor (_ from: AudioPolicy, _ to: AudioPolicy, _ error: any Error) -> Void)?

    private enum Phase { case idle, starting, listening, stopping, aborting }

    /// Follows one session's edits for its whole life, across runs.
    @MainActor
    private final class EditFeed {
        var task: Task<Void, Never>?
        var consumed = 0
        var finished = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func noteConsumed() {
            consumed += 1
            wake()
        }

        func finish() {
            finished = true
            wake()
        }

        /// Returns after the next edit was consumed, or when the feed ended.
        func waitForProgress() async {
            await withCheckedContinuation { waiters.append($0) }
        }

        private func wake() {
            let pending = waiters
            waiters = []
            for waiter in pending { waiter.resume() }
        }
    }

    /// A session whose mic lease is kept between runs.
    private struct HeldLease {
        let session: DictationSession
        let feed: EditFeed
        let linger: Duration
    }

    private let activity: any ActivityClient
    private let clipboard: any Clipboard
    private let readiness: any Readiness
    private let startEnvironment: any StartEnvironment
    private let history: any HistoryStore
    private let makeSession: DictationSessionFactory
    private let sleep: @Sendable (Duration) async throws -> Void
    private let now: @Sendable () -> Date

    private var phase = Phase.idle
    private var session: DictationSession?
    private var feed: EditFeed?
    private var held: HeldLease?
    private var run: DictationRun?
    /// A held lease being released right now (`endKeepAlive`); a start waits for it.
    private var pendingRelease: Task<Void, Never>?
    /// The abort the session's `onRunAborted` set going, so a start that finds its run already dead can
    /// report the abort's outcome.
    private var abortTask: (session: DictationSession, task: Task<Outcome, Never>)?
    private var options = StartOptions()
    /// The current run has a Live Activity (always with `.required`, maybe not with `.bestEffort`).
    private var activityLive = false
    /// The lease end last reported to the sink, so it hears only changes.
    private var reportedLease: Date?
    private var live = LiveTranscript()
    private var startedAt = Date()
    /// A press arrived while starting; the start flow ends the run as soon as it can.
    private var cancelRequested = false
    private var heartbeat: Task<Void, Never>?
    /// Publishes an edit the throttle held back once its window ends, so the last words of a phrase
    /// followed by silence don't wait for the next heartbeat. At most one is pending.
    private var trailing: Task<Void, Never>?
    private var lastPublishAt: Date?
    /// Activity updates in flight, so a stop can wait them out before it moves the activity on.
    private var publishing = 0
    private var quiesceWaiters: [CheckedContinuation<Void, Never>] = []

    public init(
        activity: any ActivityClient,
        clipboard: any Clipboard,
        readiness: any Readiness,
        startEnvironment: any StartEnvironment = UnrestrictedStartEnvironment(),
        history: any HistoryStore,
        makeSession: @escaping DictationSessionFactory,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.activity = activity
        self.clipboard = clipboard
        self.readiness = readiness
        self.startEnvironment = startEnvironment
        self.history = history
        self.makeSession = makeSession
        self.sleep = sleep
        self.now = now
    }

    /// Idle: starts a run with `options`. Starting: cancels the start. Listening: stops the run (the
    /// options are ignored).
    public func toggle(_ options: StartOptions = StartOptions()) async -> Outcome {
        switch phase {
        case .idle: return await start(options)
        case .starting: return await cancelStart()
        case .listening: return await stop()
        case .stopping, .aborting: return .busy
        }
    }

    /// Never begins a run, only ends one: for system events (interruption, lost input, engine change,
    /// media reset) and for a stop command, so a late or duplicate event (e.g. the route change our own
    /// session deactivation raises) cannot start a dictation. Listening: stops like `toggle()`.
    /// Starting: cancels the start. Returns nil when there was nothing to stop (idle, or a stop or abort
    /// is already wrapping up).
    ///
    /// `releasingLease`: do not keep the mic lease for the keep-alive window, release it now. A system
    /// event means the system took the mic or the route away, so the lease the run would have kept is
    /// dead; holding it would only fail the next start.
    @discardableResult
    public func stopIfRunning(releasingLease: Bool = false) async -> Outcome? {
        switch phase {
        case .starting: return await cancelStart()
        case .listening: return await stop(releasingLease: releasingLease)
        case .idle, .stopping, .aborting: return nil
        }
    }

    /// Starts a run with `options` only when nothing is in progress; never stops one (a second start
    /// while running must not toggle it off). Waits for a lease release in flight first. Nil when a run
    /// was starting, listening or wrapping up and so nothing started.
    public func startIfIdle(_ options: StartOptions = StartOptions()) async -> Outcome? {
        if phase == .idle, let release = pendingRelease { await release.value }
        guard phase == .idle else { return nil }
        return await start(options)
    }

    /// Releases the mic lease kept between runs, now. Does nothing during a run or without a lease; a
    /// call that finds a release already in flight returns when that one is done.
    public func endKeepAlive() async {
        guard phase == .idle else { return }
        guard let lease = held else {
            await pendingRelease?.value
            return
        }
        held = nil
        let release = Task {
            await self.release(lease)
            self.pendingRelease = nil
        }
        pendingRelease = release
        await release.value
    }

    // MARK: Start

    private func start(_ options: StartOptions) async -> Outcome {
        phase = .starting
        cancelRequested = false
        abortTask = nil
        self.options = options
        // Nothing starts over a release in flight: its deactivation would land on the new audio session.
        if let release = pendingRelease { await release.value }
        if cancelRequested { return finishRun(.stopped(nil), ended: false) }
        let issue = await readiness.check()
        if cancelRequested { return finishRun(.stopped(nil), ended: false) }
        // With a best-effort activity, "Live Activities are off" is not a reason to stay out of the run.
        if let issue, !(issue == .liveActivitiesDisabled && options.activity == .bestEffort) {
            return finishRun(.needsOnboarding(issue), ended: false)
        }
        // Always try the start where the press arrived, other audio or not; only a refusal hops.
        let context = startEnvironment.current()

        startedAt = now()
        live = LiveTranscript()
        lastPublishAt = nil
        activityLive = false
        do {
            try await activity.request(content(.starting))
            activityLive = true
        } catch {
            if options.activity == .required { return finishRun(.needsOnboarding(.liveActivitiesDisabled), ended: false) }
        }
        if cancelRequested {
            await endActivity(content(.failed))
            return finishRun(.stopped(nil))
        }

        let thisRun = DictationRun(target: options.target)
        run = thisRun
        sink?.runStarted(thisRun) // once per press: fallback and settle retries below stay within this run

        // A held lease is reused as is. The session re-arms itself under *its own* policy when its mic
        // died meanwhile, so a refusal of that re-arm is judged by the session's policy (`s.policy`),
        // not by the one selected for this press. Otherwise: the selected policy first. A refused
        // background start under a non-default policy gets one more try under the default (duck),
        // keeping the same activity and options; only then does it hop.
        var inputRetries = 0
        var s = await launch(context.audioPolicy, options)
        while true {
            // A press that landed while the session was acquired (e.g. an old lease was being released)
            // cancels the start before it touches the audio session.
            if cancelRequested { return await cancelBeforeStart(s, thisRun) }
            do {
                try await s.start()
                break
            } catch {
                await discard(s)
                let policy = s.policy
                if context.inBackground, startEnvironment.isBackgroundRefusal(error) {
                    if cancelRequested { return await finishCancelledRetry(thisRun) }
                    if policy != .default {
                        onStartFallback?(policy, .default, error)
                        s = await launch(.default, options)
                        continue
                    }
                    // The system refused a background start: tear down quietly and let the app retry in the
                    // foreground. No `failed` activity (it would linger), no idle hook (no run happened).
                    if activityLive {
                        activityLive = false
                        await activity.dismiss()
                    }
                    _ = await sink?.runEnded(thisRun, committed: "", text: nil) // a run that began always ends
                    // A press during that teardown cancelled the start: hopping now would begin the very
                    // dictation the user just cancelled.
                    if cancelRequested { return finishRun(.stopped(nil)) }
                    return finishRun(.needsForeground(.backgroundStartRefused), ended: false)
                }
                // The mic had no input yet (0 Hz after activation) in the foreground: nothing to hop to,
                // so retry with a fresh session after a short settle wait. Same policy first; a non-default
                // policy that fails again gets the default. Then it is a plain failure.
                if !context.inBackground, startEnvironment.isInputNotReady(error),
                   let next = nextPolicyAfterInputNotReady(current: policy, retries: inputRetries) {
                    if cancelRequested { return await finishCancelledRetry(thisRun) }
                    inputRetries += 1
                    onStartFallback?(policy, next, error)
                    try? await sleep(Self.settleDelay)
                    if cancelRequested { return await finishCancelledRetry(thisRun) }
                    s = await launch(next, options)
                    continue
                }
                await endActivity(content(.failed))
                _ = await sink?.runEnded(thisRun, committed: "", text: nil)
                switch error {
                case DictationError.cancelled: return finishRun(.stopped(nil))
                case DictationError.assetsNotInstalled: return finishRun(.needsOnboarding(.assetsMissing))
                default: return finishRun(.failed(String(describing: error)))
                }
            }
        }
        // The run may have died while the start was finishing (the engine stream failed at once). Its
        // abort is the real outcome, not `.started`.
        if let dead = await outcomeIfDead(s) { return dead }
        if cancelRequested { return await stop() } // pressed in the instant between listening and here

        phase = .listening
        startHeartbeat()
        sink?.update(committed: live.committed, volatile: live.volatile)
        await publishListening(force: true)
        // ... or while the first activity update was in flight.
        if let dead = await outcomeIfDead(s) { return dead }
        return .started
    }

    /// The outcome of `s`'s run when it is already over (aborted) although the start flow still holds it:
    /// waits for the abort to finish. Nil while the run is alive.
    private func outcomeIfDead(_ s: DictationSession) async -> Outcome? {
        guard session !== s || s.runState != .listening else { return nil }
        await s.settled()
        if let abort = abortTask, abort.session === s { return await abort.task.value }
        return session === s ? nil : .stopped(nil)
    }

    /// A cancel arrived before the session started: nothing was activated. Ends the activity `failed`
    /// like every cancel at the start, and drops a reused lease too (a cancelled run keeps none).
    private func cancelBeforeStart(_ s: DictationSession, _ thisRun: DictationRun) async -> Outcome {
        await s.endLease()
        await discard(s)
        await endActivity(content(.failed))
        _ = await sink?.runEnded(thisRun, committed: "", text: nil)
        return finishRun(.stopped(nil))
    }

    /// A cancel arrived while a failed attempt was being torn down for a retry or a hop: the retry never
    /// happens. The activity is dismissed (as for a hop), not ended `failed`.
    private func finishCancelledRetry(_ thisRun: DictationRun) async -> Outcome {
        if activityLive {
            activityLive = false
            await activity.dismiss()
        }
        _ = await sink?.runEnded(thisRun, committed: "", text: nil)
        return finishRun(.stopped(nil))
    }

    /// The held session when it fits `options` (same keep-alive), else a fresh one for `policy` with its
    /// own edit feed.
    private func acquireSession(_ options: StartOptions, policy: AudioPolicy) async -> (DictationSession, EditFeed) {
        if let lease = held {
            held = nil
            if options.keepAlive > .zero, lease.linger == options.keepAlive {
                lease.session.onLeaseExpired = nil
                return (lease.session, lease.feed)
            }
            await release(lease)
        }
        let s = makeSession(policy, options.keepAlive)
        return (s, startFeed(of: s))
    }

    /// The policy for the next foreground try after the mic had no input: the same one on the first
    /// retry, the default on the second (only if it differs), none after that.
    private func nextPolicyAfterInputNotReady(current: AudioPolicy, retries: Int) -> AudioPolicy? {
        switch retries {
        case 0: return current
        case 1 where current != .default: return .default
        default: return nil
        }
    }

    /// Acquires the session for `policy` (a held lease first, else a fresh one) and wires it to this run
    /// (abort hook, edits feed).
    private func launch(_ policy: AudioPolicy, _ options: StartOptions) async -> DictationSession {
        let (s, sessionFeed) = await acquireSession(options, policy: policy)
        session = s
        feed = sessionFeed
        s.onRunAborted = { [weak self, weak s] _ in
            guard let self, let s else { return }
            abortTask = (s, Task { await self.abort(s) })
        }
        return s
    }

    /// A press while starting: stops through the session (which cancels a preparing start, so no
    /// audio session is ever activated); the start flow then ends the activity.
    private func cancelStart() async -> Outcome {
        cancelRequested = true
        if let s = session, s.runState == .preparing { _ = try? await s.stop() }
        return .stopped(nil)
    }

    // MARK: Stop

    private func stop(releasingLease: Bool = false) async -> Outcome {
        guard let s = session, let thisRun = run else { return .busy }
        phase = .stopping
        await drainTimers()
        guard session === s else { return .busy }
        await quiesceActivity()
        guard session === s else { return .busy }
        await updateActivity(content(.finishing, tail: live.tail()), staleDate: nil)
        guard session === s else { return .busy }

        do {
            // The session saves the entry to history itself; it is not appended again here.
            let entry = try await s.stop()
            s.onRunAborted = nil
            guard let sessionFeed = feed else { return .busy }
            // The system ended this run: the lease it would keep is dead, so it ends with the run.
            if releasingLease { await s.endLease() }
            await flush(sessionFeed, of: s)
            let committed = live.committed

            let keep = !releasingLease && options.keepAlive > .zero && s.leaseState == .armed
            if keep {
                held = HeldLease(session: s, feed: sessionFeed, linger: options.keepAlive)
                s.onLeaseExpired = { [weak self, weak s] in
                    guard let self, let s else { return }
                    Task { await self.leaseExpired(s) }
                }
            }
            let landed = await sink?.runEnded(thisRun, committed: committed, text: entry?.text) ?? false
            if keep, held?.session === s { reportLease(now().addingTimeInterval(options.keepAlive.timeInterval)) }
            if !keep { await retire(sessionFeed) }

            guard let entry else {
                // Nothing final was recognized: nothing to copy, nothing to show but the failure.
                await endActivity(content(.failed))
                return finishRun(.stopped(nil))
            }
            await deliver(entry.text, landed: landed)
            return finishRun(.stopped(entry.text))
        } catch {
            return await abort(s)
        }
    }

    // MARK: Abort

    /// The run died under us (engine stream error, interruption, media reset) or `stop()` failed:
    /// salvage what was committed. Safe to call twice for one session; the second call is a no-op.
    private func abort(_ s: DictationSession) async -> Outcome {
        guard session === s else { return .busy }
        session = nil
        phase = .aborting
        // The session may still be tearing its own lease down (it aborted by itself and this call came
        // from a press or a start that found it dead): nothing may start over that.
        await s.settled()
        await drainTimers()
        if let dying = feed {
            await flush(dying, of: s)
            await retire(dying)
        }
        feed = nil
        await quiesceActivity()
        s.onRunAborted = nil
        reportLease(nil) // a dead session keeps no lease

        // The session's own text: the feed may have been cut short by the failure itself.
        let entry = s.partialEntry()
        var landed = false
        if let thisRun = run { landed = await sink?.runEnded(thisRun, committed: live.committed, text: entry?.text) ?? false }
        guard let entry else {
            await endActivity(content(.failed))
            return finishRun(.stopped(nil))
        }
        try? await history.append(entry) // the session never saved this run; losing the copy is worse
        await deliver(entry.text, landed: landed)
        return finishRun(.stopped(entry.text))
    }

    // MARK: Pieces

    /// `landed`: the sink confirmed the final text is in the target field, so the clipboard stays untouched.
    private func deliver(_ text: String, landed: Bool) async {
        if landed {
            await endActivity(content(.copied, tail: LiveTranscript.tail(of: text)))
            return
        }
        let changed = clipboard.write(text)
        await endActivity(content(changed ? .copied : .tapToCopy, tail: LiveTranscript.tail(of: text)))
    }

    private func finishRun(_ outcome: Outcome, ended: Bool = true) -> Outcome {
        phase = .idle
        session = nil
        feed = nil
        run = nil
        if ended { onIdle?() }
        return outcome
    }

    /// A start failed: the session is gone (it tore its own lease down), and so is its feed.
    private func discard(_ s: DictationSession) async {
        session = nil
        s.onRunAborted = nil
        await drainTimers()
        if let dying = feed { await retire(dying) }
        feed = nil
        reportLease(nil)
    }

    /// Ends a held lease and its feed for good.
    private func release(_ lease: HeldLease) async {
        lease.session.onLeaseExpired = nil
        await lease.session.endLease()
        await retire(lease.feed)
        reportLease(nil)
    }

    /// The kept lease ran out on its own.
    private func leaseExpired(_ s: DictationSession) async {
        guard let lease = held, lease.session === s else { return }
        held = nil
        await retire(lease.feed)
        reportLease(nil)
    }

    private func reportLease(_ until: Date?) {
        guard until != reportedLease else { return }
        reportedLease = until
        sink?.leaseChanged(until: until)
    }

    private func content(_ phase: DictationPhase, tail: String = "") -> DictationActivityContent {
        DictationActivityContent(startedAt: startedAt, tail: tail, phase: phase)
    }

    private func updateActivity(_ content: DictationActivityContent, staleDate: Date?) async {
        guard activityLive else { return }
        await activity.update(content, staleDate: staleDate)
    }

    private func endActivity(_ content: DictationActivityContent) async {
        guard activityLive else { return }
        activityLive = false
        await activity.end(content)
    }

    /// Pushes the live tail to the activity while listening. Throttled unless `force`d; a throttled
    /// edit is published by the trailing task when the window ends. Returns whether it published.
    @discardableResult
    private func publishListening(force: Bool, fromTrailing: Bool = false) async -> Bool {
        guard phase == .listening, activityLive else { return false }
        let t = now()
        guard let tail = live.publish(now: t, force: force) else {
            startTrailing()
            return false
        }
        lastPublishAt = t
        // This publish carries the latest tail; a pending trailing one would only repeat it.
        if !fromTrailing { trailing?.cancel(); trailing = nil }
        publishing += 1
        await activity.update(content(.listening, tail: tail), staleDate: t.addingTimeInterval(Self.staleAfter))
        publishing -= 1
        if publishing == 0 { wakeQuiesceWaiters() }
        return true
    }

    /// Returns once no activity update is in flight.
    private func quiesceActivity() async {
        while publishing > 0 { await withCheckedContinuation { quiesceWaiters.append($0) } }
    }

    private func wakeQuiesceWaiters() {
        let pending = quiesceWaiters
        quiesceWaiters = []
        for waiter in pending { waiter.resume() }
    }

    /// Schedules the trailing publish at `lastPublishAt + minPublishInterval`, unless one is pending.
    private func startTrailing() {
        guard trailing == nil else { return }
        let sleep = self.sleep
        trailing = Task { [weak self] in
            await self?.runTrailing(sleep: sleep)
            // Cancelled means a publish superseded it or the run ended; the canceller owns the handle.
            if !Task.isCancelled { self?.clearTrailing() }
        }
    }

    private func runTrailing(sleep: @Sendable (Duration) async throws -> Void) async {
        while !Task.isCancelled, phase == .listening, let last = lastPublishAt {
            let wait = last.addingTimeInterval(LiveTranscript.minPublishInterval).timeIntervalSince(now())
            do { try await sleep(.seconds(max(wait, 0))) } catch { return }
            guard !Task.isCancelled else { return }
            if await publishListening(force: false, fromTrailing: true) { return }
        }
    }

    private func clearTrailing() { trailing = nil }

    // MARK: Edit feed

    /// One feed per session instance, for as long as the session lives: a held lease keeps its feed
    /// between runs, because cancelling the iteration of a session's `edits` ends the stream for good.
    private func startFeed(of s: DictationSession) -> EditFeed {
        let sessionFeed = EditFeed()
        let edits = s.edits
        sessionFeed.task = Task { [weak self, sessionFeed] in
            for await edit in edits {
                guard let self else { return }
                live.apply(edit)
                sink?.update(committed: live.committed, volatile: live.volatile)
                sessionFeed.noteConsumed()
                await publishListening(force: false)
            }
        }
        return sessionFeed
    }

    /// Returns once the feed has seen every edit the session published so far.
    private func flush(_ sessionFeed: EditFeed, of s: DictationSession) async {
        while !sessionFeed.finished, sessionFeed.consumed < s.editCount { await sessionFeed.waitForProgress() }
    }

    private func retire(_ sessionFeed: EditFeed) async {
        sessionFeed.task?.cancel()
        await sessionFeed.task?.value
        sessionFeed.finish()
    }

    private func startHeartbeat() {
        let sleep = self.sleep
        heartbeat = Task { [weak self] in
            while !Task.isCancelled {
                do { try await sleep(Self.heartbeatInterval) } catch { return }
                guard let self else { return }
                await publishListening(force: true)
            }
        }
    }

    /// Stops the heartbeat and the trailing publish and waits out any update they have in flight.
    private func drainTimers() async {
        let tasks = [heartbeat, trailing].compactMap { $0 }
        heartbeat = nil
        trailing = nil
        for task in tasks { task.cancel() }
        for task in tasks { await task.value }
    }
}

private extension Duration {
    var timeInterval: TimeInterval {
        let parts = components
        return TimeInterval(parts.seconds) + TimeInterval(parts.attoseconds) / 1e18
    }
}
