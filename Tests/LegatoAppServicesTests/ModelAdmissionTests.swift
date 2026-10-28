import Foundation
import Testing
@testable import LegatoAppServices

@MainActor private final class AdmissionGate {
    var entered = false
    var entries = 0
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async {
        entered = true
        entries += 1
        await withCheckedContinuation { continuation = $0 }
    }
    func release() { continuation?.resume(); continuation = nil }
}
@MainActor private func waitForAdmission(_ condition: () -> Bool) async {
    let deadline = ContinuousClock.now + .seconds(2)
    while ContinuousClock.now < deadline {
        if condition() { return }
        await Task.yield()
    }
    Issue.record("Timed out waiting for model admission")
}

@MainActor struct ModelAdmissionTests {
    @Test func stopBypassesBlockedPreparationAndPreventsLateStart() async throws {
        let admission = ModelAdmission(); let gate = AdmissionGate()
        var starts = 0; var stops = 0
        let start = Task {
            try await admission.admit(isIdle: { true }, prepare: { await gate.wait() }) { starts += 1 }
        }
        await waitForAdmission { gate.entered }
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
        var firstFinished = false; var firstCancelled = false; var firstStarts = 0
        let first = Task {
            do {
                try await admission.admit(isIdle: { true }, prepare: {
                    try await owner.prepare(selected, inBackground: false)
                }) { firstStarts += 1 }
            } catch is CancellationError { firstCancelled = true }
            catch { Issue.record("Wrong first admission failure: \(error)") }
            firstFinished = true
        }
        await waitForAdmission { gate.entered }
        admission.cancel()
        await waitForAdmission { firstFinished }
        #expect(firstCancelled)
        #expect(!admission.isPreparing)
        #expect(firstStarts == 0)
        #expect(gate.entries == 1)
        var secondPreparing = false; var secondFinished = false; var secondStarts = 0
        let second = Task {
            do {
                try await admission.admit(isIdle: { true }, prepare: {
                    secondPreparing = true
                    try await owner.prepare(selected, inBackground: true)
                }) { secondStarts += 1 }
            } catch { Issue.record("Retry admission failed: \(error)") }
            secondFinished = true
        }
        await waitForAdmission { secondPreparing || secondFinished }
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
        await waitForAdmission { gate.entered }
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
        await waitForAdmission { gate.entered }
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
        await waitForAdmission { gate.entered }
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
