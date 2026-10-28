import Foundation
import LegatoCore
import Synchronization
import Testing
@testable import LegatoCoreML

private actor NativeGate {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if opened { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func open() {
        opened = true
        let pending = waiters; waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }
}
private struct BlockingDriver: CoreMLDriving {
    let cancellation: CoreMLCancellation
    let entered: NativeGate
    let returns: NativeGate
    let contextLength = 2_048
    func tokens(instructions: String, examples: [LLMExample], prompt: String) async throws -> [Int] { [1, 2, 3] }
    func generate(tokens: [Int], outputLimit: Int) async throws -> CoreMLGeneration {
        await entered.open()
        await returns.wait() // An opaque native operation keeps running after its Swift caller is cancelled.
        try cancellation.check()
        return .init(text: "Complete", stopReason: "eos_token")
    }
}
struct CoreMLSettlementTests {
    private let spec = CoreMLModels.specs[0]
    @Test func cancellationKeepsOwnershipUntilNativePredictionSettles() async throws {
        let entered = NativeGate(), returns = NativeGate()
        let backend = CoreMLBackend(spec: spec, folder: URL(filePath: "/fixture")) { cancellation in
            BlockingDriver(cancellation: cancellation, entered: entered, returns: returns)
        }
        try await backend.prepare()
        let response = Task { try await backend.respond(instructions: "Clean", prompt: "A") }
        await entered.wait()
        response.cancel()
        await #expect(throws: (any Error).self) { try await backend.respond(instructions: "Clean", prompt: "B") }
        let settled = Mutex(false)
        let waiter = Task { await backend.waitUntilSettled(); settled.withLock { $0 = true } }
        for _ in 0..<100 { await Task.yield() }
        #expect(settled.withLock { $0 } == false)
        await returns.open()
        await #expect(throws: CancellationError.self) { try await response.value }
        await waiter.value
        #expect(settled.withLock { $0 })
        #expect(try await backend.respond(instructions: "Clean", prompt: "C") == "Complete")
    }
    @Test func unloadingCancelsButWaitsAndMakesReadinessUnavailable() async throws {
        let entered = NativeGate(), returns = NativeGate()
        let backend = CoreMLBackend(spec: spec, folder: URL(filePath: "/fixture")) { cancellation in
            BlockingDriver(cancellation: cancellation, entered: entered, returns: returns)
        }
        try await backend.prepare()
        let response = Task { try await backend.respond(instructions: "Clean", prompt: "A") }
        await entered.wait()
        let released = Mutex(false)
        let release = Task { await backend.unload(); released.withLock { $0 = true } }
        for _ in 0..<100 { await Task.yield() }
        #expect(released.withLock { $0 } == false)
        #expect(await backend.availability.isAvailable == false)
        await #expect(throws: (any Error).self) { try await backend.prepare() }
        await returns.open()
        await #expect(throws: CancellationError.self) { try await response.value }
        await release.value
        #expect(released.withLock { $0 })
        #expect(await backend.isPrepared() == false)
    }
    @Test func cancelledPreparationCannotPublishALateNativeLoad() async {
        let entered = NativeGate(), returns = NativeGate()
        let backend = CoreMLBackend(spec: spec, folder: URL(filePath: "/fixture")) { cancellation in
            await entered.open(); await returns.wait()
            return BlockingDriver(cancellation: cancellation, entered: entered, returns: returns)
        }
        let preparing = Task { try await backend.prepare() }
        await entered.wait()
        let released = Mutex(false)
        let release = Task { await backend.unload(); released.withLock { $0 = true } }
        for _ in 0..<100 { await Task.yield() }
        #expect(released.withLock { $0 } == false)
        await returns.open()
        await #expect(throws: CancellationError.self) { try await preparing.value }
        await release.value
        #expect(await backend.isPrepared() == false)
    }
    @Test func concurrentPreparationSharesOneNativeLoad() async throws {
        let entered = NativeGate(), returns = NativeGate(), loads = Mutex(0)
        let backend = CoreMLBackend(spec: spec, folder: URL(filePath: "/fixture")) { cancellation in
            loads.withLock { $0 += 1 }; await entered.open(); await returns.wait()
            return BlockingDriver(cancellation: cancellation, entered: entered, returns: returns)
        }
        let first = Task { try await backend.prepare() }
        await entered.wait()
        let second = Task { try await backend.prepare() }
        for _ in 0..<100 { await Task.yield() }
        #expect(loads.withLock { $0 } == 1)
        await returns.open()
        try await first.value; try await second.value
        #expect(await backend.isPrepared())
        #expect(loads.withLock { $0 } == 1)
    }
}


extension CoreMLSettlementTests {
    @Test func acquiringDuringFolderReleaseWaitsForSettlementAndGetsOneFreshOwner() async throws {
        let entered = NativeGate(), returns = NativeGate(), acquisitionStarted = NativeGate()
        let store = CoreMLModelStore { spec, folder in
            CoreMLBackend(spec: spec, folder: folder) { cancellation in
                BlockingDriver(cancellation: cancellation, entered: entered, returns: returns)
            }
        }
        let root = URL(filePath: "/fixture-shared-owner")
        let old = await store.backend(for: spec, root: root)
        try await old.prepare()
        let response = Task { try await old.respond(instructions: "Clean", prompt: "A") }
        await entered.wait()
        let release = Task { await store.release(folder: spec.folder(root: root)) }
        for _ in 0..<1_000 {
            if await !old.isPrepared() { break }
            await Task.yield()
        }
        #expect(await old.isPrepared() == false)
        let secondRelease = Task { await store.release(folder: spec.folder(root: root)) }
        let acquired = Mutex<CoreMLBackend?>(nil)
        let acquisition = Task {
            await acquisitionStarted.open()
            let backend = await store.backend(for: spec, root: root)
            acquired.withLock { $0 = backend }
            return backend
        }
        await acquisitionStarted.wait()
        for _ in 0..<100 { await Task.yield() }
        #expect(acquired.withLock { $0 } == nil, "No owner escapes while this folder's native operation is settling")
        await returns.open()
        await #expect(throws: CancellationError.self) { try await response.value }
        await release.value
        await secondRelease.value
        let fresh = await acquisition.value
        #expect(fresh !== old)
        let again = await store.backend(for: spec, root: root)
        #expect(again === fresh, "Release cleanup must not evict the replacement owner")
        #expect(await fresh.isPrepared() == false)
    }
}
