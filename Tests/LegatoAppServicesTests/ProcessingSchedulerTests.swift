import Foundation
import Synchronization
import Testing
@testable import LegatoAppServices

private final class Box<T: Sendable>: Sendable {
    private let value: Mutex<T>
    init(_ v: T) { value = Mutex(v) }
    var current: T { value.withLock { $0 } }
    func set(_ v: T) { value.withLock { $0 = v } }
    func update(_ f: (inout T) -> Void) { value.withLock { f(&$0) } }
}

private struct Rig {
    let now = Box<TimeInterval>(0)
    let sample = Box(IdleSample(cpuLoad: 0.9, secondsSinceInput: 1))
    let recording = Box(false)
    let ran = Box<[UUID]>([])
    let running = Box(0)
    let maxRunning = Box(0)
    let priorities = Box<[TaskPriority]>([])
    let result = Box(true)
    let sampleCount = Box(0)

    func scheduler(immediate: Bool = false, pollInterval: Duration? = nil) -> ProcessingScheduler {
        let sampleCount = self.sampleCount
        let now = self.now, sample = self.sample, recording = self.recording, ran = self.ran
        let running = self.running, maxRunning = self.maxRunning, priorities = self.priorities, result = self.result
        return ProcessingScheduler(
            clock: { now.current }, sample: { sampleCount.update { $0 += 1 }; return sample.current }, isRecording: { recording.current }, immediate: immediate,
            pollInterval: pollInterval,
            work: { id in
                running.update { $0 += 1 }
                let now = running.current
                maxRunning.update { $0 = max($0, now) }
                priorities.update { $0.append(Task.currentPriority) }
                await Task.yield()
                ran.update { $0.append(id) }
                running.update { $0 -= 1 }
                return result.current
            })
    }
}

private func idle(_ p: inout IdlePredicate, _ sample: IdleSample, isRecording: Bool, now: TimeInterval) -> Bool {
    p.update(sample, isRecording: isRecording, now: now)
}

@Suite struct IdlePredicateTests {
    @Test func nothingIsIdleWhileRecording() {
        var p = IdlePredicate()
        let quiet = IdleSample(cpuLoad: 0, secondsSinceInput: 1_000)
        #expect(!idle(&p, quiet, isRecording: true, now: 0))
        #expect(!idle(&p, quiet, isRecording: true, now: 100))
    }

    @Test func lowLoadMustHoldForThirtySeconds() {
        var p = IdlePredicate()
        let low = IdleSample(cpuLoad: 0.1, secondsSinceInput: 1)
        #expect(!idle(&p, low, isRecording: false, now: 0))
        #expect(!idle(&p, low, isRecording: false, now: 29))
        #expect(idle(&p, low, isRecording: false, now: 30))
    }

    @Test func aLoadSpikeRestartsTheWindow() {
        var p = IdlePredicate()
        let low = IdleSample(cpuLoad: 0.1, secondsSinceInput: 1)
        let high = IdleSample(cpuLoad: 0.5, secondsSinceInput: 1)
        _ = p.update(low, isRecording: false, now: 0)
        _ = p.update(high, isRecording: false, now: 20)
        _ = p.update(low, isRecording: false, now: 25)
        #expect(!idle(&p, low, isRecording: false, now: 54))
        #expect(idle(&p, low, isRecording: false, now: 55))
    }

    @Test func loadAtTheThresholdIsNotLow() {
        var p = IdlePredicate()
        let edge = IdleSample(cpuLoad: 0.30, secondsSinceInput: 1)
        _ = p.update(edge, isRecording: false, now: 0)
        #expect(!idle(&p, edge, isRecording: false, now: 100))
    }

    @Test func sixtySecondsWithoutInputIsIdleWhateverTheLoad() {
        var p = IdlePredicate()
        #expect(!idle(&p, IdleSample(cpuLoad: 0.95, secondsSinceInput: 59), isRecording: false, now: 0))
        #expect(idle(&p, IdleSample(cpuLoad: 0.95, secondsSinceInput: 60), isRecording: false, now: 1))
    }

    @Test func recordingEndsAnEarlierIdleAndRestartsTheLoadWindow() {
        var p = IdlePredicate()
        let low = IdleSample(cpuLoad: 0.1, secondsSinceInput: 1)
        _ = p.update(low, isRecording: false, now: 0)
        #expect(idle(&p, low, isRecording: false, now: 30))
        #expect(!idle(&p, low, isRecording: true, now: 31))
        #expect(!idle(&p, low, isRecording: false, now: 32), "the quiet window starts again")
        #expect(idle(&p, low, isRecording: false, now: 62))
    }
}

@Suite struct ProcessingSchedulerTests {
    @Test func nothingRunsUntilTheMachineIsIdle() async {
        let rig = Rig()
        let scheduler = rig.scheduler()
        let id = UUID()
        await scheduler.enqueue(id)
        await scheduler.tick()
        #expect(rig.ran.current.isEmpty)
        #expect(await scheduler.queued == [id])

        rig.sample.set(IdleSample(cpuLoad: 0.9, secondsSinceInput: 61))
        await scheduler.tick()
        #expect(rig.ran.current == [id])
        #expect(await scheduler.queued.isEmpty)
    }

    @Test func nothingRunsWhileRecordingEvenIfIdleAndProcessNowWasPressed() async {
        let rig = Rig()
        let scheduler = rig.scheduler()
        let id = UUID()
        rig.recording.set(true)
        rig.sample.set(IdleSample(cpuLoad: 0, secondsSinceInput: 1_000))
        await scheduler.enqueue(id)
        await scheduler.processNow(id)
        await scheduler.tick()
        #expect(rig.ran.current.isEmpty)

        rig.recording.set(false)
        await scheduler.tick()
        #expect(rig.ran.current == [id])
    }

    @Test func processNowBypassesTheWaitForThatMeetingOnly() async {
        let rig = Rig()
        let scheduler = rig.scheduler()
        let first = UUID(), second = UUID()
        await scheduler.enqueue(first)
        await scheduler.enqueue(second)
        await scheduler.processNow(second)
        await scheduler.tick()
        #expect(rig.ran.current == [second])
        #expect(await scheduler.queued == [first])
    }

    @Test func processNowOnAMeetingNotQueuedYetQueuesAndRunsIt() async {
        let rig = Rig()
        let scheduler = rig.scheduler()
        let id = UUID()
        await scheduler.processNow(id)
        await scheduler.tick()
        #expect(rig.ran.current == [id])
    }

    @Test func theDebugFlagRunsWithoutWaiting() async {
        let rig = Rig()
        let scheduler = rig.scheduler(immediate: true)
        let id = UUID()
        await scheduler.enqueue(id)
        await scheduler.tick()
        #expect(rig.ran.current == [id])
    }

    @Test func jobsRunOneAtATimeInOrder() async {
        let rig = Rig()
        rig.sample.set(.idle)
        let scheduler = rig.scheduler()
        let ids = (0..<3).map { _ in UUID() }
        for id in ids { await scheduler.enqueue(id) }
        async let a: Void = scheduler.tick()
        async let b: Void = scheduler.tick()
        _ = await (a, b)
        #expect(rig.ran.current == ids)
        #expect(rig.maxRunning.current == 1)
    }

    @Test func aMeetingQueuedTwiceRunsOnce() async {
        let rig = Rig()
        rig.sample.set(.idle)
        let scheduler = rig.scheduler()
        let id = UUID()
        await scheduler.enqueue(id)
        await scheduler.enqueue(id)
        await scheduler.tick()
        #expect(rig.ran.current == [id])
    }

    @Test func heavyWorkRunsAtBackgroundPriority() async {
        let rig = Rig()
        rig.sample.set(.idle)
        let scheduler = rig.scheduler()
        await scheduler.enqueue(UUID())
        await scheduler.tick()
        #expect(rig.priorities.current == [.background])
    }

    @Test func aJobThatDidNotFinishStaysQueuedAndStopsTheRound() async {
        let rig = Rig()
        rig.sample.set(.idle)
        rig.result.set(false)
        let scheduler = rig.scheduler()
        let first = UUID(), second = UUID()
        await scheduler.enqueue(first)
        await scheduler.enqueue(second)
        await scheduler.tick()
        #expect(rig.ran.current == [first], "the round stops instead of retrying in a loop")
        #expect(await scheduler.queued == [first, second])

        rig.result.set(true)
        await scheduler.tick()
        #expect(rig.ran.current == [first, first, second])
        #expect(await scheduler.queued.isEmpty)
    }

    @Test func processNowStartsAtOnceEvenWhileThePollerSleeps() async throws {
        let rig = Rig()
        // A poller that looks only every hour: Process now must not wait for its next look.
        let scheduler = rig.scheduler(pollInterval: .seconds(3600))
        let id = UUID()
        await scheduler.enqueue(id)  // starts the poller; the machine is busy, so nothing runs
        let sampled = ContinuousClock.now + .seconds(30)
        while rig.sampleCount.current == 0, ContinuousClock.now < sampled { await Task.yield() }
        #expect(rig.sampleCount.current > 0)
        _ = await scheduler.queued // the poller's first look returned and entered its sleep
        #expect(rig.ran.current.isEmpty)

        await scheduler.processNow(id)
        // A hang guard, not a speed bound.
        let deadline = ContinuousClock.now + .seconds(30)
        while rig.ran.current.isEmpty, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(rig.ran.current == [id], "it ran without waiting for the poll")
    }
}
