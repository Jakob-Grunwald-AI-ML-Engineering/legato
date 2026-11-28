import Foundation

/// Publishes host liveness, microphone capture state and request admission.
/// Dictated text travels only through LiveDictationLink.
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
    private var beat: Task<Void, Never>?
    /// The accepted start still awaiting its result. Stop invalidates it before cancelling admission.
    private var pendingStartID: String?
    private var pendingStartRequests: Set<String> = []

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
            phase: .idle, seq: 0, beatAt: now(),
            leaseUntil: nil, acceptsRemoteStart: false)
        // Whatever an earlier process left behind is stale by definition: say "idle, no text" now.
        store.write(state, forKey: LinkChannel.Key.host)
        store.remove(forKey: LinkChannel.Key.applied)
        store.remove(forKey: LinkChannel.Key.refine)
        store.remove(forKey: LinkChannel.Key.refined)
        // An earlier process's instruction (its strip, a read or an edit carrying field text) is stale too.
        InstructionLink(store: store).clearAll()
        post(LinkChannel.Note.host)
        // So is a run it left open (a take held for the keyboard when iOS ended the app, #343): this process holds no run, and its
        // words are in History. A keyboard showing it lets it go (`KeyboardController.retireStagedTake`).
        let live = LiveDictationLink(store: store)
        if let left = live.read(), !left.complete {
            live.clear()
            post(LinkChannel.Note.dictationLive)
        }
    }

    // MARK: Publishing

    /// Capture state only. Dictated text is owned by the dictation channels.
    public func listeningChanged(_ listening: Bool) {
        let phase: HostPhase = listening ? .listening : .idle
        guard state.phase != phase else { return }
        state.phase = phase
        publish()
    }

    /// The word choices the keyboard queued (`link.choice.*`), oldest first. Every key read is deleted, the
    /// ones older than `LinkChannel.choiceMaxAge` and the ones that don't decode included. Not cleared at
    /// init: choices made while the app was away are still wanted.
    public func drainChoices(now: Date? = nil) -> [ChoiceRecord] {
        let cutoff = (now ?? self.now()).addingTimeInterval(-LinkChannel.choiceMaxAge)
        var fresh: [ChoiceRecord] = []
        for key in store.keys(withPrefix: LinkChannel.Key.choicePrefix) {
            if let record = store.read(ChoiceRecord.self, forKey: key), record.at >= cutoff { fresh.append(record) }
            store.remove(forKey: key)
        }
        return fresh.sorted { $0.at < $1.at }
    }

    /// Removes unread queued word choices when the user deletes history.
    public func removePendingChoices() {
        for key in store.keys(withPrefix: LinkChannel.Key.choicePrefix) { store.remove(forKey: key) }
    }

    /// The mic lease between runs: `until` is when it ends, nil when it is not held.
    public func leaseChanged(until: Date?) {
        state.leaseUntil = until
        state.acceptsRemoteStart = until != nil
        publish()
    }

    /// Explicit user cancellation (also from the app's Stop) invalidates the old request's reply.
    public func cancelPreparingStart() {
        settlePreparingStart(needsForeground: false)
    }

    private func settlePreparingStart(needsForeground: Bool) {
        guard pendingStartID != nil else { return }
        state.startCompletion = HostStartCompletion(requestIDs: pendingStartRequests.sorted(), needsForeground: needsForeground)
        pendingStartID = nil
        pendingStartRequests = []
        state.preparingRequestID = nil
        publish()
    }

    /// A meeting started (true) or ended (false). While it records the state says so and keeps beating, so
    /// the keyboard trusts it and can say "Meeting recording" instead of offering to dictate.
    public func meetingChanged(active: Bool) {
        state.meetingRecording = active ? true : nil
        publish()
    }

    private func publish() {
        let t = now()
        state.seq += 1
        state.beatAt = t
        lastPublishAt = t
        store.write(state, forKey: LinkChannel.Key.host)
        post(LinkChannel.Note.host)
        onPublish?(state)
        updateBeat()
    }

    private var isActive: Bool {
        (state.phase != .idle) || state.preparingRequestID != nil || state.leaseUntil != nil || state.meetingRecording == true
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
        // Keep the leading edge available even when both Darwin notifications arrive after release.
        if let start = store.read(KeyboardRequest.self, forKey: LinkChannel.Key.previewHoldStart),
           start.command == .beginPreviewHold, !ledger.contains(id: start.id) {
            await process(start)
        }
        if let end = store.read(KeyboardRequest.self, forKey: LinkChannel.Key.previewHoldEnd),
           end.command == .releasePreviewHold || end.command == .cancelPreviewHold, !ledger.contains(id: end.id) {
            await process(end)
        }
        if let request = store.read(KeyboardRequest.self, forKey: LinkChannel.Key.request) { await process(request) }
    }

    private func process(_ request: KeyboardRequest) async {
        guard now().timeIntervalSince(request.at) <= LinkChannel.requestMaxAge else { return }
        if ledger.contains(id: request.id) { // a copy: already being handled
            acknowledge(request.id, .accepted)
            return
        }
        guard canAct(on: request.command) else {
            acknowledge(request.id, .hop)
            return
        }
        _ = ledger.admit(id: request.id)
        if request.command == .start, pendingStartID != nil {
            pendingStartRequests.insert(request.id)
        }
        // Ack first: acting (a dictation start) takes longer than the keyboard is willing to wait.
        acknowledge(request.id, .accepted)
        if willChangeSomething(request.command) {
            if request.command == .start {
                pendingStartID = request.id
                pendingStartRequests = [request.id]
                state.preparingRequestID = request.id
                publish()
            } else if request.command == .stop || request.command == .endKeepAlive {
                cancelPreparingStart()
            }
            let succeeded = await onRequest?(request) ?? true
            // The keyboard took the first ack as "on it" and has stopped waiting. A start that then failed
            // (refused, not ready) needs the user to open the app: say so.
            if request.command == .start, pendingStartID == request.id {
                settlePreparingStart(needsForeground: !succeeded)
                if !succeeded { acknowledge(request.id, .hop) }
            }
        } else if request.command == .start, pendingStartID == nil {
            // Already running/finishing: this accepted request needs no second admission or watcher.
            state.startCompletion = HostStartCompletion(requestIDs: [request.id], needsForeground: false)
            publish()
        }
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
    private var isRunning: Bool { state.phase != .idle }

    private func canAct(on command: RequestCommand) -> Bool {
        switch command {
        case .start: state.acceptsRemoteStart || isRunning
        case .stop: isRunning || pendingStartID != nil || state.leaseUntil != nil
        case .endKeepAlive: state.leaseUntil != nil
        // A manual take that is paused (#313) has no running phase but still holds words to send; the app ignores a send with nothing to send.
        case .send, .editPreview, .beginPreviewHold, .releasePreviewHold, .cancelPreviewHold, .sendRaw, .discard, .undoDiscard: true
        case .arm: false // arming activates audio: only from the front, through the URL that opens the app
        }
    }

    /// A start while a run is already going is accepted but needs no action.
    private func willChangeSomething(_ command: RequestCommand) -> Bool {
        command != .start || (!isRunning && pendingStartID == nil)
    }

    private func acknowledge(_ id: String, _ result: AckResult) {
        store.write(KeyboardAck(id: id, result: result), forKey: LinkChannel.Key.ack)
        post(LinkChannel.Note.ack)
    }

    // MARK: From the keyboard

    public func keyboardDocumentID() -> String? {
        guard let presence = store.read(KeyboardPresence.self, forKey: LinkChannel.Key.presence), presence.isFresh(now: now()) else { return nil }
        return presence.documentID
    }
    /// The keyboard's presence while it is fresh; nil once it disappeared or stopped beating.
    public func keyboardPresence() -> KeyboardPresence? {
        guard let presence = store.read(KeyboardPresence.self, forKey: LinkChannel.Key.presence), presence.isFresh(now: now()) else { return nil }
        return presence
    }
    public func keyboardIsVisible() -> Bool {
        store.read(KeyboardPresence.self, forKey: LinkChannel.Key.presence)?.isFresh(now: now()) ?? false
    }

}
