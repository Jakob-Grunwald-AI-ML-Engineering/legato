import Foundation

/// The app's end of the link, without any dictation or UIKit knowledge: publishes the run's state for
/// the keyboard (`link.host`), answers the keyboard's requests (`link.request` -> `link.ack`) and
/// reads what the keyboard reports (`link.presence`, `link.applied`).
///
/// Publishing: phase changes go out at once; text updates at most every `LinkChannel.minPublishInterval`
/// (a held-back update is published when its window ends). While a run or a lease exists the state is
/// re-published every `LinkChannel.beatInterval` with a fresh `beatAt`, so a keyboard can tell a live
/// app from a dead one.
@MainActor
public final class HostLink {
    /// Acts on an accepted request (start, stop or end the keep-alive).
    public var onRequest: (@MainActor (KeyboardRequest) async -> Void)?

    /// Called with every state written to `link.host` (for logging and the app's own UI).
    public var onPublish: (@MainActor (HostState) -> Void)?

    /// The state last written (and, between a held update and its publish, the one about to be).
    public private(set) var state: HostState

    private let store: LinkStore
    private let post: @Sendable (String) -> Void
    private let now: @Sendable () -> Date
    private let sleep: @Sendable (Duration) async throws -> Void
    private let ledger = RequestLedger()

    private var lastPublishAt: Date?
    private var trailing: Task<Void, Never>?
    private var beat: Task<Void, Never>?
    private var appliedWaiter: (runID: String, continuation: CheckedContinuation<Bool, Never>)?
    private var appliedTimeout: Task<Void, Never>?

    public init(
        store: LinkStore,
        post: @escaping @Sendable (String) -> Void = { DarwinObserver.post($0) },
        now: @escaping @Sendable () -> Date = { Date() },
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.store = store
        self.post = post
        self.now = now
        self.sleep = sleep
        state = HostState(
            runID: nil, phase: .idle, target: .app, committed: "", volatile: "", seq: 0, beatAt: now(),
            leaseUntil: nil, acceptsRemoteStart: false)
    }

    // MARK: Publishing

    public func runStarted(id: String, target: HostTarget) {
        state.runID = id
        state.target = target
        state.phase = .starting
        state.committed = ""
        state.volatile = ""
        publish()
    }

    public func update(committed: String, volatile: String) {
        state.committed = committed
        state.volatile = volatile
        if state.phase != .listening {
            state.phase = .listening
            publish()
        } else if let last = lastPublishAt, now().timeIntervalSince(last) < LinkChannel.minPublishInterval {
            scheduleTrailing(after: last)
        } else {
            publish()
        }
    }

    /// The run is over: the final state goes out at once, whatever was held back is dropped.
    public func runEnded(committed: String) {
        state.phase = .idle
        state.committed = committed
        state.volatile = ""
        publish()
    }

    /// The mic lease between runs: `until` is when it ends, nil when it is not held.
    public func leaseChanged(until: Date?) {
        state.leaseUntil = until
        state.acceptsRemoteStart = until != nil
        publish()
    }

    private func publish() {
        trailing?.cancel()
        trailing = nil
        let t = now()
        state.seq += 1
        state.beatAt = t
        lastPublishAt = t
        store.write(state, forKey: LinkChannel.Key.host)
        post(LinkChannel.Note.host)
        onPublish?(state)
        updateBeat()
    }

    private func scheduleTrailing(after last: Date) {
        guard trailing == nil else { return }
        let wait = max(last.addingTimeInterval(LinkChannel.minPublishInterval).timeIntervalSince(now()), 0)
        let sleep = self.sleep
        trailing = Task { [weak self] in
            do { try await sleep(.seconds(wait)) } catch { return }
            guard !Task.isCancelled else { return }
            self?.publish()
        }
    }

    private var isActive: Bool {
        (state.runID != nil && state.phase != .idle) || state.leaseUntil != nil
    }

    private func updateBeat() {
        guard isActive else {
            beat?.cancel()
            beat = nil
            return
        }
        guard beat == nil else { return }
        let sleep = self.sleep
        beat = Task { [weak self] in
            while !Task.isCancelled {
                do { try await sleep(.seconds(LinkChannel.beatInterval)) } catch { return }
                guard let self, !Task.isCancelled, isActive else { return }
                publish()
            }
        }
    }

    // MARK: Requests

    /// Handles the keyboard's request in the inbox. Called on the Darwin note, never at launch: a
    /// leftover request must not start a dictation (and a URL that opened the app carries the same id).
    ///
    /// A request the app can act on from where it is gets acted on once (the ledger drops copies) and an
    /// ack of `accepted`; one it can't gets `hop`, and stays admittable by the URL that opens the app.
    public func processInbox() async {
        guard let request = store.read(KeyboardRequest.self, forKey: LinkChannel.Key.request),
              now().timeIntervalSince(request.at) <= LinkChannel.requestMaxAge
        else { return }
        if ledger.contains(id: request.id) { // a copy: already being handled
            acknowledge(request.id, .accepted)
            return
        }
        guard canAct(on: request.command) else {
            acknowledge(request.id, .hop)
            return
        }
        _ = ledger.admit(id: request.id)
        // Ack first: acting (a dictation start) takes longer than the keyboard is willing to wait.
        acknowledge(request.id, .accepted)
        if willChangeSomething(request.command) { await onRequest?(request) }
    }

    /// `legato://keyboard?...&req=<id>` arrived: true the first time this id is seen (act on it).
    public func admitURL(requestID: String) -> Bool {
        ledger.admit(id: requestID)
    }

    private var isRunning: Bool { state.runID != nil && (state.phase == .starting || state.phase == .listening) }

    private func canAct(on command: RequestCommand) -> Bool {
        switch command {
        case .start: state.acceptsRemoteStart || isRunning
        case .stop: isRunning
        case .endKeepAlive: state.leaseUntil != nil
        }
    }

    /// A start while a run is already going is accepted but needs no action.
    private func willChangeSomething(_ command: RequestCommand) -> Bool {
        command != .start || !isRunning
    }

    private func acknowledge(_ id: String, _ result: AckResult) {
        store.write(KeyboardAck(id: id, result: result), forKey: LinkChannel.Key.ack)
        post(LinkChannel.Note.ack)
    }

    // MARK: From the keyboard

    public func keyboardIsVisible() -> Bool {
        store.read(KeyboardPresence.self, forKey: LinkChannel.Key.presence)?.isFresh(now: now()) ?? false
    }

    /// Waits up to `timeout` for the keyboard to report that run `runID`'s final text is in the field.
    public func awaitFinalApplied(runID: String, timeout: TimeInterval) async -> Bool {
        if finalApplied(runID: runID) { return true }
        resolveAppliedWaiter(false) // one waiter at a time
        let sleep = self.sleep
        return await withCheckedContinuation { continuation in
            appliedWaiter = (runID, continuation)
            appliedTimeout = Task { [weak self] in
                do { try await sleep(.seconds(timeout)) } catch { return }
                self?.resolveAppliedWaiter(false)
            }
        }
    }

    /// The Darwin note for `link.applied` arrived.
    public func appliedDidChange() {
        guard let waiter = appliedWaiter, finalApplied(runID: waiter.runID) else { return }
        resolveAppliedWaiter(true)
    }

    private func finalApplied(runID: String) -> Bool {
        guard let cursor = store.read(AppliedCursor.self, forKey: LinkChannel.Key.applied) else { return false }
        return cursor.runID == runID && cursor.finalApplied
    }

    private func resolveAppliedWaiter(_ result: Bool) {
        appliedTimeout?.cancel()
        appliedTimeout = nil
        guard let waiter = appliedWaiter else { return }
        appliedWaiter = nil
        waiter.continuation.resume(returning: result)
    }
}
