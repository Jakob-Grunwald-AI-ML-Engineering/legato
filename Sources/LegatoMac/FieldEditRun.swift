import Foundation
import LegatoFieldEdit

/// What ``FieldEditRun`` needs of the run's agent (the cleanup agent in the apps): the ``FieldAgent`` calls plus
/// the two entry points beyond them. Closures, so this target does not depend on the agent's module.
public struct FieldRunAgent: Sendable {
    var consume: @Sendable (FeedBatch) async -> [EditTransaction]
    var conflicted: @Sendable (Conflict, UUID) async -> Void
    var superseded: @Sendable (UUID, UUID) async -> Void
    var replan: @Sendable () async -> [EditTransaction]
    var finish: @Sendable () async -> [EditTransaction]

    public init(
        _ agent: some FieldAgent, replan: @escaping @Sendable () async -> [EditTransaction],
        finish: @escaping @Sendable () async -> [EditTransaction]
    ) {
        consume = { await agent.consume($0) }
        conflicted = { await agent.conflicted($0, for: $1) }
        superseded = { await agent.superseded($0, by: $1) }
        self.replan = replan
        self.finish = finish
    }
}

/// The edit queue's wiring for one dictation run on the Mac (the setting "Experimental: edit queue and cleanup
/// agent" on): a ``FieldEditQueue`` driven by an ``AXFieldExecutor`` behind a ``TypingGuard``, the
/// ``QueuedFieldWriteChannel`` the run's ``FieldWriter`` writes through, and, in Live mode, the run's agent.
///
/// - **Owner per run.** The controller creates one per run for the focused field, gives its ``channel`` to the
///   `FieldWriter` and calls ``attach(writer:)``. Replace and Hold have no agent: the writer's one swap or
///   insert goes through the channel, and ``wait(_:)`` is the pause its held-swap retry uses.
/// - **Feed.** With an agent, the queue's feed is read in-process: every wake (the writer put text in
///   (``textChanged()``), the field changed (the activity source), a held edit may run) is one pump that
///   refreshes the field, hands the new feed entries to the agent as a ``FeedBatch``, submits what it returns in
///   the cleanup lane and runs it. The agent's conflicts and supersedes go back to it. ``start()`` makes the
///   first batch, so the agent knows the field before the run's first text lands.
/// - **The writer follows the agent.** An agent step that lands is folded into the writer
///   (``FieldWriter/absorb(_:)``) in the same main-actor step as the write, so the writer's next check still
///   reads the field as expected.
/// - **Stop.** ``finish()`` catches the agent up, takes its final pass, runs it, and waits (at most
///   ``finalHoldBudget``) for typing to pause; what has not landed by then is withdrawn and reported in
///   ``Outcome/unapplied`` for the caller's clipboard fallback.
@MainActor
public final class FieldEditRun {
    /// The longest a stop waits for the user to stop typing before the agent's final edits are given up.
    public static let finalHoldBudget: TimeInterval = 2
    /// Pump rounds per wake before it hands over to the next wake.
    static let maxRounds = 8

    public struct Outcome: Sendable, Equatable {
        /// The agent's final-pass edits that did not land (conflicted, or still held when the budget ran out).
        public var unapplied: [EditTransaction]
    }

    public let executor: AXFieldExecutor
    public let channel: QueuedFieldWriteChannel
    public let typingGuard: TypingGuard
    /// Whether an agent works on this run (Live): the session's own live passes must not.
    public var agentRuns: Bool { agent != nil }

    private let agent: FieldRunAgent?
    private let pause: @MainActor @Sendable (TimeInterval) async -> Void
    private weak var writer: FieldWriter?
    private var wakes: AsyncStream<Void>.Continuation?
    private var consumer: Task<Void, Never>?
    private var wakeQueued = false
    private var pumping = false
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []
    private var retrying = false
    private var closed = false
    /// The last feed entry handed to the agent / folded into the writer.
    private var fedThrough: Int?
    private var absorbedThrough = 0
    /// The agent's edits submitted and without an outcome yet.
    private var outstanding: [UUID: EditTransaction] = [:]
    private var applied: Set<UUID> = []

    /// Nil when the field cannot be read (no queue can start): the run then writes directly, as with the
    /// setting off.
    public init?(
        target: any TextTarget, owner: String, agent: FieldRunAgent?, activity: (any FieldActivitySource)? = nil,
        quiet: TimeInterval = TypingGuard.defaultQuiet,
        now: @escaping @MainActor () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        pause: @escaping @MainActor @Sendable (TimeInterval) async -> Void = { try? await Task.sleep(for: .seconds($0)) }
    ) {
        let box = WeakRun()
        let source = activity.map { ForwardingActivitySource(base: $0) { box.run?.textChanged() } }
        let typingGuard = TypingGuard(source: source, quiet: quiet, now: now)
        guard let executor = AXFieldExecutor(target: target, typingGuard: typingGuard) else {
            typingGuard.stop()
            return nil
        }
        self.executor = executor
        self.typingGuard = typingGuard
        channel = QueuedFieldWriteChannel(executor: executor, owner: owner)
        self.agent = agent
        self.pause = pause
        box.run = self
    }

    /// The writer of this run: it follows the agent's edits.
    public func attach(writer: FieldWriter) { self.writer = writer }

    /// Gives the agent its first batch (the field as it is) and starts reading the feed. Call it before the
    /// run's first text lands.
    public func start() async {
        guard let agent, consumer == nil else { return }
        let (stream, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        wakes = continuation
        let first = executor.queue.feed.since(nil)
        fedThrough = first.lastSeq
        submit(await agent.consume(first))
        executor.drain()
        absorbLanded()
        consumer = Task { [weak self] in
            for await _ in stream {
                guard let self else { return }
                await self.handleWake()
            }
        }
    }

    /// The run's text, or the field, changed: read the feed again.
    public func textChanged() {
        guard agent != nil, !closed, !wakeQueued, let wakes else { return }
        wakeQueued = true
        wakes.yield()
    }

    /// Returns once every wake so far has been handled.
    public func idle() async {
        while wakeQueued || pumping { await withCheckedContinuation { idleWaiters.append($0) } }
    }

    /// Waits `seconds` (the pause a held write retries after).
    public func wait(_ seconds: TimeInterval) async { await pause(seconds) }

    // MARK: Stop

    /// The run is over: the agent's final pass, run to the end (see the type's notes). Without an agent it only
    /// closes the run's guard.
    public func finish() async -> Outcome {
        guard let agent, !closed else {
            close()
            return Outcome(unapplied: [])
        }
        wakes?.finish()
        await consumer?.value
        consumer = nil
        wakeQueued = false
        await pump()
        let finals = await agent.finish()
        let ids = Set(finals.map(\.id))
        submit(finals)
        var waited: TimeInterval = 0
        func pending() -> Bool { outstanding.keys.contains(where: ids.contains) }
        while pending() {
            executor.refresh()
            let result = executor.drain()
            absorbLanded()
            _ = await route(to: agent)
            if !pending() { break }
            guard case .held(let delay) = result, waited + delay <= Self.finalHoldBudget else { break }
            waited += delay
            await pause(delay)
        }
        for id in ids where outstanding[id] != nil { executor.withdraw(id) }
        _ = executor.takeEvents()
        close()
        return Outcome(unapplied: finals.filter { !applied.contains($0.id) })
    }

    /// Ends the run without a final pass (cancelled): pending edits are taken back, the guard stops.
    public func cancel() {
        for id in outstanding.keys { executor.withdraw(id) }
        outstanding = [:]
        close()
    }

    private func close() {
        closed = true
        wakes?.finish()
        consumer?.cancel()
        typingGuard.stop()
        resumeIdle()
    }

    /// The cleaned text a clipboard fallback should carry when `unapplied` edits did not land: `shown` (the
    /// run's text in the field) with each such patch applied where its expected text occurs exactly once.
    public static func fallbackText(shown: String, unapplied: [EditTransaction]) -> String {
        var text = shown
        for step in unapplied.flatMap(\.steps) where !step.expect.isEmpty {
            let parts = text.components(separatedBy: step.expect)
            if parts.count == 2 { text = parts[0] + step.text + parts[1] }
        }
        return text
    }

    // MARK: Pump

    private func handleWake() async {
        wakeQueued = false
        pumping = true
        await pump()
        pumping = false
        if !wakeQueued { resumeIdle() }
    }

    private func resumeIdle() {
        let waiting = idleWaiters
        idleWaiters = []
        for waiter in waiting { waiter.resume() }
    }

    private func submit(_ transactions: [EditTransaction]) {
        for transaction in transactions {
            outstanding[transaction.id] = transaction
            executor.submit(transaction)
        }
    }

    /// Folds the agent's landed steps into the writer. Synchronous with the write that landed them.
    private func absorbLanded() {
        let feed = executor.queue.feed
        for entry in feed.entries where entry.seq > absorbedThrough {
            if case .applied(_, .agent, let steps, _) = entry.event {
                for step in steps { writer?.absorb(step) }
            }
        }
        absorbedThrough = feed.lastSeq
    }

    /// Hands the agent the outcomes of its edits; true when any was handed back (it re-plans).
    private func route(to agent: FieldRunAgent) async -> Bool {
        var handedBack = false
        for event in executor.takeEvents() {
            switch event {
            case .applied(let id, _):
                if outstanding.removeValue(forKey: id) != nil { applied.insert(id) }
            case .conflict(let id, let conflict):
                guard outstanding.removeValue(forKey: id) != nil else { continue }
                handedBack = true
                await agent.conflicted(conflict, id)
            case .superseded(let id, let by):
                guard outstanding.removeValue(forKey: id) != nil else { continue }
                handedBack = true
                await agent.superseded(id, by)
            case .withdrawn(let id):
                outstanding.removeValue(forKey: id)
            }
        }
        return handedBack
    }

    private func pump() async {
        guard let agent, !closed else { return }
        for _ in 0..<Self.maxRounds {
            executor.refresh()
            absorbLanded()
            let handedBack = await route(to: agent)
            let batch = executor.queue.feed.since(fedThrough)
            var made: [EditTransaction] = []
            if batch.resync || !batch.entries.isEmpty {
                fedThrough = batch.lastSeq
                made = await agent.consume(batch)
            } else if handedBack {
                made = await agent.replan()
            }
            if closed { return }
            submit(made)
            let result = executor.drain()
            absorbLanded()
            if case .held(let delay) = result { retry(after: delay) }
            if made.isEmpty, !handedBack, executor.queue.feed.lastSeq <= (fedThrough ?? 0) { return }
        }
        textChangedAfterPump()
    }

    private func textChangedAfterPump() {
        guard !closed, !wakeQueued, let wakes else { return }
        wakeQueued = true
        wakes.yield()
    }

    /// A held edit runs again once the user has paused for `delay`.
    private func retry(after delay: TimeInterval) {
        guard !retrying, !closed else { return }
        retrying = true
        Task { [weak self] in
            guard let self else { return }
            await self.pause(delay)
            self.retrying = false
            self.textChanged()
        }
    }
}

/// Lets the activity source's handler reach the run that is still being built.
@MainActor
private final class WeakRun {
    weak var run: FieldEditRun?
}

/// Passes the field's change notifications on to the guard and to the run.
@MainActor
private final class ForwardingActivitySource: FieldActivitySource {
    private let base: any FieldActivitySource
    private let onChange: @MainActor () -> Void

    init(base: any FieldActivitySource, onChange: @escaping @MainActor () -> Void) {
        self.base = base
        self.onChange = onChange
    }

    func start(_ handler: @escaping @MainActor () -> Void) -> Bool {
        base.start { [onChange] in
            handler()
            onChange()
        }
    }

    func stop() { base.stop() }
}
