import Foundation

/// The decision logic behind one "dictate" button (Action Button, control, Live Activity stop):
/// each `toggle()` starts a dictation or stops the running one, and keeps the Live Activity and the
/// clipboard in step. Pure policy: ActivityKit, the pasteboard and the system checks are ports.
///
/// Order matters. The activity is requested *before* the session starts, because iOS stops a
/// recording intent that has no Live Activity. Every start builds a fresh `DictationSession` (and so
/// a fresh mic); nothing stays armed between dictations.
@MainActor
public final class DictationCoordinator {
    public enum Outcome: Sendable, Equatable {
        /// Listening; the next toggle stops.
        case started
        /// Finished and idle again. The text now on the clipboard, or nil when nothing was recognized
        /// (or the start was cancelled).
        case stopped(String?)
        /// Not started: resolve `ReadinessIssue` in the foreground first.
        case needsOnboarding(ReadinessIssue)
        /// The start failed (description of the error); the activity ended `failed`.
        case failed(String)
        /// A stop or abort is already being wrapped up; the press did nothing.
        case busy
    }

    /// While listening, the activity is refreshed this often so a pause in speech never looks stale.
    public static let heartbeatInterval: Duration = .seconds(10)
    /// How long after an update the system may treat the activity as stale.
    public static let staleAfter: TimeInterval = 30

    /// Fires after a run is over and its activity has ended (stopped, aborted or failed to start), with
    /// the coordinator idle again. The app decides what to do with the quiet moment (e.g. leave the
    /// background). Not fired when a press ends in `.needsOnboarding`: no run happened.
    public var onIdle: (@MainActor () -> Void)?

    private enum Phase { case idle, starting, listening, stopping, aborting }

    private let activity: any ActivityClient
    private let clipboard: any Clipboard
    private let readiness: any Readiness
    private let history: any HistoryStore
    private let makeSession: DictationSessionFactory
    private let sleep: @Sendable (Duration) async throws -> Void
    private let now: @Sendable () -> Date

    private var phase = Phase.idle
    private var session: DictationSession?
    private var live = LiveTranscript()
    private var startedAt = Date()
    /// A press arrived while starting; the start flow ends the run as soon as it can.
    private var cancelRequested = false
    private var consumer: Task<Void, Never>?
    private var heartbeat: Task<Void, Never>?
    /// Publishes an edit the throttle held back once its window ends, so the last words of a phrase
    /// followed by silence don't wait for the next heartbeat. At most one is pending.
    private var trailing: Task<Void, Never>?
    private var lastPublishAt: Date?

    public init(
        activity: any ActivityClient,
        clipboard: any Clipboard,
        readiness: any Readiness,
        history: any HistoryStore,
        makeSession: @escaping DictationSessionFactory,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.activity = activity
        self.clipboard = clipboard
        self.readiness = readiness
        self.history = history
        self.makeSession = makeSession
        self.sleep = sleep
        self.now = now
    }

    public func toggle() async -> Outcome {
        switch phase {
        case .idle: return await start()
        case .starting: return await cancelStart()
        case .listening: return await stop()
        case .stopping, .aborting: return .busy
        }
    }

    /// For system events (interruption, lost input, engine change, media reset): only ever ends a run,
    /// never begins one, so a late or duplicate event (e.g. the route change our own session
    /// deactivation raises) cannot start a dictation. Listening: stops like `toggle()`. Starting:
    /// cancels the start. Returns nil when there was nothing to stop (idle, or a stop or abort is
    /// already wrapping up).
    @discardableResult
    public func stopIfRunning() async -> Outcome? {
        switch phase {
        case .starting: return await cancelStart()
        case .listening: return await stop()
        case .idle, .stopping, .aborting: return nil
        }
    }

    // MARK: Start

    private func start() async -> Outcome {
        phase = .starting
        cancelRequested = false
        let issue = await readiness.check()
        if cancelRequested { return finishRun(.stopped(nil), ended: false) }
        if let issue { return finishRun(.needsOnboarding(issue), ended: false) }

        startedAt = now()
        live = LiveTranscript()
        lastPublishAt = nil
        do {
            try await activity.request(content(.starting))
        } catch {
            return finishRun(.needsOnboarding(.liveActivitiesDisabled), ended: false)
        }
        if cancelRequested {
            await activity.end(content(.failed))
            return finishRun(.stopped(nil))
        }

        let s = makeSession()
        session = s
        s.onRunAborted = { [weak self, weak s] _ in
            guard let self, let s else { return }
            Task { _ = await self.abort(s) }
        }
        startConsumer(of: s)
        do {
            try await s.start()
        } catch {
            await discard(s)
            await activity.end(content(.failed))
            switch error {
            case DictationError.cancelled: return finishRun(.stopped(nil))
            case DictationError.assetsNotInstalled: return finishRun(.needsOnboarding(.assetsMissing))
            default: return finishRun(.failed(String(describing: error)))
            }
        }
        guard session === s else { return .started } // aborted right away; `abort` is wrapping it up
        if cancelRequested { return await stop() } // pressed in the instant between listening and here

        phase = .listening
        startHeartbeat()
        await publishListening(force: true)
        return .started
    }

    /// A press while starting: stops through the session (which cancels a preparing start, so no
    /// audio session is ever activated); the start flow then ends the activity.
    private func cancelStart() async -> Outcome {
        cancelRequested = true
        if let s = session, s.runState == .preparing { _ = try? await s.stop() }
        return .stopped(nil)
    }

    // MARK: Stop

    private func stop() async -> Outcome {
        guard let s = session else { return .busy }
        phase = .stopping
        await drainTasks()
        guard session === s else { return .busy }
        await activity.update(content(.finishing, tail: live.tail()), staleDate: nil)
        guard session === s else { return .busy }

        do {
            // The session saves the entry to history itself; it is not appended again here.
            let entry = try await s.stop()
            s.onRunAborted = nil
            guard let entry else {
                // Nothing final was recognized: nothing to copy, nothing to show but the failure.
                await activity.end(content(.failed))
                return finishRun(.stopped(nil))
            }
            await deliver(entry.text)
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
        await drainTasks()
        s.onRunAborted = nil

        // The session's own text, not `live`: the edits consumer may still lag behind the abort.
        guard let entry = s.partialEntry() else {
            await activity.end(content(.failed))
            return finishRun(.stopped(nil))
        }
        try? await history.append(entry) // the session never saved this run; losing the copy is worse
        await deliver(entry.text)
        return finishRun(.stopped(entry.text))
    }

    // MARK: Pieces

    private func deliver(_ text: String) async {
        let changed = clipboard.write(text)
        await activity.end(content(changed ? .copied : .tapToCopy, tail: LiveTranscript.tail(of: text)))
    }

    private func finishRun(_ outcome: Outcome, ended: Bool = true) -> Outcome {
        phase = .idle
        session = nil
        if ended { onIdle?() }
        return outcome
    }

    private func discard(_ s: DictationSession) async {
        session = nil
        s.onRunAborted = nil
        await drainTasks()
    }

    private func content(_ phase: DictationPhase, tail: String = "") -> DictationActivityContent {
        DictationActivityContent(startedAt: startedAt, tail: tail, phase: phase)
    }

    /// Pushes the live tail to the activity while listening. Throttled unless `force`d; a throttled
    /// edit is published by the trailing task when the window ends. Returns whether it published.
    @discardableResult
    private func publishListening(force: Bool, fromTrailing: Bool = false) async -> Bool {
        guard phase == .listening else { return false }
        let t = now()
        guard let tail = live.publish(now: t, force: force) else {
            startTrailing()
            return false
        }
        lastPublishAt = t
        // This publish carries the latest tail; a pending trailing one would only repeat it.
        if !fromTrailing { trailing?.cancel(); trailing = nil }
        await activity.update(content(.listening, tail: tail), staleDate: t.addingTimeInterval(Self.staleAfter))
        return true
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

    /// One consumer per session instance, for that session's whole life.
    private func startConsumer(of s: DictationSession) {
        let edits = s.edits
        consumer = Task { [weak self] in
            for await edit in edits {
                guard let self else { return }
                live.apply(edit)
                await publishListening(force: false)
            }
        }
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

    /// Stops the consumer and heartbeat and waits out any update in flight, so nothing can land
    /// after the activity has moved on.
    private func drainTasks() async {
        let tasks = [consumer, heartbeat, trailing].compactMap { $0 }
        consumer = nil
        heartbeat = nil
        trailing = nil
        for task in tasks { task.cancel() }
        for task in tasks { await task.value }
    }
}
