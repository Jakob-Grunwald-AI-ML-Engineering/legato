import Foundation
import Testing
@testable import LegatoAppServices

@MainActor private final class AdmissionGate {
    var entered = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async {
        entered = true
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
