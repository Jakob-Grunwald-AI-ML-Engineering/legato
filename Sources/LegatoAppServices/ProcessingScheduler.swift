import Foundation

/// What the machine is doing, sampled for ``IdlePredicate``.
public struct IdleSample: Sendable, Equatable {
    /// System-wide CPU load, 0 to 1.
    public var cpuLoad: Double
    /// Seconds since the user last touched the keyboard, mouse or screen.
    public var secondsSinceInput: TimeInterval

    public init(cpuLoad: Double, secondsSinceInput: TimeInterval) {
        self.cpuLoad = cpuLoad
        self.secondsSinceInput = secondsSinceInput
    }

    /// The phone while the app is in the foreground and nothing records: always a good time.
    public static let idle = IdleSample(cpuLoad: 0, secondsSinceInput: .infinity)
}

/// Decides when the machine is idle. Pure: the caller feeds it samples and the time.
public struct IdlePredicate: Sendable {
    public static let loadThreshold = 0.30
    /// How long the load must stay under the threshold.
    public static let loadWindow: TimeInterval = 30
    /// How long without input counts as idle whatever the load.
    public static let inputIdle: TimeInterval = 60

    private var lowSince: TimeInterval?

    public init() {}

    /// Records `sample` taken at `now` and answers whether the machine is idle: nothing records, and either the
    /// load has been under ``loadThreshold`` for ``loadWindow`` seconds or ``inputIdle`` seconds passed without input.
    public mutating func update(_ sample: IdleSample, isRecording: Bool, now: TimeInterval) -> Bool {
        if sample.cpuLoad < Self.loadThreshold {
            if lowSince == nil { lowSince = now }
        } else {
            lowSince = nil
        }
        guard !isRecording else {
            lowSince = nil  // the quiet window starts again after the meeting
            return false
        }
        let quiet = lowSince.map { now - $0 >= Self.loadWindow } ?? false
        return quiet || sample.secondsSinceInput >= Self.inputIdle
    }
}

/// The one lane every heavy job of the meetings runs in: the after-meeting steps (post-pass, speakers, summary)
/// that wait for an idle machine, and the actions the user asks for (Improve transcript, Summarize, Regenerate,
/// Claude). One job runs at a time, so two models never load next to each other and a job never sees another
/// one's steps.
///
/// - **Deferred jobs** are meetings queued by id; they run in order, at background priority, once the machine is
///   idle. A meeting that ``processNow(_:)`` names, or any meeting when `immediate` is set (the debug launch
///   argument `LegatoMeetingProcessImmediately`), skips the wait for idleness.
/// - **Manual jobs** (``perform(for:_:)``) go ahead of the deferred ones: they skip the wait for idleness and
///   run as soon as the job that runs now has ended. The caller awaits the job's result.
/// - **Recordings come first.** Nothing starts while a meeting records, and a manual job is refused then.
///   ``cancelRunning()`` (a recording starts, or the app is about to be suspended) cuts the running job short. A
///   deferred job stays queued. A manual job cut short by a recording stays queued too and runs again once the
///   recording has ended (``recordingEnded()``), and its caller gets that run's result; cut short for any other
///   reason, it ends with `CancellationError`. Cancelling the caller's task cancels its manual job.
///
/// The clock and the samplers are injected. With a `pollInterval` the scheduler looks again by itself while
/// meetings wait; without one the caller drives the deferred jobs with ``tick()``.
public actor ProcessingScheduler {
    private let clock: @Sendable () -> TimeInterval
    private let sample: @Sendable () -> IdleSample
    private let isRecording: @Sendable () -> Bool
    private let immediate: Bool
    private let pollInterval: Duration?
    private let work: @Sendable (UUID) async -> Bool

    private struct ManualJob {
        let id: UUID
        let meeting: UUID
        let work: @Sendable () async throws -> any Sendable
        let done: CheckedContinuation<any Sendable, any Error>
        /// Its caller was cancelled: it ends with what the run gives, never runs again.
        var abandoned = false
    }

    private var queue: [UUID] = []
    private var forced: Set<UUID> = []
    /// Manual jobs, in the order they were asked for; the first one runs when the lane is free.
    private var manual: [ManualJob] = []
    /// Manual jobs admitted to the lane but still waiting behind its running job.
    var waitingManualCount: Int { manual.filter { $0.id != runningManual }.count }
    private var predicate = IdlePredicate()
    /// The job in the lane, and the id of the manual job when it is one.
    private var running: Task<Void, Never>?
    private var runningManual: UUID?
    private var polling: Task<Void, Never>?

    /// Whether the debug launch argument asks for processing without the wait. Always false in release builds.
    public static var launchImmediate: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains { $0 == "LegatoMeetingProcessImmediately" || $0 == "-LegatoMeetingProcessImmediately" }
        #else
        false
        #endif
    }

    /// - Parameters:
    ///   - sample: the machine's load and input idleness now.
    ///   - isRecording: a meeting is recording.
    ///   - pollInterval: how often to look while meetings wait; nil never looks by itself.
    ///   - work: runs the heavy steps of one meeting; true when it is done, false to keep it queued (it was
    ///     cut short). It runs at `.background` priority.
    public init(
        clock: @escaping @Sendable () -> TimeInterval, sample: @escaping @Sendable () -> IdleSample,
        isRecording: @escaping @Sendable () -> Bool, immediate: Bool = false, pollInterval: Duration? = .seconds(5),
        work: @escaping @Sendable (UUID) async -> Bool
    ) {
        self.clock = clock
        self.sample = sample
        self.isRecording = isRecording
        self.immediate = immediate
        self.pollInterval = pollInterval
        self.work = work
    }

    /// The meetings waiting for their deferred job, in the order they will run.
    public var queued: [UUID] { queue }

    /// Queues a meeting (once) and, if the scheduler polls, starts looking for the moment to run it.
    public func enqueue(_ id: UUID) {
        if !queue.contains(id) { queue.append(id) }
        poll()
    }

    /// Takes a meeting out of the queue (a manual job did its deferred work).
    public func dequeue(_ id: UUID) {
        queue.removeAll { $0 == id }
        forced.remove(id)
    }

    /// Runs this meeting as soon as nothing records and nothing else runs, without waiting for idleness.
    public func processNow(_ id: UUID) {
        if !queue.contains(id) { queue.append(id) }
        forced.insert(id)
        poll(lookNow: true)
    }

    /// Cancels the running job, manual or deferred (the app is about to be suspended, or a meeting starts
    /// recording). See the type's notes for what becomes of it.
    public func cancelRunning() {
        running?.cancel()
    }

    /// The recording that held the lane has ended: a manual job waiting for it runs now.
    public func recordingEnded() {
        pump()
    }

    /// A manual job on `meeting`: runs `work` in the lane, ahead of the deferred jobs and without waiting for
    /// idleness, and returns its result.
    /// - Throws: ``MeetingServicesError/recording`` while a meeting records; what `work` throws;
    ///   `CancellationError` when cut short (see the type's notes).
    public func perform<T: Sendable>(for meeting: UUID, _ work: @escaping @Sendable () async throws -> T) async throws -> T {
        guard !isRecording() else { throw MeetingServicesError.recording }
        let id = UUID()
        let result = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (done: CheckedContinuation<any Sendable, any Error>) in
                manual.append(ManualJob(id: id, meeting: meeting, work: { try await work() }, done: done))
                pump()
            }
        } onCancel: {
            Task { await self.abandon(id) }
        }
        guard let value = result as? T else { throw CancellationError() }
        return value
    }

    /// Looks once: runs every meeting that may run now, one after another. Returns when none may, when the
    /// work of one was cut short, or when a manual job takes the lane.
    public func tick() async {
        guard running == nil else { return }
        while true {
            guard manual.isEmpty else { return pump() }
            let recording = isRecording()
            let idle = predicate.update(sample(), isRecording: recording, now: clock())
            guard !recording,
                let id = idle || immediate ? queue.first : queue.first(where: forced.contains)
            else { return }
            let work = self.work
            // Waiting on the task itself would raise its priority to ours; a continuation does not.
            let done = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                running = Task(priority: .background) { continuation.resume(returning: await work(id)) }
            }
            running = nil
            guard done else { return pump() }
            queue.removeAll { $0 == id }
            forced.remove(id)
        }
    }

    // MARK: Manual jobs

    /// Starts the first manual job if the lane is free and nothing records.
    private func pump() {
        guard running == nil, !isRecording(), let job = manual.first else { return }
        let (id, work) = (job.id, job.work)
        runningManual = id
        running = Task(priority: .userInitiated) { [self] in
            let result: Result<any Sendable, any Error>
            do { result = .success(try await work()) } catch { result = .failure(error) }
            manualEnded(id, result)
        }
    }

    private func manualEnded(_ id: UUID, _ result: Result<any Sendable, any Error>) {
        running = nil
        runningManual = nil
        if let index = manual.firstIndex(where: { $0.id == id }) {
            let job = manual[index]
            let cutByRecording = if case .failure(let error) = result { error is CancellationError && !job.abandoned && isRecording() } else { false }
            if !cutByRecording {  // else it stays first in line and runs again after the recording
                manual.remove(at: index)
                job.done.resume(with: result)
            }
        }
        pump()
        if running == nil, !queue.isEmpty { poll(lookNow: true) }
    }

    /// The caller of a manual job was cancelled: a waiting job ends now, a running one is cancelled.
    private func abandon(_ id: UUID) {
        guard let index = manual.firstIndex(where: { $0.id == id }) else { return }
        if runningManual == id {
            manual[index].abandoned = true
            running?.cancel()
        } else {
            manual.remove(at: index).done.resume(throwing: CancellationError())
        }
    }

    /// Starts the poller if it is not looking yet; `lookNow` also makes it look once now when it is asleep,
    /// so "Process now" does not wait for the next poll. (`tick` is safe to run twice: it returns while a job runs.)
    private func poll(lookNow: Bool = false) {
        guard let pollInterval else { return }
        guard polling == nil else {
            if lookNow { Task { await tick() } }
            return
        }
        polling = Task { [self] in
            while !Task.isCancelled {
                await tick()
                guard !queue.isEmpty else { break }
                try? await Task.sleep(for: pollInterval)
            }
            polling = nil
            predicate = IdlePredicate()
        }
    }
}
