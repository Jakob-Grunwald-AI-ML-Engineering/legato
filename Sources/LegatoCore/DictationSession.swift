import Foundation

/// Orchestrates one dictation: an *audio lease* (policy active, mic armed) hosting *runs*
/// (one engine transcription each). With `linger > 0` the lease outlives a run so the next
/// run reuses the armed mic without re-activating the session.
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

    private let engine: any DictationEngine
    private let source: any AudioSource
    private let sessionControl: any AudioSessionControlling
    private let history: any HistoryStore
    private let policy: AudioPolicy
    private let linger: Duration
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

    public init(
        engine: any DictationEngine,
        source: any AudioSource,
        sessionControl: any AudioSessionControlling,
        history: any HistoryStore,
        policy: AudioPolicy = .default,
        linger: Duration = .zero,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.engine = engine
        self.source = source
        self.sessionControl = sessionControl
        self.history = history
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
    /// (or when stopped while still preparing).
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
        var entry: DictationEntry?
        var failure: (any Error)?
        do {
            await source.detach()
            try await engine.finish()
            await consumeTask?.value
            if let streamFailure { throw streamFailure }
            if let e = partialEntry() {
                try await history.append(e)
                entry = e
            }
        } catch {
            failure = error
        }

        // Every exit ends this run's consumer, so nothing of it can reach a later run.
        generation += 1
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
                for edit in assembler.apply(event) { editsContinuation.yield(edit) }
            }
        } catch {
            guard gen == generation else { return }
            lastError = error
            if runState == .listening {
                runState = .finishing // blocks stop() while aborting
                generation += 1
                consumeTask = nil
                clearVolatile()
                await source.detach()
                await teardownLease()
                runState = .idle
                onRunAborted?(error)
            } else {
                streamFailure = error // stop() is in flight; it reports the failure
            }
        }
    }

    /// Removes tentative text from the sink; a run never leaves volatile text behind.
    private func clearVolatile() {
        for edit in assembler.apply(TranscriptEvent(text: "", isFinal: false)) { editsContinuation.yield(edit) }
    }

    /// Ends the lease: stops the mic, then deactivates the session. No-op when idle.
    private func teardownLease() async {
        guard leaseState != .idle else { return }
        await source.stop()
        sessionControl.deactivate()
        leaseState = .idle
    }

    /// After a successful run: deactivate now, or after `linger` unless a new run starts.
    private func releaseLease() async {
        if linger == .zero {
            await teardownLease()
            return
        }
        let sleep = self.sleep, linger = self.linger
        lingerTask = Task {
            do { try await sleep(linger) } catch { return }
            guard !Task.isCancelled, runState == .idle else { return }
            await teardownLease()
        }
    }

    private func cancelLinger() async {
        guard let task = lingerTask else { return }
        task.cancel()
        await task.value // if expiry already began, let teardown finish
        lingerTask = nil
    }
}
