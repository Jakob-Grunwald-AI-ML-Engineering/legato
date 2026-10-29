import Foundation
import LegatoFieldEdit
import Synchronization

/// What ``FieldEditRun`` needs of the run's agent (the cleanup agent in the apps): the ``FieldAgent`` calls plus
/// the two entry points beyond them. Closures, so this target does not depend on the agent's module.
public struct FieldRunAgent: Sendable {
    var consume: @Sendable (FeedBatch) async -> [EditTransaction]
    var tentative: @Sendable (Int) async -> Void
    var conflicted: @Sendable (Conflict, UUID) async -> Void
    var superseded: @Sendable (UUID, UUID) async -> Void
    var replan: @Sendable () async -> [EditTransaction]
    var finish: @Sendable () async -> [EditTransaction]
    /// Whether there is an agent after all (a deferred one may turn out missing). Only asked once it was awaited.
    var available: @Sendable () async -> Bool = { true }
    /// The run is over: an agent that is made after this touches nothing (a deferred one drops every later call).
    var retire: @Sendable () -> Void = {}

    /// An agent that is made in the background (its model session may still be warming): every call waits for
    /// `make`, in the order the run makes them. When `make` returns nil there is no agent after all: the run's text
    /// stays as the engine heard it.
    public init(deferred make: @escaping @Sendable () async -> FieldRunAgent?) {
        let made = Task { await make() }
        let retired = Mutex(false)
        /// The agent, unless there is none or the run is over by the time it is there.
        @Sendable func agent() async -> FieldRunAgent? {
            let agent = await made.value
            return retired.withLock { $0 } ? nil : agent
        }
        consume = { batch in
            guard let agent = await agent() else { return [] }
            return await agent.consume(batch)
        }
        tentative = { length in
            if let agent = await agent() { await agent.tentative(length) }
        }
        conflicted = { conflict, id in
            if let agent = await agent() { await agent.conflicted(conflict, id) }
        }
        superseded = { id, by in
            if let agent = await agent() { await agent.superseded(id, by) }
        }
        replan = {
            guard let agent = await agent() else { return [] }
            return await agent.replan()
        }
        finish = {
            guard let agent = await agent() else { return [] }
            return await agent.finish()
        }
        available = { await made.value != nil }
        retire = { retired.withLock { $0 = true } }
    }

    public init(
        _ agent: some FieldAgent, tentative: @escaping @Sendable (Int) async -> Void = { _ in },
        replan: @escaping @Sendable () async -> [EditTransaction],
        finish: @escaping @Sendable () async -> [EditTransaction]
    ) {
        consume = { await agent.consume($0) }
        self.tentative = tentative
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
///   the cleanup lane and runs it. The agent's conflicts and supersedes go back to it. ``start()`` queues the
///   first batch ahead of every wake, so the agent knows the field before the run's first text lands, without
///   holding the run back.
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
        /// There was no agent to take a final pass: none came (no rolling session) or it was still warming past
        /// the run's cap. The caller cleans the run's text with the stateless pass (``deliverWithoutAgent(raw:clean:)``).
        public var agentAbsent = false
    }

    public let executor: AXFieldExecutor
    public let channel: QueuedFieldWriteChannel
    public let typingGuard: TypingGuard
    /// Whether an agent works on this run (Live): the session's own live passes must not.
    public var agentRuns: Bool { agent != nil }

    private let agent: FieldRunAgent?
    private let pause: @MainActor @Sendable (TimeInterval) async -> Void
    /// The longest a stop waits for an agent that is not ready yet (the run's cleanup time limit).
    private let agentWait: TimeInterval
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
        quiet: TimeInterval = TypingGuard.defaultQuiet, agentWait: TimeInterval = 2,
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
        self.agentWait = agentWait
        box.run = self
    }

    /// The writer of this run: it follows the agent's edits.
    public func attach(writer: FieldWriter) { self.writer = writer }

    /// Starts reading the feed for the agent, whose first batch is the field as it is now. It does not wait for the
    /// agent (its model session may still be warming): the batch is handed over in the background, before any
    /// later one, so the agent still knows the field before the run's first text. Call it before that text lands.
    public func start() {
        guard let agent, consumer == nil else { return }
        let (stream, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        wakes = continuation
        let first = executor.queue.feed.since(nil)
        fedThrough = first.lastSeq
        pumping = true
        consumer = Task { [weak self] in
            await self?.begin(agent, with: first)
            for await _ in stream {
                guard let self else { return }
                await self.handleWake()
            }
        }
    }

    private func begin(_ agent: FieldRunAgent, with first: FeedBatch) async {
        guard !closed else { return finishedBegin() }
        let made = await agent.consume(first)
        if !closed {
            submit(made)
            executor.drain()
            absorbLanded()
        }
        finishedBegin()
    }

    private func finishedBegin() {
        pumping = false
        if !wakeQueued { resumeIdle() }
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
        // Only the wait for the agent to exist is capped. Once it is there, its running pass and its final pass
        // are waited for (each bounded by the cleanup time limit): a busy agent is not an absent one.
        guard await Self.exists(agent, within: agentWait) == true else {
            // Still warming, or none: the agent is treated as absent. Whatever it does later changes nothing
            // (closed), and any edit it held is taken back before the caller cleans the text another way.
            consumer?.cancel()
            consumer = nil
            cancel()
            return Outcome(unapplied: [], agentAbsent: true)
        }
        await consumer?.value
        consumer = nil
        wakeQueued = false
        await pump()
        let finals = await agent.finish()
        submit(finals)
        // Every edit of the run without an outcome yet is waited for: the final pass's, and the rolling ones the
        // user's typing still holds back.
        let awaited = outstanding
        func pending() -> Bool { awaited.keys.contains(where: { outstanding[$0] != nil }) }
        var waited: TimeInterval = 0
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
        for id in awaited.keys where outstanding[id] != nil { executor.withdraw(id) }
        _ = executor.takeEvents()
        close()
        var all = awaited
        for final in finals { all[final.id] = final }
        let unapplied = all.values.filter { !applied.contains($0.id) }
            .sorted { ($0.steps.first?.span.location ?? 0) < ($1.steps.first?.span.location ?? 0) }
        return Outcome(unapplied: unapplied)
    }

    /// Whether there is an agent after all, or nil when that is not known within `seconds`. Neither side is waited
    /// for once the other has answered.
    private static func exists(_ agent: FieldRunAgent, within seconds: TimeInterval) async -> Bool? {
        let once = Once<Bool?>()
        return await withCheckedContinuation { continuation in
            once.continuation = continuation
            Task { once.resume(await agent.available()) }
            Task {
                try? await Task.sleep(for: .seconds(seconds))
                once.resume(nil)
            }
        }
    }

    /// The stop of a run whose agent was absent: `clean` (today's stateless final cleanup pass) turns the run's
    /// raw text into the cleaned one, which goes into the field as patches, as Replace does (a swap held back by
    /// typing waits for a pause, a little). Without a cleaned text the raw text stays.
    public func deliverWithoutAgent(raw: String, clean: (String) async -> String?) async -> FinishAction {
        guard let writer else { return .done }
        let cleaned = (await clean(raw))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !cleaned.isEmpty, cleaned != raw.trimmingCharacters(in: .whitespacesAndNewlines) else {
            return writer.finish(finalText: nil)
        }
        return await writer.finish(
            rawText: raw, cleanedText: cleaned, delivery: .replace, retryingFor: Self.finalHoldBudget,
            wait: { [pause] in await pause($0) })
    }

    /// Ends the run without a final pass (cancelled): pending edits are taken back, the guard stops.
    public func cancel() {
        for id in outstanding.keys { executor.withdraw(id) }
        outstanding = [:]
        close()
    }

    private func close() {
        closed = true
        wakeQueued = false
        wakes?.finish()
        consumer?.cancel()
        agent?.retire()
        typingGuard.stop()
        resumeIdle()
    }

    /// The cleaned text a clipboard fallback should carry when `unapplied` edits did not land: the run's text as
    /// the field holds it now, with each such edit applied where it belongs (see ``fallbackText(current:spanStart:unapplied:)``).
    public func clipboardText(unapplied: [EditTransaction]) -> String {
        guard let writer else { return "" }
        guard let start = writer.runStart else { return writer.shownText }
        executor.refresh()
        let feed = executor.queue.feed
        let window = feed.window as NSString
        // The run's text may have grown or shrunk by what the user typed inside it.
        var length = writer.shownText.utf16.count
        for entry in feed.entries {
            guard case .foreign(let step, true, _) = entry.event else { continue }
            if step.span.location >= start, step.span.end <= start + length { length += step.text.utf16.count - step.span.length }
        }
        let region = NSIntersectionRange(NSRange(location: start, length: length), NSRange(location: 0, length: window.length))
        let mapped = unapplied.map { transaction -> EditTransaction in
            var moved = transaction
            moved.steps = Self.mapped(transaction, through: feed.entries)
            return moved
        }
        return Self.fallbackText(current: window.substring(with: region), spanStart: start, unapplied: mapped)
    }

    /// `current` (the run's text in the field, starting at field offset `spanStart`) with each `unapplied` step
    /// applied at its position in the run (`span - spanStart`). The step's expected text is only a check: a step
    /// whose expected text is not there (the user changed it) is left out. Insertions are included. Steps are
    /// applied from the end, so none shifts another.
    static func fallbackText(current: String, spanStart: Int, unapplied: [EditTransaction]) -> String {
        var units = Array(current.utf16)
        for step in unapplied.flatMap(\.steps).sorted(by: { $0.span.location > $1.span.location }) {
            let lower = step.span.location - spanStart, upper = step.span.end - spanStart
            guard lower >= 0, upper <= units.count,
                  String(decoding: units[lower..<upper], as: UTF16.self) == step.expect
            else { continue }
            units.replaceSubrange(lower..<upper, with: Array(step.text.utf16))
        }
        return String(decoding: units, as: UTF16.self)
    }

    /// The steps of `transaction` (at its base version) at their place in the field now: moved through every
    /// change that landed since. A step the changes deleted, or after a reset, is left out.
    private static func mapped(_ transaction: EditTransaction, through entries: [FeedEntry]) -> [EditStep] {
        var steps = transaction.steps
        for entry in entries {
            guard let version = entry.event.version, version > transaction.base else { continue }
            let changes: [EditStep]
            switch entry.event {
            case .applied(_, _, let landed, _): changes = landed
            case .foreign(let step, _, _): changes = [step]
            case .rebased: continue
            default: return []
            }
            for change in changes {
                let map = StepMap(change)
                steps = steps.compactMap { step in
                    guard case .moved(let span) = map.map(step.span) else { return nil }
                    return EditStep(span: span, text: step.text, expect: step.expect)
                }
            }
        }
        return steps
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
            await agent.tentative(writer?.tentativeLength ?? 0)
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

/// Resumes its continuation once, from whichever side answers first.
private final class Once<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    var continuation: CheckedContinuation<Value, Never>?

    func resume(_ value: Value) {
        lock.lock()
        defer { lock.unlock() }
        guard !done else { return }
        done = true
        continuation?.resume(returning: value)
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
