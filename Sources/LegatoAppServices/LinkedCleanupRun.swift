import Foundation
import LegatoFieldEdit

/// One iOS dictation run with the experimental edit queue ("Experimental: edit queue and cleanup agent" on), on
/// the app's side of the keyboard link. The keyboard owns the queue; this type reads its feed and sends edits.
///
/// - **Feed.** The keyboard publishes its field events as `FeedBatch`es to `link.feed` (``Transport/read``), a few
///   per second at most. Every batch is folded into a ``FeedMirror`` at once (also while the agent is still
///   warming: the ring is bounded). The agent takes what arrived once per wake: the batches since its last call
///   folded into one, so a pass plans on the newest field.
/// - **Agent (Live).** Made in the background on the warm rolling session (``init(owner:agent:transport:agentWait:finalWait:)``);
///   the run never waits for it. Its calls run one at a time, in the order the run makes them: feed batches,
///   the in-process ASR text (``heard(committed:volatile:)``: `hear` for newly committed text, the tentative
///   length). Its transactions go to the keyboard over `link.edits` (cleanup lane), based on the newest batch's
///   version and queue instance; their conflicts and supersedes come back in the feed, which the agent reads
///   itself (it re-plans in the same call).
/// - **Stop (Live).** ``finish()`` waits (``agentWait`` at most) for the agent to exist: absent, the caller cleans
///   the run with the stateless pass and writes it with ``deliver(raw:cleaned:)``. Present, it catches the agent
///   up, takes its final pass, sends it, and waits (``finalWait`` at most) for every edit of the run still without
///   an outcome; what did not land is ``Outcome/unapplied`` (the caller's clipboard fallback,
///   ``fallbackText(unapplied:)``).
/// - **Replace / absent agent.** ``deliver(raw:cleaned:)``: one stateless final pass's text as the smallest
///   patches of the run's text (``FeedMirror/patch(from:to:owner:origin:)``), one transaction, its outcome waited for.
@MainActor
public final class LinkedCleanupRun {
    /// How the run reaches the keyboard (the app's `FieldFeedLink` for the run).
    public struct Transport {
        /// The batches published since the last call, oldest first (the first call: since the run began).
        public var read: @MainActor () -> [FeedBatch]
        /// Queues transactions for the keyboard.
        public var send: @MainActor ([EditTransaction]) -> Void

        public init(read: @escaping @MainActor () -> [FeedBatch], send: @escaping @MainActor ([EditTransaction]) -> Void) {
            self.read = read
            self.send = send
        }
    }

    public struct Outcome: Sendable, Equatable {
        /// Edits still without an outcome at the stop (the final pass's included) that did not land by the end of
        /// the wait: conflicted then, or no outcome yet.
        public var unapplied: [EditTransaction]
        /// There was no agent (no rolling session, or still warming past ``agentWait``).
        public var agentAbsent = false
    }

    public enum Delivery: Sendable, Equatable {
        /// The patches landed: the field shows the cleaned text.
        case applied
        /// The keyboard handed them back (the user changed the text, the field moved on).
        case conflicted(Conflict)
        /// The field does not show the run's raw text as the run's (nothing attributed, the user edited it, sent).
        case notShown
        /// Nothing to change.
        case unchanged
        /// No outcome within ``finalWait``.
        case timedOut
    }

    /// The longest a stop waits for the run's edits to land.
    public let finalWait: Duration
    /// The longest a stop waits for an agent that is not there yet.
    public let agentWait: Duration
    /// The keyboard's field as the feed told it.
    public private(set) var mirror = FeedMirror()
    /// Diagnostics (the DEBUG e2e logs them); counts and outcomes only, no user text.
    public var trace: ((String) -> Void)?

    private let owner: String
    private let transport: Transport
    private let made: Task<CleanupAgent?, Never>?
    private var work: [Work] = []
    private var pumping: Task<Void, Never>?
    /// The agent is done with (finished, absent or cancelled): later agent work is dropped. The feed is still read.
    private var closed = false
    private var heardCount = 0
    private var lastTentative = -1
    /// The agent's edits sent, by id, until their outcome.
    private var outstanding: [UUID: EditTransaction] = [:]
    private var sent: [UUID: EditTransaction] = [:]

    private enum Work {
        case batch(FeedBatch)
        case hear(String)
        case tentative(Int)
    }

    /// `agent`: makes the run's agent (nil: none, e.g. Replace); it runs in the background, never blocking the run.
    public init(
        owner: String, agent: (@Sendable () async -> CleanupAgent?)?, transport: Transport,
        agentWait: Duration = .seconds(2), finalWait: Duration = .seconds(2)
    ) {
        self.owner = owner
        self.transport = transport
        self.agentWait = agentWait
        self.finalWait = finalWait
        made = agent.map { make in Task { await make() } }
    }

    /// Whether an agent works on this run (one was asked for; it may still turn out absent).
    public var hasAgent: Bool { made != nil }

    // MARK: While listening

    /// The keyboard published to the feed (its Darwin note), or the run's text changed: read and pump.
    public func feedChanged() {
        let batches = transport.read()
        guard !batches.isEmpty else { return }
        for batch in batches {
            fold(batch)
            if made != nil, !closed { work.append(.batch(batch)) }
        }
        pump()
    }

    /// The app's own recognized text (`DictationSession`): newly committed text is heard, the tentative tail is
    /// left out of what the agent may edit.
    public func heard(committed: String, volatile: String) {
        guard !closed, made != nil else { return }
        if committed.count > heardCount {
            work.append(.hear(String(committed.dropFirst(heardCount))))
            heardCount = committed.count
        }
        let tentative = volatile.isEmpty ? 0 : volatile.utf16.count + 1  // with the separator it may follow
        if tentative != lastTentative {
            work.append(.tentative(tentative))
            lastTentative = tentative
        }
        feedChanged()
        pump()
    }

    private func fold(_ batch: FeedBatch) {
        mirror.fold(batch)
        for entry in batch.entries {
            switch entry.event {
            case .applied(let id, _, _, _):
                if outstanding.removeValue(forKey: id) != nil { trace?("agent.outcome result=applied") }
            case .conflict(let id, let conflict):
                if outstanding.removeValue(forKey: id) != nil {
                    trace?("agent.outcome result=conflict reason=\(conflict.reason.rawValue) byUser=\(conflict.byUser ? 1 : 0) note=\(conflict.note == nil ? 0 : 1)")
                }
            case .superseded(let id, _), .withdrawn(let id):
                if outstanding.removeValue(forKey: id) != nil { trace?("agent.outcome result=superseded") }
            default: break
            }
        }
    }

    private func pump() {
        guard pumping == nil, !closed, !work.isEmpty, let made else { return }
        pumping = Task { [weak self] in
            guard let agent = await made.value else {
                self?.pumping = nil
                self?.work = []
                return
            }
            // Once per wake (like the Mac run's `since(fedThrough)`): everything that arrived while the agent was
            // busy is taken in together, so a pass plans on the newest field, not on each batch in turn.
            while let self, !self.closed, !self.work.isEmpty {
                let wake = Self.coalesced(self.work)
                self.work = []
                if !wake.heard.isEmpty { await agent.hear(wake.heard) }
                if let length = wake.tentative { await agent.setTentative(length: length) }
                for batch in wake.batches {
                    guard !self.closed else { break }
                    let edits = await agent.consume(batch)
                    if !self.closed { self.send(edits, final: false) }
                }
            }
            self?.pumping = nil
        }
    }

    /// The work of one wake: the heard text in order, the newest tentative length, and the batches with every run
    /// of consecutive deltas (same queue instance, no resync between) folded into one batch.
    private static func coalesced(_ work: [Work]) -> (heard: String, tentative: Int?, batches: [FeedBatch]) {
        var heard = "", tentative: Int?, batches: [FeedBatch] = []
        for item in work {
            switch item {
            case .hear(let text): heard += text
            case .tentative(let length): tentative = length
            case .batch(let batch):
                if !batch.resync, let last = batches.last, !last.resync, last.session == batch.session {
                    batches[batches.count - 1] = FeedBatch(
                        entries: last.entries + batch.entries, version: batch.version, session: batch.session,
                        through: batch.lastSeq ?? last.lastSeq)
                } else {
                    batches.append(batch)
                }
            }
        }
        return (heard, tentative, batches)
    }

    /// Whether `cleaned` is a text to give the user instead of `raw`: not empty, and not `raw` once trimmed.
    private static func changes(_ cleaned: String, _ raw: String) -> Bool {
        let cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        return !cleaned.isEmpty && cleaned != raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func send(_ transactions: [EditTransaction], final: Bool) {
        guard !transactions.isEmpty else { return }
        for transaction in transactions {
            outstanding[transaction.id] = transaction
            sent[transaction.id] = transaction
        }
        trace?("agent.edits n=\(transactions.count) steps=\(transactions.map(\.steps.count).reduce(0, +)) final=\(final ? 1 : 0)")
        transport.send(transactions)
    }

    // MARK: Stop

    /// The run is over (Live): see the type's notes.
    public func finish() async -> Outcome {
        guard let made, !closed else {
            cancel()
            return Outcome(unapplied: [], agentAbsent: true)
        }
        guard await Self.exists(made, within: agentWait) == true, let agent = await made.value else {
            trace?("agent.absent")
            cancel()
            return Outcome(unapplied: [], agentAbsent: true)
        }
        // Catch up: every batch so far, then the final pass.
        feedChanged()
        await pumping?.value
        while !work.isEmpty {
            pump()
            await pumping?.value
        }
        let finals = await agent.finish()
        send(finals, final: true)
        // Every edit of the run without an outcome yet: the final pass's, and rolling ones still on their way. One
        // handed back earlier was re-planned by the agent already.
        let awaited = Set(outstanding.keys)
        await waitForOutcomes(of: awaited)
        closed = true
        let unapplied = awaited.compactMap { id -> EditTransaction? in
            mirror.results[id] == .applied ? nil : sent[id]
        }.sorted { ($0.steps.first?.span.location ?? 0) < ($1.steps.first?.span.location ?? 0) }
        trace?("agent.finish edits=\(awaited.count) unapplied=\(unapplied.count)")
        return Outcome(unapplied: unapplied)
    }

    /// One stateless pass's text as patches of the run's text (Replace, or Live without an agent).
    public func deliver(raw: String, cleaned: String) async -> Delivery {
        feedChanged()
        let rawText = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanedText = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanedText.isEmpty, cleanedText != rawText else { return .unchanged }
        guard let transaction = mirror.patch(from: rawText, to: cleanedText, owner: owner) else {
            trace?("final.patch result=notShown")
            return .notShown
        }
        outstanding[transaction.id] = transaction
        sent[transaction.id] = transaction
        trace?("final.patch steps=\(transaction.steps.count)")
        transport.send([transaction])
        await waitForOutcomes(of: [transaction.id])
        let delivery: Delivery
        switch mirror.results[transaction.id] {
        case .applied: delivery = .applied
        case .conflict(let conflict): delivery = .conflicted(conflict)
        case .superseded, .withdrawn: delivery = .conflicted(Conflict(.overlap))
        case nil: delivery = .timedOut
        }
        trace?("final.patch result=\(Self.describe(delivery))")
        return delivery
    }

    /// How the run's cleaned text reaches the field.
    public enum Mode: Sendable, Equatable {
        /// The cleanup agent edits the run as it goes (or, absent, the stop's stateless pass as patches).
        case live
        /// The session's final pass, written as patches at the stop.
        case replace
    }

    /// What a stop left.
    public struct Stop: Sendable, Equatable {
        /// The final text is in the field, or the cleaned text is on the clipboard instead: the session's own text
        /// must not replace it there.
        public var landed: Bool
        /// The text the run's history entry should hold instead of the engine's (nil: keep it).
        public var cleaned: String?

        public init(landed: Bool, cleaned: String? = nil) {
            self.landed = landed
            self.cleaned = cleaned
        }
    }

    /// The whole stop of the run. `text`: the session's text (Live with the agent: the raw text; its own final
    /// pass was off); `finalText`: the session's cleaned text when it differs from the trimmed `committed`.
    /// `applied`: waits for the keyboard to confirm the streamed text; nil when no visible keyboard can.
    /// `statelessPass`: today's stateless final cleanup; `copy`: puts a text on the clipboard (false: unchanged).
    public func stop(
        _ mode: Mode, committed: String, text: String, finalText: String?, applied: (@MainActor () async -> Bool)?,
        statelessPass: @MainActor (String) async -> String?, copy: @MainActor (String) -> Bool
    ) async -> Stop {
        guard let applied else {
            cancel()
            // The agent was to clean this run, so the session's own final pass was off and `text` is raw: the
            // stateless pass cleans it for the clipboard (as for an absent agent). Without an agent the session's
            // text is already its cleaned text.
            guard mode == .live, hasAgent, let pass = await statelessPass(text), Self.changes(pass, text) else {
                return Stop(landed: false)
            }
            let landed = copy(pass)
            trace?("link.fallback copied=\(landed ? 1 : 0) keyboard=0")
            return Stop(landed: landed, cleaned: pass)
        }
        let confirmed = await applied()
        if mode == .replace {
            guard let finalText else { return Stop(landed: confirmed) }
            switch await deliver(raw: committed, cleaned: finalText) {
            case .applied, .unchanged: return Stop(landed: confirmed)  // unchanged: the stream is the text
            default: return Stop(landed: false)  // today's fallback: the session copies its cleaned text
            }
        }
        let outcome = await finish()
        var cleaned: String?
        var fallback: String?
        if outcome.agentAbsent {
            if let pass = await statelessPass(text) {
                switch await deliver(raw: committed, cleaned: pass) {
                case .applied: cleaned = pass
                case .unchanged: break
                default: fallback = pass
                }
            }
        } else if mirror.runText == nil, !mirror.wasCleared, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // The run's spans are unknown (the keyboard restarted: another queue's window is not searched): where
            // the agent's edits are cannot be told. The whole text cleaned by the stateless pass goes to the
            // clipboard, or the session's own text: never nothing.
            trace?("link.spans unknown")
            guard let pass = await statelessPass(text), Self.changes(pass, text) else { return Stop(landed: false) }
            let landed = copy(pass)
            trace?("link.fallback copied=\(landed ? 1 : 0)")
            return Stop(landed: landed, cleaned: pass)
        } else if outcome.unapplied.isEmpty {
            cleaned = mirror.runText
        } else {
            fallback = fallbackText(unapplied: outcome.unapplied)
        }
        var landed = confirmed
        if fallback != nil || !confirmed, let clip = fallback ?? cleaned, clip != text {
            // The field changed under the agent's edits (or never confirmed): the cleaned text goes to the clipboard.
            landed = copy(clip)
            trace?("link.fallback copied=\(landed ? 1 : 0)")
            cleaned = clip
        }
        return Stop(landed: landed, cleaned: mirror.wasCleared ? nil : cleaned)
    }

    /// The cleaned text for a clipboard fallback: the run's text as the field holds it, with each unapplied edit
    /// applied where it belongs (``FeedMirror/text(applying:)``).
    public func fallbackText(unapplied: [EditTransaction]) -> String? {
        mirror.text(applying: unapplied)
    }

    /// Ends the run without waiting: a late agent touches nothing.
    public func cancel() {
        closed = true
        work = []
        pumping?.cancel()
        pumping = nil
    }

    private func waitForOutcomes(of ids: Set<UUID>) async {
        let clock = ContinuousClock()
        let deadline = clock.now + finalWait
        while ids.contains(where: { mirror.results[$0] == nil }), clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(25))
            let batches = transport.read()
            for batch in batches { fold(batch) }
        }
    }

    /// Whether the agent is there, or nil when that is not known within `limit`. Neither side is waited for once
    /// the other answered (a task group would wait for an agent that never comes).
    private static func exists(_ made: Task<CleanupAgent?, Never>, within limit: Duration) async -> Bool? {
        let once = FirstAnswer()
        return await withCheckedContinuation { continuation in
            once.continuation = continuation
            Task { once.resume(await made.value != nil) }
            Task {
                try? await Task.sleep(for: limit)
                once.resume(nil)
            }
        }
    }

    private static func describe(_ delivery: Delivery) -> String {
        switch delivery {
        case .applied: "applied"
        case .conflicted(let conflict): "conflict reason=\(conflict.reason.rawValue) byUser=\(conflict.byUser ? 1 : 0)"
        case .notShown: "notShown"
        case .unchanged: "unchanged"
        case .timedOut: "timedOut"
        }
    }
}

/// Resumes its continuation once, from whichever side answers first.
private final class FirstAnswer: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    var continuation: CheckedContinuation<Bool?, Never>?

    func resume(_ value: Bool?) {
        lock.lock()
        defer { lock.unlock() }
        guard !done else { return }
        done = true
        continuation?.resume(returning: value)
    }
}
