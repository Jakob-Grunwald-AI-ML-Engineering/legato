import Foundation

/// The app's end of the link, without any dictation or UIKit knowledge: publishes the run's state for
/// the keyboard (`link.host`), answers the keyboard's requests (`link.request` -> `link.ack`) and
/// reads what the keyboard reports (`link.presence`, `link.applied`).
///
/// Publishing: phase changes go out at once; text updates at most every `LinkChannel.minPublishInterval`
/// (a held-back update is published when its window ends). While a run or a lease exists the state is
/// re-published every `LinkChannel.beatInterval` with a fresh `beatAt`, so a keyboard can tell a live
/// app from a dead one.
///
/// Dictated text does not stay in the App Group: a new link overwrites whatever an earlier process left
/// in `link.host` (an app that died mid-run would otherwise leave "listening" and the run's text there),
/// and a finished run's text leaves `link.host` and `link.applied` after `LinkChannel.finalTextRetention`.
@MainActor
public final class HostLink {
    /// Acts on an accepted request (start, stop or end the keep-alive).
    public var onRequest: (@MainActor (KeyboardRequest) async -> Bool)?

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
    private var scrub: Task<Void, Never>?

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
        // Whatever an earlier process left behind is stale by definition: say "idle, no text" now.
        store.write(state, forKey: LinkChannel.Key.host)
        store.remove(forKey: LinkChannel.Key.applied)
        store.remove(forKey: LinkChannel.Key.refine)
        store.remove(forKey: LinkChannel.Key.refined)
        post(LinkChannel.Note.host)
    }

    // MARK: Publishing

    /// `delivery`: how the run's cleaned text reaches the field (nil without cleanup); the keyboard needs
    /// it from the start, because `.hold` keeps the field free while listening.
    public func runStarted(id: String, target: HostTarget, delivery: HostDelivery? = nil) {
        cancelScrub()
        state.runID = id
        state.target = target
        state.phase = .starting
        state.committed = ""
        state.volatile = ""
        state.delivery = delivery
        state.finalText = nil
        state.revisions = nil
        publish()
    }

    /// Live cleanup replaced a committed span (`HostDelivery.live`): published at once.
    public func revise(_ revision: HostRevision) {
        guard state.runID != nil else { return }
        state.revisions = (state.revisions ?? []) + [revision]
        publish()
    }

    /// A stop began: published at once. Updates that still arrive while the engine finalizes keep the phase.
    public func runFinishing() {
        guard state.runID != nil, state.phase == .starting || state.phase == .listening else { return }
        state.phase = .finishing
        publish()
    }

    public func update(committed: String, volatile: String) {
        state.committed = committed
        state.volatile = volatile
        if state.phase != .listening, state.phase != .finishing {
            state.phase = .listening
            publish()
        } else if let last = lastPublishAt, now().timeIntervalSince(last) < LinkChannel.minPublishInterval {
            scheduleTrailing(after: last)
        } else {
            publish()
        }
    }

    /// The run is over: the final state goes out at once, whatever was held back is dropped. `finalText`:
    /// the post-processed text when it differs from the trimmed `committed` text.
    public func runEnded(committed: String, finalText: String? = nil) {
        state.phase = .idle
        state.committed = committed
        state.volatile = ""
        state.finalText = finalText
        publish()
        scheduleScrub()
    }

    /// Removes the dictated text from the link: `link.host` goes back to "idle, no run, no text" (a lease
    /// stays) and `link.applied` is deleted. Called when a finished run's retention ends, and when the
    /// user deletes history. Does nothing while a run is going on.
    public func scrubText() {
        guard !isRunning else { return }
        cancelScrub()
        store.remove(forKey: LinkChannel.Key.applied)
        store.remove(forKey: LinkChannel.Key.refine)
        store.remove(forKey: LinkChannel.Key.refined)
        guard state.runID != nil || !state.committed.isEmpty || !state.volatile.isEmpty || state.finalText != nil
        else { return }
        state.runID = nil
        state.phase = .idle
        state.committed = ""
        state.volatile = ""
        state.finalText = nil
        state.delivery = nil
        state.revisions = nil
        publish()
    }

    private func scheduleScrub() {
        cancelScrub()
        let sleep = self.sleep
        scrub = Task { [weak self] in
            do { try await sleep(.seconds(LinkChannel.finalTextRetention)) } catch { return }
            guard !Task.isCancelled else { return }
            self?.scrubText()
        }
    }

    private func cancelScrub() {
        scrub?.cancel()
        scrub = nil
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
        if willChangeSomething(request.command) {
            let succeeded = await onRequest?(request) ?? true
            // The keyboard took the first ack as "on it" and has stopped waiting. A start that then failed
            // (refused, not ready) needs the user to open the app: say so.
            if !succeeded, request.command == .start { acknowledge(request.id, .hop) }
        }
    }

    /// Answers a refine request (`processRefine`) with the refined text, or nil when there is none.
    public var onRefine: (@MainActor (String) async -> String?)?

    /// Handles the keyboard's refine request (`link.refine`), on its Darwin note: a fresh request is acked
    /// at once (the keyboard then waits up to `LinkChannel.refineTimeout`), removed from the store (it
    /// carries dictated text), answered once (`onRefine`) and the reply written to `link.refined`.
    public func processRefine() async {
        guard let request = store.read(RefineRequest.self, forKey: LinkChannel.Key.refine),
              now().timeIntervalSince(request.at) <= LinkChannel.requestMaxAge
        else { return }
        store.remove(forKey: LinkChannel.Key.refine)
        acknowledge(request.id, .accepted)
        guard ledger.admit(id: request.id) else { return } // a copy: already being answered
        let text = await onRefine?(request.text) ?? nil
        store.write(RefineReply(id: request.id, text: text), forKey: LinkChannel.Key.refined)
        post(LinkChannel.Note.refined)
    }

    /// What to do with a `legato://keyboard` URL.
    public enum URLAdmission: Sendable, Equatable {
        /// Our keyboard asked for this and nothing acted on it yet: act.
        case act
        /// Its request id was already handled (the Darwin note got there first): do not act twice.
        case alreadyHandled
        /// No fresh request from our keyboard backs this URL: just open the app, start nothing.
        case rejected
    }

    /// `legato://keyboard?...&req=<id>` arrived.
    ///
    /// Anything can open this URL (a web page, another app), and acting on it starts the microphone. So
    /// it only counts when our keyboard's own request for the same id and command sits in `link.request`
    /// and is recent; every other URL just opens the app. The ledger drops the copy when the Darwin note
    /// got there first.
    public func admitURL(requestID: String, command: RequestCommand) -> URLAdmission {
        if ledger.contains(id: requestID) { return .alreadyHandled }
        guard let request = store.read(KeyboardRequest.self, forKey: LinkChannel.Key.request),
              request.id == requestID, request.command == command,
              now().timeIntervalSince(request.at) <= LinkChannel.requestMaxAge
        else { return .rejected }
        _ = ledger.admit(id: requestID)
        return .act
    }

    /// A run is starting, listening or finishing (being stopped and post-processed).
    private var isRunning: Bool { state.runID != nil && state.phase != .idle }

    private func canAct(on command: RequestCommand) -> Bool {
        switch command {
        case .start: state.acceptsRemoteStart || isRunning
        case .stop: isRunning
        case .endKeepAlive: state.leaseUntil != nil
        case .arm: false // arming activates audio: only from the front, through the URL that opens the app
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
