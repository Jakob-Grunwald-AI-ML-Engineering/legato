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
    @Test func speechAndFoundationReadinessDoesNotWaitForBlockedMeetingModel() async throws {
        let owner = SelectedModelWarmup(); let speech = WarmResource(); let foundation = WarmResource(); let meeting = WarmResource(); let gate = WarmGate()
        await meeting.block(on: gate)
        await owner.setRequested([.init(key: "speech", lifecycle: speech), .init(key: "foundation", lifecycle: foundation)], for: .dictation, inBackground: false)
        await owner.setRequested([.init(key: "meeting", lifecycle: meeting)], for: .meetingSummary, inBackground: false)
        await meeting.preparationEntered.wait()
        try await owner.prepare(keys: ["speech", "foundation"], inBackground: false)
        #expect(await owner.isReady(for: ["speech", "foundation"]))
        #expect(await owner.isReady(for: ["meeting"]) == false)
        await gate.release()
        try await owner.prepare(keys: ["meeting"], inBackground: true)
        await owner.invalidate()
    }

    @Test func disabledCleanupCanAdmitSpeechWhileIndependentRefinePrepares() async throws {
        let owner = SelectedModelWarmup(); let speech = WarmResource(); let refine = WarmResource(); let gate = WarmGate()
        await refine.block(on: gate)
        await owner.setRequested([.init(key: "speech", lifecycle: speech)], for: .dictation, inBackground: false)
        await owner.setRequested([.init(key: "cleanup", lifecycle: refine)], for: .refine, inBackground: false)
        await refine.preparationEntered.wait()
        try await owner.prepare(keys: ["speech"], inBackground: false)
        #expect(await owner.isReady(for: ["speech"]))
        #expect(await owner.isReady(for: ["cleanup"]) == false)
        await gate.release()
        await owner.invalidate()
    }

    @Test func roleRemovalRetainsResourcesUntilTheLastOperationLeaseEnds() async throws {
        let owner = SelectedModelWarmup(); let resource = WarmResource()
        await owner.setRequested([.init(key: "cleanup", lifecycle: resource)], for: .meetingSummary, inBackground: false)
        let lease = try await owner.acquire(keys: ["cleanup"], inBackground: false)
        await owner.setRequested([], for: .meetingSummary, inBackground: false)
        #expect(await resource.released == 0)
        #expect(await owner.isReady(for: ["cleanup"]))
        await lease.release()
        #expect(await resource.released == 1)
        #expect(await owner.isReady(for: ["cleanup"]) == false)
        await lease.release()
        #expect(await resource.released == 1)
    }

    @Test func cancelledMeetingWaiterDoesNotCancelSharedDictationLoad() async throws {
        let owner = SelectedModelWarmup(); let resource = WarmResource(); let gate = WarmGate(); let completion = WarmWaiterCompletion()
        await resource.block(on: gate)
        let resources = [SelectedModelWarmup.Resource(key: "shared", lifecycle: resource)]
        await owner.setRequested(resources, for: .dictation, inBackground: false)
        await owner.setRequested(resources, for: .meetingSummary, inBackground: false)
        await resource.preparationEntered.wait()
        let waiter = Task {
            do { let lease = try await owner.acquire(keys: ["shared"], inBackground: false); await lease.release(); await completion.finish(cancelled: false) }
            catch is CancellationError { await completion.finish(cancelled: true) }
            catch { Issue.record("Wrong error: \(error)"); await completion.finish(cancelled: false) }
        }
        waiter.cancel()
        await completion.finished.wait()
        #expect(await completion.cancelled == true)
        #expect(await resource.released == 0)
        await owner.setRequested([], for: .meetingSummary, inBackground: false)
        await gate.release()
        try await owner.prepare(keys: ["shared"], inBackground: true)
        #expect(await resource.prepared == 1)
        #expect(await owner.isReady(for: ["shared"]))
        await waiter.value
        await owner.invalidate()
    }

    @Test func cancelledLastMeetingWaiterReturnsBeforeNativeRetirementSettles() async throws {
        let owner = SelectedModelWarmup(); let resource = WarmResource(); let gate = WarmGate()
        let completion = WarmWaiterCompletion()
        await resource.block(on: gate)
        let selected = [SelectedModelWarmup.Resource(key: "meeting", lifecycle: resource)]
        // Only acquire starts preparation, so this event also proves its lease is already pinned.
        await owner.setRequested(selected, for: .meetingSummary, inBackground: true)
        let waiter = Task {
            do {
                let lease = try await owner.acquire(keys: ["meeting"], inBackground: false)
                await lease.release()
                await completion.finish(cancelled: false)
            } catch is CancellationError {
                await completion.finish(cancelled: true)
            } catch {
                Issue.record("Wrong error: \(error)")
                await completion.finish(cancelled: false)
            }
        }
        await resource.preparationEntered.wait()
        await owner.setRequested([], for: .meetingSummary, inBackground: false)
        waiter.cancel()
        await completion.finished.wait()
        #expect(await completion.cancelled == true, "Cancellation returns while native preparation is still blocked")
        #expect(await resource.released == 0, "Native resources cannot be released before preparation settles")
        #expect(await owner.isReady(for: ["meeting"]) == false)
        await gate.release()
        await waiter.value
        await owner.invalidate() // joins retirement even though the cancelled waiter already returned
        #expect(await resource.released == 1)
        #expect(await resource.prepared == 1)
        #expect(await owner.isReady(for: ["meeting"]) == false, "Retired preparation cannot publish late readiness")
        try await owner.prepare(selected, inBackground: false)
        #expect(await resource.prepared == 2, "A subsequent request prepares a fresh identity after retirement")
        #expect(await owner.isReady(for: ["meeting"]))
        await owner.invalidate()
    }

    @Test func failedMeetingPreparationNeverPublishesReadyOrBlocksSpeech() async throws {
        let owner = SelectedModelWarmup(); let speech = WarmResource(); let meeting = WarmResource()
        await meeting.failOnce()
        await owner.setRequested([.init(key: "speech", lifecycle: speech)], for: .dictation, inBackground: false)
        await owner.setRequested([.init(key: "meeting", lifecycle: meeting)], for: .meetingSummary, inBackground: true)
        await #expect(throws: WarmError.failed) { try await owner.prepare(keys: ["meeting"], inBackground: false) }
        try await owner.prepare(keys: ["speech"], inBackground: false)
        #expect(await owner.isReady(for: ["speech"]))
        #expect(await owner.isReady(for: ["meeting"]) == false)
        await owner.invalidate()
    }

    @Test func pressureReleasesBothRequestedRolesAndRevokesTheirLeases() async throws {
        let owner = SelectedModelWarmup(); let speech = WarmResource(); let meeting = WarmResource()
        await owner.setRequested([.init(key: "speech", lifecycle: speech)], for: .dictation, inBackground: false)
        await owner.setRequested([.init(key: "meeting", lifecycle: meeting)], for: .meetingSummary, inBackground: false)
        let first = try await owner.acquire(keys: ["speech"], inBackground: false)
        let second = try await owner.acquire(keys: ["meeting"], inBackground: false)
        await owner.invalidate()
        #expect(await owner.isReady(for: ["speech"]) == false)
        #expect(await owner.isReady(for: ["meeting"]) == false)
        #expect(await speech.released == 1)
        #expect(await meeting.released == 1)
        await first.release(); await second.release()
        #expect(await speech.released == 1)
        #expect(await meeting.released == 1)
    }

    @Test func readinessOfRequiredSubsetIsIndependentOfOtherRetainedResources() async throws {
        let owner = SelectedModelWarmup(); let speech = WarmResource(); let cleanup = WarmResource()
        try await owner.prepare([.init(key: "speech", lifecycle: speech), .init(key: "cleanup", lifecycle: cleanup)], inBackground: false)
        #expect(await owner.isReady(for: ["speech"]))
        #expect(await owner.isReady(for: ["cleanup"]))
    }

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
