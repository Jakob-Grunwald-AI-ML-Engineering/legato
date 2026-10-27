import Foundation
import Testing
import LegatoCore
import LegatoAppServices
@testable import ANECleanupCore

actor Suspension {
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private var released = false
    private var safety: Task<Void, Never>?
    func wait() async {
        if released { return }
        await withCheckedContinuation { continuation in
            continuations.append(continuation)
            if safety == nil {
                safety = Task {
                    do { try await Task.sleep(for: .seconds(3)) } catch { return }
                    guard !released else { return }
                    Issue.record("Test safety deadline released a blocked fake operation")
                    release()
                }
            }
        }
    }
    func release() {
        released = true; safety?.cancel()
        let waiting = continuations; continuations = []
        for continuation in waiting { continuation.resume() }
    }
}
@MainActor private func waitFor(_ label: String, _ condition: () async -> Bool) async {
    let deadline = ContinuousClock.now + .seconds(2)
    while ContinuousClock.now < deadline {
        if await condition() { return }
        await Task.yield()
    }
    Issue.record("Timed out waiting for \(label)")
}
actor FakeRuntime: ParityRuntime {
    nonisolated let id = "test-ane"
    nonisolated let maxPromptCharacters: Int? = nil
    var loaded = false
    var loadedChecks = 0
    var loadedGate: Suspension?
    var events: [String] = []
    var loadGate: Suspension?
    var responseGate: Suspension?
    var reply = "Hello world."
    var seenExamples: [LLMExample] = []
    var seenInstructions = ""
    var seenPrompt = ""
    var failed = false
    var active = false
    var availability: LLMAvailability { .available }
    func setLoadGate(_ gate: Suspension) { loadGate = gate }
    func setResponseGate(_ gate: Suspension) { responseGate = gate }
    func setReply(_ value: String) { reply = value }
    func prepare() async throws {
        events.append("prepare")
        if let loadGate { await loadGate.wait() }
        try Task.checkCancellation()
        loaded = true
    }
    func setLoadedGate(_ gate: Suspension) { loadedGate = gate }
    func isLoaded() async -> Bool {
        loadedChecks += 1
        let snapshot = loaded
        if let loadedGate { await loadedGate.wait() }
        return snapshot
    }
    func cancel() { events.append("cancel") }
    func waitUntilSettled() async {
        while active { await Task.yield() }
        events.append("settled")
    }
    func unload() { events.append(active ? "UNSAFE unload" : "unload"); loaded = false }
    func respond(instructions: String, prompt: String) async throws -> String {
        try await respond(instructions: instructions, examples: [], prompt: prompt)
    }
    func respond(instructions: String, examples: [LLMExample], prompt: String) async throws -> String {
        seenExamples = examples; seenInstructions = instructions; seenPrompt = prompt
        active = true; events.append("respond")
        defer { active = false; events.append("response settled") }
        if let responseGate { await responseGate.wait() }
        return reply
    }
}
@MainActor struct ParityLifecycleTests {
    @Test func bootstrapEnablesANEOnceAndPreservesLaterChoices() throws {
        let name = "legato-parity-test-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        ParityBootstrap.apply(defaults: defaults)
        let settings = CleanupSettingsStore(defaults: defaults)
        #expect(settings.enabled)
        #expect(settings.delivery == .replace)
        #expect(settings.style == .verbatim)
        #expect(settings.timeoutSeconds == 4)
        settings.enabled = false; settings.delivery = .hold; settings.timeoutSeconds = 7
        ParityBootstrap.apply(defaults: defaults)
        #expect(!settings.enabled)
        #expect(settings.delivery == .hold)
        #expect(settings.timeoutSeconds == 7)
    }
    @Test func coldBackgroundPreparationRefusesWithoutLoading() async {
        let runtime = FakeRuntime(); let owner = ParityModelOwner(runtime: runtime)
        do { try await owner.prepare(inBackground: true); Issue.record("cold background model admitted") }
        catch ParityPreparationError.needsForeground {} catch { Issue.record("wrong error \(error)") }
        #expect(await runtime.events.isEmpty)
    }
    @Test func modelIsPreparedBeforeMicrophoneReadyAndSurvivesMicExpiry() async throws {
        let runtime = FakeRuntime(); let owner = ParityModelOwner(runtime: runtime); let admission = ParityAdmission()
        var micReady = false
        try await admission.admit(isIdle: { true }, prepare: { try await owner.prepare(inBackground: false) }) {
            #expect(await runtime.isLoaded()); micReady = true
        }
        #expect(micReady)
        micReady = false // The production coordinator owns mic expiry, independently of this owner.
        try await owner.prepare(inBackground: true)
        #expect(await runtime.isLoaded())
        #expect(await runtime.events.filter { $0 == "prepare" }.count == 1)
    }
    @Test func stopCancelsPreparationWithoutStartingMicrophone() async throws {
        let runtime = FakeRuntime(); let gate = Suspension(); await runtime.setLoadGate(gate)
        let owner = ParityModelOwner(runtime: runtime); let admission = ParityAdmission()
        var micStarts = 0
        let start = Task { try await admission.admit(isIdle: { true }, prepare: { try await owner.prepare(inBackground: false) }) { micStarts += 1 } }
        await waitFor("model preparation") { !(await runtime.events.isEmpty) }
        var stopCalls = 0
        await admission.stop { stopCalls += 1 }
        #expect(stopCalls == 1)
        await gate.release()
        _ = await start.result
        #expect(micStarts == 0)
    }
    @Test func simultaneousStartsAreSerializedAndStateIsRechecked() async throws {
        let admission = ParityAdmission(); let gate = Suspension()
        var idle = true; var starts = 0
        let first = Task { try await admission.admit(isIdle: { idle }, prepare: { await gate.wait() }) { starts += 1 } }
        await Task.yield()
        do { try await admission.admit(isIdle: { idle }, prepare: {}) { starts += 1 }; Issue.record("duplicate admitted") }
        catch ParityPreparationError.busy {} catch { Issue.record("wrong error") }
        idle = false
        await gate.release()
        _ = await first.result
        #expect(starts == 0)
    }
    @Test func resetDuringSuspendedLoadedCheckCannotAdmitInference() async throws {
        let runtime = FakeRuntime(); let owner = ParityModelOwner(runtime: runtime)
        try await owner.prepare(inBackground: false)
        let baseline = await runtime.loadedChecks
        let loaded = Suspension(); await runtime.setLoadedGate(loaded)
        let response = Task { try await owner.respond(instructions: "", prompt: "hello") }
        await waitFor("suspended loaded check") { await runtime.loadedChecks > baseline }
        try await owner.reset()
        await loaded.release()
        do { _ = try await response.value; Issue.record("inference admitted after reset") } catch {}
        #expect(!(await runtime.events.contains("respond")))
    }
    @Test func concurrentSuspendedLoadedChecksCannotOverlapWorkers() async throws {
        let runtime = FakeRuntime(); let owner = ParityModelOwner(runtime: runtime)
        try await owner.prepare(inBackground: false)
        let baseline = await runtime.loadedChecks
        let loaded = Suspension(); let responseGate = Suspension()
        await runtime.setLoadedGate(loaded); await runtime.setResponseGate(responseGate)
        let first = Task { try await owner.respond(instructions: "", prompt: "first") }
        let second = Task { try await owner.respond(instructions: "", prompt: "second") }
        await waitFor("both suspended loaded checks") { await runtime.loadedChecks >= baseline + 2 }
        await loaded.release()
        await waitFor("active worker") { await runtime.active }
        for _ in 0..<30 { await Task.yield() }
        #expect(await runtime.events.filter { $0 == "respond" }.count == 1)
        await responseGate.release()
        let results = [await first.result, await second.result]
        #expect(results.filter { if case .success = $0 { true } else { false } }.count == 1)
    }
    @Test func resetReservesAdmissionBeforeMicInvalidationAndModelRelease() async throws {
        let admission = ParityAdmission(); let release = Suspension()
        var invalidating = false; var modelReleased = false; var starts = 0; var stops = 0
        let reset = Task { await admission.reset {
            invalidating = true
            await release.wait()
            modelReleased = true
        } }
        await waitFor("microphone invalidation") { invalidating }
        #expect(admission.isResetting && admission.isPreparing)
        do {
            try await admission.admit(isIdle: { true }, prepare: {}) { starts += 1 }
            Issue.record("start admitted during reset")
        } catch ParityPreparationError.busy {} catch { Issue.record("wrong admission error") }
        await admission.stop { stops += 1 }
        #expect(stops == 1)
        #expect(starts == 0 && !modelReleased)
        await release.release()
        await reset.value
        #expect(modelReleased && !admission.isPreparing)
    }
    @Test(arguments: ["arm", "start"])
    func aMeetingTakingOwnershipDuringPreparationPreventsMicrophoneAction(command: String) async throws {
        let admission = ParityAdmission(); let gate = Suspension()
        var meetingActive = false; var microphoneActions: [String] = []
        let pending = Task {
            try await admission.admit(isIdle: { true }, canStart: { !meetingActive }, prepare: { await gate.wait() }) {
                microphoneActions.append(command)
            }
        }
        await waitFor("reserved dictation admission") { admission.isPreparing }
        #expect(admission.isPreparing) // The host's meetings.dictationActive includes this reservation.
        meetingActive = true
        await gate.release()
        _ = await pending.result
        #expect(microphoneActions.isEmpty)
    }
    @Test func resetWaitsForActualWorkerSettlementBeforeUnloadAndReacquire() async throws {
        let runtime = FakeRuntime(); let owner = ParityModelOwner(runtime: runtime)
        try await owner.prepare(inBackground: false)
        let gate = Suspension(); await runtime.setResponseGate(gate)
        let response = Task { try await owner.respond(instructions: "", prompt: "hello") }
        await waitFor("active worker") { await runtime.active }
        let reset = Task { try await owner.reset() }
        await waitFor("reset cancellation") { await runtime.events.contains("cancel") }
        #expect(!(await runtime.events.contains("unload")))
        await gate.release()
        _ = await response.result; try await reset.value
        #expect(await runtime.events.suffix(2) == ["settled", "unload"])
        try await owner.prepare(inBackground: false)
        #expect(await runtime.isLoaded())
    }
}
