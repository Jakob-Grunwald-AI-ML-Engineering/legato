import Foundation

/// Orchestrates one dictation: an *audio lease* (policy active, mic armed) hosting *runs*
/// (one engine transcription each). With a `linger` the lease outlives a run so the next
/// run reuses the armed mic without re-activating the session.
///
/// Live cleanup (the post-processor's `cleansSegmentsLive`, read when a run starts): every committed
/// segment is cleaned in the background, one at a time and in order, with the cleaned text before it as
/// context, and published as a `.revise` edit; recognition never waits for it. At the stop the segment in
/// flight finishes, the segments still raw are cleaned in one pass, and the entry keeps the revised text
/// (`rawText` the engine's). Both share one deadline, the processor's `liveStopTimeLimit`: past it they are
/// cancelled and the rest stays raw. An abort cancels the cleanup and revises nothing more.
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

    /// One committed segment of a live-cleaned run.
    private struct LiveSegment {
        /// Where it starts in the raw committed text, in characters.
        let start: Int
        let raw: String
        /// What the revised text shows for it once handled (its cleaned text, or its raw text when cleanup
        /// failed or changed nothing; empty for a segment a multi-segment revision covered). Nil: not yet.
        var shown: String?
    }

    /// The current run cleans its segments live.
    private var cleansLive = false
    private var segments: [LiveSegment] = []
    /// The first segment not cleaned (or being cleaned) yet.
    private var nextToClean = 0
    private var cleaner: Task<Void, Never>?
    /// A stop began: the cleaner takes no further segment (the stop pass cleans the rest).
    private var liveStopping = false
    /// How much of the cleaned text before a segment it gets as context (its end).
    static let liveContextCharacters = 400
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
            segments = []
            nextToClean = 0
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
                    if cleansLive, case .commit(let delta) = edit { addLiveSegment(delta) }
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

    private func addLiveSegment(_ raw: String) {
        let start = segments.last.map { $0.start + $0.raw.count } ?? 0
        segments.append(LiveSegment(start: start, raw: raw))
        startCleaner()
    }

    /// Starts the cleaner unless it runs already: it works through the segments in order, one at a time.
    private func startCleaner() {
        guard cleaner == nil, !liveStopping, nextToClean < segments.count, let processor = postProcessor else { return }
        let gen = generation
        cleaner = Task { await self.cleanSegments(with: processor, generation: gen) }
    }

    private func cleanSegments(with processor: any TranscriptPostProcessor, generation gen: Int) async {
        while gen == generation, !liveStopping, !Task.isCancelled, nextToClean < segments.count {
            let index = nextToClean
            nextToClean += 1
            let raw = segments[index].raw
            let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            var out: String?
            if !text.isEmpty {
                out = try? await processor.processSegment(
                    text, context: liveContext(before: index), locale: runLocale ?? Locale.current, atStop: false)
            }
            guard gen == generation, !Task.isCancelled else { return }
            settle(index..<index + 1, cleaned: out)
        }
        if gen == generation { cleaner = nil }
    }

    /// At the stop: lets the segment in flight finish, then cleans the segments still raw in one pass, all
    /// within the processor's `liveStopTimeLimit` when it has one. At that deadline both are cancelled and
    /// what was not cleaned keeps its raw text.
    private func finishLiveCleanup(with processor: any TranscriptPostProcessor) async {
        guard let limit = processor.liveStopTimeLimit else {
            await cleanRemainingSegments(with: processor)
            return
        }
        let race = StopRace()
        let work = Task { await self.cleanRemainingSegments(with: processor); race.cleanupEnded() }
        let sleep = self.sleep
        let timer = Task { if (try? await sleep(limit)) != nil { race.finish() } }
        await race.wait()
        timer.cancel()
        guard !race.cleanupDone else { return }
        work.cancel()
        cancelLiveCleanup()
        nextToClean = segments.count
    }

    private func cleanRemainingSegments(with processor: any TranscriptPostProcessor) async {
        await cleaner?.value
        cleaner = nil
        guard !Task.isCancelled else { return }
        let pending = nextToClean..<segments.count
        guard !pending.isEmpty else { return }
        nextToClean = segments.count
        let raw = segments[pending].map(\.raw).joined()
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        var out: String?
        if !text.isEmpty {
            out = try? await processor.processSegment(
                text, context: liveContext(before: pending.lowerBound), locale: runLocale ?? Locale.current,
                atStop: true)
        }
        guard !Task.isCancelled else { return }
        settle(pending, cleaned: out)
    }

    /// Records the outcome for `range` and publishes its revision when the cleaned text differs.
    private func settle(_ range: Range<Int>, cleaned out: String?) {
        let raw = segments[range].map(\.raw).joined()
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleaned = out?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !cleaned.isEmpty, cleaned != text else {
            for i in range { segments[i].shown = segments[i].raw }
            return
        }
        let revision = TranscriptRevision.cleaning(raw, at: segments[range.lowerBound].start, to: cleaned)
        for i in range { segments[i].shown = i == range.lowerBound ? revision.text : "" }
        publish(.revise(revision))
    }

    /// The revised text before segment `index`, its end only, trimmed.
    private func liveContext(before index: Int) -> String {
        let text = segments[..<index].map { $0.shown ?? $0.raw }.joined()
        return String(text.suffix(Self.liveContextCharacters)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The entry of a live-cleaned run: the revised text, with the engine's as `rawText` when they differ.
    private func applyLiveCleanup(to entry: inout DictationEntry) {
        let revised = segments.map { $0.shown ?? $0.raw }.joined().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !revised.isEmpty, revised != entry.text else { return }
        entry.rawText = entry.text
        entry.text = revised
    }

    private func cancelLiveCleanup() {
        cleaner?.cancel()
        cleaner = nil
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
