import Foundation
import Testing
@testable import LegatoAppServices

@MainActor private final class AdmissionGate {
    let entered = AdmissionSignal()
    var entries = 0
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async {
        entries += 1
        entered.signal()
        await withCheckedContinuation { continuation = $0 }
    }
    func release() { continuation?.resume(); continuation = nil }
}
// Latched events avoid polling; cancellation lets the suite watchdog unwind.
@MainActor private final class AdmissionSignal {
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

@Suite(.timeLimit(.minutes(1)))
@MainActor struct ModelAdmissionTests {
    @Test func coldEngineResolutionPrecedesReadinessAdmission() async {
        let admission = ModelAdmission()
        var resolving = true
        var arms = 0
        do {
            try await admission.admit(isIdle: { true }, canStart: { !resolving }, resolve: {
                resolving = false
            }, prepare: {}) { arms += 1 }
        } catch { Issue.record("The first keyboard tap must join resolution: \(error)") }
        #expect(arms == 1)
        #expect(!resolving)
    }

    @Test func coldFirstArmWaitsForPublishedResolutionButNotSubsequentModelWarmup() async throws {
        let admission = ModelAdmission(), resolutionGate = AdmissionGate(), nativeWarmup = AdmissionGate()
        var resolving = true; var arms = 0
        // As in AppController.init, publish identity resolution synchronously before scheduling the URL.
        let resolution = Task { await resolutionGate.wait(); resolving = false }
        let launch = Task { await resolution.value; await nativeWarmup.wait() }
        let arm = Task {
            try await admission.admit(isIdle: { true }, canStart: { !resolving }, resolve: {
                try await ModelAdmission.waitForResolution(resolution)
            }, prepare: {}) { arms += 1 }
        }
        await resolutionGate.entered.wait()
        #expect(arms == 0)
        resolutionGate.release()
        try await arm.value
        await nativeWarmup.entered.wait()
        #expect(arms == 1)
        #expect(!admission.isPreparing)
        nativeWarmup.release(); await launch.value
    }

    @Test func cancelledHopResolutionReturnsWithoutLateCaptureAndDoesNotCancelSharedResolution() async {
        let admission = ModelAdmission(), gate = AdmissionGate(), joining = AdmissionSignal()
        var arms = 0; var cancelled = false; var resolved = false
        let resolution = Task { await gate.wait(); resolved = true }
        let arm = Task {
            do {
                try await admission.admit(isIdle: { true }, resolve: {
                    joining.signal()
                    try await ModelAdmission.waitForResolution(resolution)
                }, prepare: {}) { arms += 1 }
            } catch is CancellationError { cancelled = true }
            catch { Issue.record("Unexpected hop failure: \(error)") }
        }
        await gate.entered.wait(); await joining.wait()
        admission.cancel()
        await arm.value
        #expect(cancelled)
        #expect(!admission.isPreparing)
        #expect(!resolved)
        #expect(arms == 0)
        gate.release(); await resolution.value
        #expect(resolved)
        #expect(arms == 0)
    }
    @Test func stopBypassesBlockedPreparationAndPreventsLateStart() async throws {
        let admission = ModelAdmission(); let gate = AdmissionGate()
        var starts = 0; var stops = 0
        let start = Task {
            try await admission.admit(isIdle: { true }, prepare: { await gate.wait() }) { starts += 1 }
        }
        await gate.entered.wait()
        #expect(admission.isPreparing)
        await admission.stop { stops += 1 }
        #expect(stops == 1)
        gate.release()
        _ = await start.result
        #expect(starts == 0)
    }
    @Test func cancellingWarmupReturnsAdmissionBeforeNativePreparationCompletesAndAllowsRetry() async {
        let admission = ModelAdmission(); let owner = SelectedModelWarmup(); let gate = AdmissionGate()
        let selected = [SelectedModelWarmup.Resource(key: "speech", prewarm: { await gate.wait() }, release: {})]
        let firstFinished = AdmissionSignal()
        var firstCancelled = false; var firstStarts = 0
        let first = Task {
            do {
                try await admission.admit(isIdle: { true }, prepare: {
                    try await owner.prepare(selected, inBackground: false)
                }) { firstStarts += 1 }
            } catch is CancellationError { firstCancelled = true }
            catch { Issue.record("Wrong first admission failure: \(error)") }
            firstFinished.signal()
        }
        await gate.entered.wait()
        admission.cancel()
        await firstFinished.wait()
        #expect(firstCancelled)
        #expect(!admission.isPreparing)
        #expect(firstStarts == 0)
        #expect(gate.entries == 1)
        let secondProgressed = AdmissionSignal()
        var secondPreparing = false; var secondStarts = 0
        let second = Task {
            do {
                try await admission.admit(isIdle: { true }, prepare: {
                    secondPreparing = true
                    secondProgressed.signal()
                    try await owner.prepare(selected, inBackground: true)
                }) { secondStarts += 1 }
            } catch { Issue.record("Retry admission failed: \(error)") }
            secondProgressed.signal()
        }
        await secondProgressed.wait()
        #expect(secondPreparing)
        #expect(admission.isPreparing)
        #expect(secondStarts == 0)
        gate.release()
        await first.value; await second.value
        #expect(firstStarts == 0)
        #expect(secondStarts == 1)
        #expect(gate.entries == 1)
        #expect(!admission.isPreparing)
        #expect(await owner.isReady(for: ["speech"]))
    }
    @Test func meetingOwnershipIsRecheckedAfterPreparation() async {
        let admission = ModelAdmission(); let gate = AdmissionGate()
        var meeting = false; var starts = 0
        let start = Task {
            try await admission.admit(isIdle: { true }, canStart: { !meeting }, prepare: { await gate.wait() }) { starts += 1 }
        }
        await gate.entered.wait()
        meeting = true; gate.release()
        _ = await start.result
        #expect(starts == 0)
    }
    @Test func concurrentStartIsRejectedWithoutStartingAnotherPreparation() async {
        let admission = ModelAdmission(); let gate = AdmissionGate()
        var extraPreparations = 0; var starts = 0
        let first = Task {
            try await admission.admit(isIdle: { true }, prepare: { await gate.wait() }) { starts += 1 }
        }
        await gate.entered.wait()
        do {
            try await admission.admit(isIdle: { true }, prepare: { extraPreparations += 1 }) { starts += 1 }
            Issue.record("Concurrent admission succeeded")
        } catch ModelAdmission.AdmissionError.busy {} catch { Issue.record("Wrong failure") }
        gate.release(); _ = await first.result
        #expect(extraPreparations == 0)
        #expect(starts == 1)
    }
    @Test func resetReservesAdmissionBeforeResourceRelease() async {
        let admission = ModelAdmission(); let gate = AdmissionGate(); var starts = 0
        let reset = Task { await admission.reset { await gate.wait() } }
        await gate.entered.wait()
        #expect(admission.isResetting)
        do {
            try await admission.admit(isIdle: { true }, prepare: {}) { starts += 1 }
            Issue.record("Start admitted during reset")
        } catch ModelAdmission.AdmissionError.busy {} catch { Issue.record("Wrong failure") }
        gate.release(); await reset.value
        #expect(starts == 0)
        #expect(!admission.isPreparing)
    }
}
