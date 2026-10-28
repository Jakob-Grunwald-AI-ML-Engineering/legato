import Foundation
import LegatoCore
import Testing
@testable import LegatoAppServices

private actor WarmResource: ModelResourceLifecycle {
    var prepared = 0
    var released = 0
    var failure = false
    var gate: WarmGate?
    let preparationEntered = WarmSignal()
    var activeRunText = "dictation continues"
    func block(on gate: WarmGate) { self.gate = gate }
    func failOnce() { failure = true }
    func prewarmResources() async throws {
        prepared += 1
        await preparationEntered.signal()
        if let gate { await gate.wait() }
        try Task.checkCancellation()
        if failure { failure = false; throw WarmError.failed }
    }
    func releaseWarmResources() { released += 1 }
}
private enum WarmError: Error { case failed }
private actor WarmWaiterCompletion {
    var cancelled: Bool?
    let finished = WarmSignal()
    func finish(cancelled: Bool) async {
        self.cancelled = cancelled
        await finished.signal()
    }
}
// Latched events avoid scheduler-sensitive polling; cancellation lets the suite watchdog unwind.
private actor WarmSignal {
    private var signalled = false
    private var waiters: [AsyncStream<Void>.Continuation] = []
    func wait() async {
        if signalled { return }
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        waiters.append(continuation)
        var iterator = stream.makeAsyncIterator()
        _ = await iterator.next()
    }
    func signal() {
        signalled = true
        let waiting = waiters; waiters = []
        for waiter in waiting { waiter.yield(()); waiter.finish() }
    }
}
private actor WarmGate {
    private var open = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if open { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func release() {
        open = true
        let waiting = waiters; waiters = []
        for waiter in waiting { waiter.resume() }
    }
}
@Suite(.timeLimit(.minutes(1)))
struct SelectedModelWarmupTests {
    @Test func repeatedPreparationRetainsSelectedResourcesWithoutReinitializingActiveRun() async throws {
        let owner = SelectedModelWarmup(); let resource = WarmResource()
        let selected = [SelectedModelWarmup.Resource(key: "speech", lifecycle: resource)]
        try await owner.prepare(selected, inBackground: false)
        #expect(await owner.isReady(for: ["speech"]))
        try await owner.prepare(selected, inBackground: true)
        #expect(await resource.prepared == 1)
        #expect(await resource.released == 0)
        #expect(await resource.activeRunText == "dictation continues")
    }
    @Test func coldBackgroundRequestDoesNotLoadOrPublishReady() async {
        let owner = SelectedModelWarmup(); let resource = WarmResource()
        do {
            try await owner.prepare([.init(key: "speech", lifecycle: resource)], inBackground: true)
            Issue.record("Cold background request was admitted")
        } catch SelectedModelWarmup.PreparationError.needsForeground {} catch { Issue.record("Wrong failure: \(error)") }
        #expect(await resource.prepared == 0)
        #expect(!(await owner.isReady(for: ["speech"])))
    }
    @Test func readinessWaitsForEverySelectedResourceAndConcurrentCallersSharePreparation() async throws {
        let owner = SelectedModelWarmup(); let speech = WarmResource(); let cleanup = WarmResource()
        let gate = WarmGate(); await cleanup.block(on: gate)
        let resources = [SelectedModelWarmup.Resource(key: "speech", lifecycle: speech), .init(key: "cleanup", lifecycle: cleanup)]
        let first = Task { try await owner.prepare(resources, inBackground: false) }
        await cleanup.preparationEntered.wait()
        #expect(!(await owner.isReady(for: ["speech", "cleanup"])))
        let second = Task { try await owner.prepare(resources, inBackground: false) }
        await gate.release()
        try await first.value; try await second.value
        #expect(await speech.prepared == 1)
        #expect(await cleanup.prepared == 1)
        #expect(await owner.isReady(for: ["speech", "cleanup"]))
    }
    @Test func invalidationRevokesReadinessAndWaitsForPreparationBeforeRelease() async throws {
        let owner = SelectedModelWarmup(); let resource = WarmResource(); let gate = WarmGate()
        await resource.block(on: gate)
        let prepare = Task { try await owner.prepare([.init(key: "old", lifecycle: resource)], inBackground: false) }
        await resource.preparationEntered.wait()
        let invalidate = Task { await owner.invalidate() }
        await Task.yield()
        #expect(!(await owner.isReady(for: ["old"])))
        #expect(await resource.released == 0)
        await gate.release()
        _ = await prepare.result; await invalidate.value
        #expect(await resource.released == 1)
        #expect(!(await owner.isReady(for: ["old"])))
    }
    @Test func failedPreparationCanRetryAndDoesNotPublishPartialReadiness() async throws {
        let owner = SelectedModelWarmup(); let resource = WarmResource(); await resource.failOnce()
        let selected = [SelectedModelWarmup.Resource(key: "speech", lifecycle: resource)]
        do { try await owner.prepare(selected, inBackground: false); Issue.record("Failed warmup was admitted") }
        catch WarmError.failed {} catch { Issue.record("Wrong failure") }
        #expect(!(await owner.isReady(for: ["speech"])))
        try await owner.prepare(selected, inBackground: false)
        #expect(await owner.isReady(for: ["speech"]))
        #expect(await resource.prepared == 2)
    }
    @Test func switchingSelectionReleasesOldResourcesAndDoesNotReuseReadiness() async throws {
        let owner = SelectedModelWarmup(); let old = WarmResource(); let new = WarmResource()
        try await owner.prepare([.init(key: "old", lifecycle: old)], inBackground: false)
        try await owner.prepare([.init(key: "new", lifecycle: new)], inBackground: false)
        #expect(await old.released == 1)
        #expect(await new.prepared == 1)
        #expect(!(await owner.isReady(for: ["old"])))
        #expect(await owner.isReady(for: ["new"]))
    }

    @Test func cancelledWaiterReturnsBeforeSharedNativePreparationCompletes() async throws {
        let owner = SelectedModelWarmup(); let resource = WarmResource(); let gate = WarmGate()
        let completion = WarmWaiterCompletion()
        await resource.block(on: gate)
        let selected = [SelectedModelWarmup.Resource(key: "speech", lifecycle: resource)]
        let cancelled = Task {
            do {
                try await owner.prepare(selected, inBackground: false)
                await completion.finish(cancelled: false)
            } catch is CancellationError {
                await completion.finish(cancelled: true)
            } catch {
                Issue.record("Wrong failure: \(error)")
                await completion.finish(cancelled: false)
            }
        }
        await resource.preparationEntered.wait()
        cancelled.cancel()
        await completion.finished.wait()
        #expect(await completion.cancelled == true)
        #expect(await resource.prepared == 1)
        #expect(await resource.released == 0)
        #expect(!(await owner.isReady(for: ["speech"])))
        let joined = Task { try await owner.prepare(selected, inBackground: true) }
        await gate.release()
        await cancelled.value
        try await joined.value
        #expect(await owner.isReady(for: ["speech"]))
        #expect(await resource.prepared == 1)
        #expect(await resource.released == 0)
    }

    @Test func cancelledWaiterDoesNotEraseAnotherWaitersSuccessfulReadiness() async throws {
        for _ in 0..<20 {
            let owner = SelectedModelWarmup(); let resource = WarmResource(); let gate = WarmGate()
            await resource.block(on: gate)
            let selected = [SelectedModelWarmup.Resource(key: "speech", lifecycle: resource)]
            let cancelled = Task(priority: .background) { try await owner.prepare(selected, inBackground: false) }
            await resource.preparationEntered.wait()
            let waiting = Task(priority: .userInitiated) { try await owner.prepare(selected, inBackground: false) }
            cancelled.cancel()
            await gate.release()
            try await waiting.value
            _ = await cancelled.result
            #expect(await owner.isReady(for: ["speech"]))
            #expect(await resource.prepared == 1)
        }
    }

    @Test func selectionDuringPreparationCannotPublishOrReloadTheSupersededSelection() async throws {
        let owner = SelectedModelWarmup(); let old = WarmResource(); let new = WarmResource(); let gate = WarmGate()
        await old.block(on: gate)
        let first = Task { try await owner.prepare([.init(key: "old", lifecycle: old)], inBackground: false) }
        await old.preparationEntered.wait()
        let second = Task { try await owner.prepare([.init(key: "new", lifecycle: new)], inBackground: false) }
        await Task.yield()
        #expect(!(await owner.isReady(for: ["new"])))
        #expect(await old.released == 0)
        await gate.release()
        _ = await first.result
        try await second.value
        #expect(await old.released == 1)
        #expect(await new.prepared == 1)
        #expect(await owner.isReady(for: ["new"]))
        #expect(!(await owner.isReady(for: ["old"])))
    }
}
