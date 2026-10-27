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

/// Runs the heavy after-meeting steps (post-pass, speakers, summary) one at a time, at background priority, once
/// the machine is idle.
///
/// Meetings are queued by id and run in order. Nothing runs while a meeting records. A meeting that
/// ``processNow(_:)`` names, or any meeting when `immediate` is set (the debug launch argument
/// `LegatoMeetingProcessImmediately`), skips the wait for idleness, but never runs during a recording.
///
/// The clock and the samplers are injected. With a `pollInterval` the scheduler looks again by itself while
/// meetings wait; without one the caller drives it with ``tick()``.
public actor ProcessingScheduler {
    private let clock: @Sendable () -> TimeInterval
    private let sample: @Sendable () -> IdleSample
    private let isRecording: @Sendable () -> Bool
    private let immediate: Bool
    private let pollInterval: Duration?
    private let work: @Sendable (UUID) async -> Bool

    private var queue: [UUID] = []
    private var forced: Set<UUID> = []
    private var predicate = IdlePredicate()
    private var running: Task<Void, Never>?
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

    /// The meetings waiting, in the order they will run.
    public var queued: [UUID] { queue }

    /// Queues a meeting (once) and, if the scheduler polls, starts looking for the moment to run it.
    public func enqueue(_ id: UUID) {
        if !queue.contains(id) { queue.append(id) }
        poll()
    }

    /// Runs this meeting as soon as nothing records and nothing else runs, without waiting for idleness.
    public func processNow(_ id: UUID) {
        if !queue.contains(id) { queue.append(id) }
        forced.insert(id)
        poll()
    }

    /// Cancels the running job (the app is about to be suspended). It stays queued.
    public func cancelRunning() {
        running?.cancel()
    }

    /// Looks once: runs every meeting that may run now, one after another. Returns when none may, or when the
    /// work of one was cut short.
    public func tick() async {
        guard running == nil else { return }
        while true {
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
            guard done else { return }
            queue.removeAll { $0 == id }
            forced.remove(id)
        }
    }

    private func poll() {
        guard let pollInterval, polling == nil else { return }
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
