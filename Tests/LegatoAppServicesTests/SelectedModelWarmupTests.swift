import Foundation
import LegatoCore
import Testing
@testable import LegatoAppServices

private actor WarmResource: ModelResourceLifecycle {
    var prepared = 0
    var released = 0
    var failure = false
    var gate: WarmGate?
    var activeRunText = "dictation continues"
    func block(on gate: WarmGate) { self.gate = gate }
    func failOnce() { failure = true }
    func prewarmResources() async throws {
        prepared += 1
        if let gate { await gate.wait() }
        try Task.checkCancellation()
        if failure { failure = false; throw WarmError.failed }
    }
    func releaseWarmResources() { released += 1 }
}
private enum WarmError: Error { case failed }
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
private func waitForWarm(_ condition: () async -> Bool) async {
    let deadline = ContinuousClock.now + .seconds(2)
    while ContinuousClock.now < deadline {
        if await condition() { return }
        await Task.yield()
    }
    Issue.record("Timed out waiting for model lifecycle operation")
}

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
        await waitForWarm { await cleanup.prepared == 1 }
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
        await waitForWarm { await resource.prepared == 1 }
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

    @Test func cancelledWaiterDoesNotEraseAnotherWaitersSuccessfulReadiness() async throws {
        for _ in 0..<20 {
            let owner = SelectedModelWarmup(); let resource = WarmResource(); let gate = WarmGate()
            await resource.block(on: gate)
            let selected = [SelectedModelWarmup.Resource(key: "speech", lifecycle: resource)]
            let cancelled = Task(priority: .background) { try await owner.prepare(selected, inBackground: false) }
            await waitForWarm { await resource.prepared == 1 }
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
        await waitForWarm { await old.prepared == 1 }
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
