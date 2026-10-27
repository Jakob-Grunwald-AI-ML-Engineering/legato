import Foundation

/// Orchestrates one dictation: an *audio lease* (policy active, mic armed) hosting *runs*
/// (one engine transcription each). With a `linger` the lease outlives a run so the next
/// run reuses the armed mic without re-activating the session.
///
/// Live cleanup (the post-processor's `cleansSegmentsLive`, read when a run starts): after each commit a
/// rolling pass cleans the run's whole raw text so far (raw only, never an earlier pass's output, so errors
/// don't compound) and publishes it as one `.revise` edit, a whole-span replacement (`TranscriptRevision`).
/// Latest wins: at most one pass runs; commits during it start one pass over the newest raw text when it
/// ends. Past ``liveWholeTextCharacters`` the text cleaned so far is frozen and passes cover only the
/// trailing window, with the frozen text as read-only context. Recognition never waits for a pass.
///
/// At the stop one final pass covers the whole raw text (a pass in flight over all of it is that pass; one
/// over older text gives way), within the processor's `liveStopTimeLimit`: past it the entry keeps the
/// newest published text and the raw tail. The entry's `rawText` is the whole raw text, `text` the final
/// cleaned one. A sent boundary (``liveTextSent(upTo:shownRevision:)``) closes the text before it: it is not
/// cleaned again and later passes start after it. An abort cancels the cleanup and revises nothing more.
@MainActor
public final class DictationSession {
    public enum LeaseState: Sendable, Equatable { case idle, arming, armed }
    public enum RunState: Sendable, Equatable { case idle, preparing, listening, finishing }

    public private(set) var leaseState: LeaseState = .idle
    public private(set) var runState: RunState = .idle
    /// The error that aborted the last run asynchronously (e.g. the engine stream failed).
    public private(set) var lastError: (any Error)?
    /// Edits for the current and later runs; apply them to a text sink in order.
    public let edits: AsyncStream<TranscriptEdit>
    /// Fires once when a run is aborted asynchronously (the engine stream failed while listening),
    /// after the run and lease are torn down. Not fired for failures `stop()` reports itself.
    /// The text recognized so far is still available from `partialEntry()`.
    public var onRunAborted: (@MainActor (any Error) -> Void)?
    /// Fires once when a lease held between runs (`linger`) runs out and is torn down. Not fired for
    /// `endLease()`, nor when there is no linger.
    public var onLeaseExpired: (@MainActor () -> Void)?
    /// How many edits have been published on `edits` so far; a consumer that has seen this many is caught up.
    public private(set) var editCount = 0

    private let engine: any DictationEngine
    private let source: any AudioSource
    private let sessionControl: any AudioSessionControlling
    private let history: any HistoryStore
    private let postProcessor: (any TranscriptPostProcessor)?
    /// The audio policy this session activates under (fixed at construction). A reused lease keeps it.
    public let policy: AudioPolicy
    public private(set) var linger: Linger
    private let sleep: @Sendable (Duration) async throws -> Void
    private let now: @Sendable () -> Date
    private let editsContinuation: AsyncStream<TranscriptEdit>.Continuation

    private var startTask: Task<Void, any Error>?
    private var consumeTask: Task<Void, Never>?
    private var lingerTask: Task<Void, Never>?
    private var assembler = TranscriptAssembler()
    private var runStart = Date()
    private var runLocale: Locale?
    private var streamFailure: (any Error)?
    /// Identifies the current run's consume task; events and errors from older runs are ignored.
    private var generation = 0
    /// The run's own abort teardown (stream failure) is in progress.
    private var isAborting = false

    /// Whole-text passes cover at most this many raw characters of the current segment; past it the text
    /// cleaned so far is frozen and a pass cleans only what follows (at most this much again).
    public static let liveWholeTextCharacters = 2_000

    /// Live trace (internal builds): every pass's outcome, every sent boundary. Lengths and times only.
    public var onLiveTrace: (@MainActor (LiveTraceEvent) -> Void)?

    /// The pass in flight.
    private struct LivePass {
        let n: Int
        /// The raw span it cleans ends here (what was committed when it began).
        let end: Int
        /// Its input starts here: the segment base, or past the cap the end of the frozen text.
        let from: Int
        /// The text shown for the raw text before `from` in the segment (empty without a frozen part).
        let frozenText: String
        let inputCharacters: Int
        let atStop: Bool
        let started: ContinuousClock.Instant
        var task: Task<Void, Never>?
    }

    /// The current run cleans live.
    private var cleansLive = false
    /// Where the current segment starts in the raw committed text: 0, or the last sent boundary.
    private var liveBase = 0
    /// The text the field showed for the parts sent so far (cleaned as far as it was), in order.
    private var sentText = ""
    /// The revisions published for the current segment, oldest first; the last one is what clients show.
    private var segmentRevisions: [TranscriptRevision] = []
    private var revisionCount = 0
    private var passCount = 0
    /// The raw end the last finished pass covered, whatever came of it: a stop with nothing past it needs no pass.
    private var lastPassEnd = 0
    /// Past the cap: the frozen start of the segment (its raw end, the text shown for it).
    private var frozen: (end: Int, text: String)?
    private var pass: LivePass?
    /// A stop began: no pass starts but the stop's own.
    private var liveStopping = false
    private let passClock = ContinuousClock()
    private var settleWaiters: [CheckedContinuation<Void, Never>] = []

    public init(
        engine: any DictationEngine,
        source: any AudioSource,
        sessionControl: any AudioSessionControlling,
        history: any HistoryStore,
        postProcessor: (any TranscriptPostProcessor)? = nil,
        policy: AudioPolicy = .default,
        linger: Linger = .off,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.engine = engine
        self.source = source
        self.sessionControl = sessionControl
        self.history = history
        self.postProcessor = postProcessor
        self.policy = policy
        self.linger = linger
        self.sleep = sleep
        self.now = now
        (edits, editsContinuation) = AsyncStream.makeStream()
    }

    // MARK: Run lifecycle

    /// Starts a run. Fails fast (before touching the audio session) when assets are missing.
    /// - Throws: `DictationError.alreadyRunning`, `.assetsNotInstalled`, `.cancelled` (stopped while
    ///   preparing), or whatever the engine, session or source threw. The session is torn down on failure.
    public func start(locale: Locale? = nil) async throws {
        guard runState == .idle else { throw DictationError.alreadyRunning }
        runState = .preparing
        lastError = nil
        streamFailure = nil
        let task = Task { try await self.performStart(locale: locale) }
        startTask = task
        defer { if startTask == task { startTask = nil } } // a newer run may own the handle by now
        do {
            try await task.value
        } catch is CancellationError {
            throw DictationError.cancelled
        }
    }

    /// Ends the run. Returns the saved entry, or nil when nothing final was recognized
    /// (or when stopped while still preparing). With a `postProcessor` the entry carries its result as
    /// `text` and the engine's text as `rawText` (see `DictationEntry.rawText`).
    public func stop() async throws -> DictationEntry? {
        switch runState {
        case .idle, .finishing:
            throw DictationError.notRunning
        case .preparing:
            startTask?.cancel()
            _ = await startTask?.result
            return nil
        case .listening:
            break
        }

        runState = .finishing
        liveStopping = true
        var entry: DictationEntry?
        var failure: (any Error)?
        do {
            await source.detach()
            try await engine.finish()
            await consumeTask?.value
            if let streamFailure { throw streamFailure }
            if cleansLive, let postProcessor { await finishLiveCleanup(with: postProcessor) }
            if var e = partialEntry() {
                if cleansLive {
                    applyLiveCleanup(to: &e)
                } else if let postProcessor {
                    await postProcess(&e, with: postProcessor)
                }
                try await history.append(e)
                entry = e
            }
        } catch {
            failure = error
        }

        // Every exit ends this run's consumer, so nothing of it can reach a later run.
        generation += 1
        cancelLiveCleanup()
        consumeTask?.cancel()
        await consumeTask?.value
        consumeTask = nil
        clearVolatile()
        runState = .idle
        if let failure {
            await teardownLease()
            throw failure
        }
        await releaseLease()
        return entry
    }

    /// Returns once the run's own abort teardown (after a stream failure) has finished and
    /// `onRunAborted` has fired; at once when no abort is in progress. A caller that must not start
    /// anything over that teardown (a new activation would be deactivated by it) waits here.
    public func settled() async {
        while isAborting { await withCheckedContinuation { settleWaiters.append($0) } }
    }

    /// The entry for the text committed so far in the current or last run (nil when there is none),
    /// built like the one `stop()` saves but not written to history: use it to salvage an aborted run.
    public func partialEntry() -> DictationEntry? {
        let text = assembler.committedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        return DictationEntry(
            date: runStart,
            text: text,
            localeIdentifier: (runLocale ?? Locale.current).identifier,
            engineID: engine.id,
            duration: now().timeIntervalSince(runStart)
        )
    }

    // MARK: Internals

    /// Runs the post-processor on the entry's (raw) text. A throw or a blank result keeps the raw text; a
    /// changed result becomes `text`, with the raw text kept as `rawText`.
    private func postProcess(_ entry: inout DictationEntry, with processor: any TranscriptPostProcessor) async {
        let raw = entry.text
        let locale = runLocale ?? Locale.current
        guard let out = try? await processor.process(raw, locale: locale) else { return }
        let processed = out.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !processed.isEmpty, processed != raw else { return }
        entry.text = processed
        entry.rawText = raw
    }

    private func performStart(locale: Locale?) async throws {
        do {
            await cancelLinger()
            let format = try await engine.prepare(locale: locale)
            try Task.checkCancellation()

            let input: AsyncStream<AudioChunk>
            if leaseState == .armed {
                do {
                    input = try await source.route()
                } catch let cancelled as CancellationError {
                    throw cancelled
                } catch {
                    // The armed source is dead (e.g. its engine stopped): re-arm from scratch.
                    await teardownLease()
                    input = try await arm(format)
                }
            } else {
                input = try await arm(format)
            }
            try Task.checkCancellation()

            assembler = TranscriptAssembler()
            runStart = now()
            runLocale = locale
            cleansLive = postProcessor?.cleansSegmentsLive ?? false
            if cleansLive { postProcessor?.liveRunStarts() }
            liveBase = 0
            sentText = ""
            segmentRevisions = []
            revisionCount = 0
            passCount = 0
            lastPassEnd = 0
            frozen = nil
            pass = nil
            liveStopping = false
            let events = engine.transcribe(input)
            runState = .listening
            generation += 1
            let gen = generation
            consumeTask = Task { await self.consume(events, generation: gen) }
        } catch {
            await teardownLease()
            runState = .idle
            throw error
        }
    }

    private func arm(_ format: AudioFormatSpec) async throws -> AsyncStream<AudioChunk> {
        leaseState = .arming
        try sessionControl.activate(policy.sessionConfig)
        let input = try await source.start(format: format)
        leaseState = .armed
        return input
    }

    private func consume(_ events: AsyncThrowingStream<TranscriptEvent, any Error>, generation gen: Int) async {
        do {
            for try await event in events {
                guard gen == generation else { return }
                for edit in assembler.apply(event) {
                    publish(edit)
                    if cleansLive, case .commit = edit { liveCommitted() }
                }
            }
        } catch {
            guard gen == generation else { return }
            lastError = error
            if runState == .listening {
                runState = .finishing // blocks stop() while aborting
                isAborting = true
                generation += 1
                cancelLiveCleanup()
                consumeTask = nil
                clearVolatile()
                await source.detach()
                await teardownLease()
                runState = .idle
                isAborting = false
                onRunAborted?(error)
                let pending = settleWaiters
                settleWaiters = []
                for waiter in pending { waiter.resume() }
            } else {
                streamFailure = error // stop() is in flight; it reports the failure
            }
        }
    }

    // MARK: Live cleanup

    /// A commit: a pass starts over the newest raw text unless one runs (it starts the next when it ends).
    private func liveCommitted() {
        guard !liveStopping, pass == nil, assembler.committedText.count > lastPassEnd else { return }
        startPass(atStop: false)
    }

    private func startPass(atStop: Bool) {
        guard let processor = postProcessor else { return }
        let raw = Array(assembler.committedText)
        let end = raw.count
        guard end > liveBase else { return }
        let (from, frozenText) = passWindow(end: end, raw: raw)
        let input = String(raw[from..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
        passCount += 1
        let n = passCount
        pass = LivePass(
            n: n, end: end, from: from, frozenText: frozenText, inputCharacters: input.count, atStop: atStop,
            started: passClock.now)
        guard !input.isEmpty else {
            passEnded(n, generation: generation, .success(LivePassResult(text: "")))
            return
        }
        let gen = generation
        let context = frozenText.trimmingCharacters(in: .whitespacesAndNewlines)
        let locale = runLocale ?? Locale.current
        pass?.task = Task {
            let result: Result<LivePassResult, any Error>
            do {
                result = .success(try await processor.cleanLivePass(input, context: context, locale: locale, atStop: atStop))
            } catch {
                result = .failure(error)
            }
            self.passEnded(n, generation: gen, result)
        }
    }

    /// Where a pass that ends at `end` starts, and the frozen text before it. Within the cap: the segment
    /// base, nothing frozen. Past it: the frozen part stays while the window after it fits; otherwise the
    /// newest published text is frozen (it is what clients show), or, without one that leaves a window
    /// within the cap, the shown text up to a word near the cap.
    private func passWindow(end: Int, raw: [Character]) -> (from: Int, frozenText: String) {
        let cap = Self.liveWholeTextCharacters
        guard end - liveBase > cap else {
            frozen = nil
            return (liveBase, "")
        }
        if let frozen, end - frozen.end <= cap { return (frozen.end, frozen.text) }
        if let newest = segmentRevisions.last, end - newest.end <= cap {
            frozen = (newest.end, newest.text)
        } else {
            var split = end - cap
            while split < end, !raw[split - 1].isWhitespace { split += 1 }
            if split == end { split = end - cap }
            frozen = (split, shownText(upTo: split, raw: raw))
        }
        return (frozen!.end, frozen!.text)
    }

    /// What clients show for the current segment's raw text up to `end`: the newest revision and the raw
    /// text after it, or the raw text.
    private func shownText(upTo end: Int, raw: [Character]) -> String {
        if let newest = segmentRevisions.last, newest.end <= end {
            return newest.text + String(raw[newest.end..<end])
        }
        return String(raw[liveBase..<end])
    }

    private func passEnded(_ n: Int, generation gen: Int, _ result: Result<LivePassResult, any Error>) {
        guard gen == generation, let p = pass, p.n == n else { return } // dropped: cancelled, aborted, superseded
        pass = nil
        lastPassEnd = max(lastPassEnd, p.end)
        let raw = Array(assembler.committedText)
        let final = p.atStop || (liveStopping && p.end == raw.count)
        switch result {
        case .failure:
            trace(p, output: 0, .error, final: final)
        case .success(let out):
            let cleaned = out.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let window = String(raw[p.from..<p.end])
            let outcome: LivePassReport.Outcome
            if cleaned.isEmpty || cleaned == window.trimmingCharacters(in: .whitespacesAndNewlines) {
                outcome = out.timedOut ? .timeout : out.guardRejected ? .guardRejected : .unchanged
            } else if let newest = segmentRevisions.last, newest.end >= p.end {
                outcome = .superseded
            } else {
                let text = p.frozenText + TranscriptRevision.keepingWhitespace(of: window, around: cleaned)
                if text == shownText(upTo: p.end, raw: raw) {
                    outcome = .unchanged
                } else {
                    revisionCount += 1
                    let revision = TranscriptRevision(
                        n: revisionCount, start: liveBase, raw: String(raw[liveBase..<p.end]), text: text)
                    segmentRevisions.append(revision)
                    publish(.revise(revision))
                    outcome = .published
                }
            }
            trace(p, output: cleaned.count, outcome, final: final, backend: out.backend, device: out.device)
        }
        if !liveStopping, raw.count > p.end { startPass(atStop: false) }
    }

    /// Drops the pass in flight (its result is never published) and traces it with `outcome`.
    @discardableResult
    private func cancelPass(_ outcome: LivePassReport.Outcome, final: Bool) -> Bool {
        guard let p = pass else { return false }
        pass = nil
        p.task?.cancel()
        trace(p, output: 0, outcome, final: final)
        return true
    }

    private func trace(
        _ p: LivePass, output: Int, _ outcome: LivePassReport.Outcome, final: Bool, backend: String? = nil,
        device: String? = nil
    ) {
        let ms = Int(p.started.duration(to: passClock.now) / .milliseconds(1))
        onLiveTrace?(.pass(LivePassReport(
            n: p.n, inputCharacters: p.inputCharacters, outputCharacters: output, milliseconds: ms, outcome: outcome,
            final: final, backend: backend, device: device)))
    }

    /// The field the run streams into was cleared (the user sent what it showed, as in a chat app) when it
    /// held the run's raw text up to `boundary`, shown as revision `shownRevision` (0: raw). That text is
    /// done: it is recorded as it was shown, never cleaned again, and passes start after it. A pass in flight
    /// over it is dropped. A boundary that does not move forward is ignored.
    /// Returns whether the boundary was taken.
    @discardableResult
    public func liveTextSent(upTo boundary: Int, shownRevision: Int) -> Bool {
        guard cleansLive, runState == .listening || runState == .finishing else { return false }
        let raw = Array(assembler.committedText)
        let end = min(boundary, raw.count)
        guard end > liveBase else { return false }
        let shown: String
        if let revision = segmentRevisions.first(where: { $0.n == shownRevision }), revision.end <= end {
            shown = revision.text + String(raw[revision.end..<end])
        } else {
            shown = String(raw[liveBase..<end])
        }
        let cancelled = cancelPass(.superseded, final: false) ? 1 : 0
        onLiveTrace?(.sent(LiveSentReport(
            rawCharacters: end - liveBase, shownCharacters: shown.count, cancelledPasses: cancelled)))
        sentText += shown
        liveBase = end
        segmentRevisions = []
        frozen = nil
        lastPassEnd = max(lastPassEnd, end)
        if !liveStopping, raw.count > end { startPass(atStop: false) }
        return true
    }

    /// At the stop: one final pass over the whole raw text, unless the last pass covered it already (a pass
    /// in flight over all of it is awaited; one over older text gives way), within the processor's
    /// `liveStopTimeLimit` when it has one. At that deadline the pass is cancelled; the newest published
    /// text and the raw tail stay.
    private func finishLiveCleanup(with processor: any TranscriptPostProcessor) async {
        if let p = pass, p.end < assembler.committedText.count { cancelPass(.superseded, final: false) }
        guard let limit = processor.liveStopTimeLimit else {
            await runFinalPass()
            return
        }
        let race = StopRace()
        let work = Task { await self.runFinalPass(); race.cleanupEnded() }
        let sleep = self.sleep
        let timer = Task { if (try? await sleep(limit)) != nil { race.finish() } }
        await race.wait()
        timer.cancel()
        guard !race.cleanupDone else { return }
        work.cancel()
        cancelPass(.timeout, final: true)
    }

    private func runFinalPass() async {
        if pass == nil, assembler.committedText.count > max(lastPassEnd, liveBase) { startPass(atStop: true) }
        await pass?.task?.value
    }

    /// The entry of a live-cleaned run: the sent parts as they were shown, then what clients show for the
    /// rest; the engine's text as `rawText` when they differ.
    private func applyLiveCleanup(to entry: inout DictationEntry) {
        let raw = Array(assembler.committedText)
        let shown = (sentText + shownText(upTo: raw.count, raw: raw)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !shown.isEmpty, shown != entry.text else { return }
        entry.rawText = entry.text
        entry.text = shown
    }

    private func cancelLiveCleanup() {
        pass?.task?.cancel()
        pass = nil
    }

    /// The stop's cleanup against its deadline: whichever ends first resumes the stop.
    @MainActor private final class StopRace {
        private var continuation: CheckedContinuation<Void, Never>?
        private var done = false
        private(set) var cleanupDone = false

        func wait() async {
            guard !done else { return }
            await withCheckedContinuation { continuation = $0 }
        }

        /// Called by the cleanup (when it ends) and by the timer (at the deadline).
        func finish() {
            guard !done else { return }
            done = true
            continuation?.resume()
            continuation = nil
        }

        /// The cleanup ended (so the deadline did not cut it).
        func cleanupEnded() {
            cleanupDone = true
            finish()
        }
    }

    private func publish(_ edit: TranscriptEdit) {
        editCount += 1
        editsContinuation.yield(edit)
    }

    /// Removes tentative text from the sink; a run never leaves volatile text behind.
    private func clearVolatile() {
        for edit in assembler.apply(TranscriptEvent(text: "", isFinal: false)) { publish(edit) }
    }

    /// Ends the lease: stops the mic, then deactivates the session. No-op when idle.
    private func teardownLease() async {
        guard leaseState != .idle else { return }
        await source.stop()
        sessionControl.deactivate()
        leaseState = .idle
    }

    /// After a successful run: deactivate now, after `linger` unless a new run starts, or never (indefinite).
    private func releaseLease() async {
        switch linger {
        case .off:
            await teardownLease()
        case .indefinite:
            break // no timer: held until `endLease`, an abort or a dead source
        case .duration(let duration):
            armExpiry(after: duration)
        }
    }

    private func armExpiry(after duration: Duration) {
        let sleep = self.sleep
        lingerTask = Task {
            do { try await sleep(duration) } catch { return }
            guard !Task.isCancelled, runState == .idle else { return }
            let held = leaseState != .idle
            await teardownLease()
            if held { onLeaseExpired?() }
        }
    }

    /// Changes how long the lease outlives runs. A lease held between runs follows at once: `.off` ends
    /// it, `.indefinite` drops its timer, a duration restarts the whole timer from now. During a run
    /// the new linger applies when the run ends.
    public func setLinger(_ new: Linger) async {
        guard new != linger else { return }
        linger = new
        guard runState == .idle, leaseState == .armed else { return }
        await cancelLinger()
        guard runState == .idle, leaseState == .armed, linger == new else { return }
        switch new {
        case .off: await teardownLease()
        case .indefinite: break
        case .duration(let duration): armExpiry(after: duration)
        }
    }

    /// Arms the lease without a run: activates the audio session and starts the mic (detached, nothing
    /// transcribes), so a later `start()` reuses it at once, also from the background. The lease then
    /// ends like one a run left behind: after `linger`, never for `.indefinite`. Arming a lease that is
    /// already armed only restarts its timer.
    /// - Throws: `DictationError.alreadyRunning`, `.assetsNotInstalled`, or whatever the engine, session
    ///   or source threw (the lease is torn down).
    public func armLease(locale: Locale? = nil) async throws {
        guard runState == .idle else { throw DictationError.alreadyRunning }
        await cancelLinger()
        do {
            if leaseState != .armed {
                let format = try await engine.prepare(locale: locale)
                _ = try await arm(format)
                await source.detach() // armed and idle, like a lease between two runs
            }
        } catch {
            await teardownLease()
            throw error
        }
        await releaseLease()
    }

    /// Sets the linger for the run that is about to reuse the held lease, leaving the lease itself alone
    /// (`setLinger` would end it at once for `.off`). The run's end applies it.
    public func adoptLinger(_ new: Linger) {
        linger = new
    }

    /// Tears down a lease held between runs now. No-op during a run or without a lease.
    public func endLease() async {
        guard runState == .idle, leaseState != .idle else { return }
        await cancelLinger()
        await teardownLease()
    }

    private func cancelLinger() async {
        guard let task = lingerTask else { return }
        task.cancel()
        await task.value // if expiry already began, let teardown finish
        lingerTask = nil
    }
}
