import Foundation
import LegatoCore
import Synchronization
import Testing
@testable import LegatoModels

private actor ResourceReleaseGate {
    private var open = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private(set) var arrived = false
    func wait() async {
        arrived = true
        if open { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func release() {
        open = true
        let waiting = waiters; waiters = []
        for waiter in waiting { waiter.resume() }
    }
}

private final class SettlingWarmInstaller: ModelInstaller {
    let base = FakeInstaller(folderName: "speech-a")
    let gate = ResourceReleaseGate()
    let resident = Mutex(false)
    let settled = Mutex(false)
    let cancelled = Mutex(false)
    func installFolder(root: URL) -> URL { base.installFolder(root: root) }
    func isInstalled(root: URL) async -> Bool { await base.isInstalled(root: root) }
    func install(root: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        try await base.install(root: root, progress: progress)
    }
    func warm(root: URL) async throws {
        resident.withLock { $0 = true }
        await withTaskCancellationHandler { await gate.wait() } onCancel: { self.cancelled.withLock { $0 = true } }
        // A native warmup can return successfully after cancellation; the manager must release it.
        settled.withLock { $0 = true }
    }
}

struct ModelManagerResourceReleaseTests {
    @Test func anExistingUnlabelledTrailingClosureStillRunsAfterFileRemoval() async {
        let h = Harness(); defer { h.cleanUp() }
        let installer = FakeInstaller(folderName: "speech-a")
        let observations = Mutex<[Bool]>([])
        let manager = ModelManager(
            root: h.root, catalog: [Harness.speech], installers: ["speech-a": installer], selection: h.store
        ) { _, folder in observations.withLock { $0.append(FileManager.default.fileExists(atPath: folder.path)) } }
        _ = await collect(await manager.install("speech-a"))
        await manager.delete("speech-a")
        #expect(observations.withLock { $0 } == [false])
    }

    @Test func cancellationAfterNativeWarmupReleasesItsResourcesBeforeTerminalState() async {
        let h = Harness(); defer { h.cleanUp() }
        let installer = SettlingWarmInstaller()
        let observations = Mutex<[(settled: Bool, folderExisted: Bool)]>([])
        let manager = ModelManager(
            root: h.root, catalog: [Harness.speech], installers: ["speech-a": installer], selection: h.store,
            onDelete: { _, folder in
                observations.withLock { $0.append((installer.settled.withLock { $0 }, FileManager.default.fileExists(atPath: folder.path))) }
                installer.resident.withLock { $0 = false }
            })
        let stream = await manager.install("speech-a")
        #expect(await eventually { await installer.gate.arrived })
        let cancellation = Task { await manager.cancel("speech-a") }
        #expect(await eventually { installer.cancelled.withLock { $0 } })
        #expect(installer.resident.withLock { $0 })
        #expect(observations.withLock { $0.isEmpty })
        await installer.gate.release()
        await cancellation.value
        #expect(await collect(stream).last == .notInstalled)
        #expect(!installer.resident.withLock { $0 })
        #expect(observations.withLock { $0.count } == 1)
        #expect(observations.withLock { $0.first?.settled } == true)
        #expect(observations.withLock { $0.first?.folderExisted } == false)
    }

    @Test func deletionSettlesResourcesBeforeUnlinkAndReinstallationWaitsForTheWholeDelete() async {
        let h = Harness(); defer { h.cleanUp() }
        let installer = FakeInstaller(folderName: "speech-a")
        let gate = ResourceReleaseGate()
        let postDeleteFolderExisted = Mutex<[Bool]>([])
        let manager = ModelManager(
            root: h.root, catalog: [Harness.speech], installers: ["speech-a": installer], selection: h.store,
            onDelete: { _, folder in postDeleteFolderExisted.withLock { $0.append(FileManager.default.fileExists(atPath: folder.path)) } },
            onWillDelete: { _, _ in await gate.wait() })
        _ = await collect(await manager.install("speech-a"))
        let deletion = Task { await manager.delete("speech-a") }
        #expect(await eventually { await gate.arrived })
        #expect(h.folderExists("speech-a"))
        #expect(await manager.state(of: "speech-a") == .notInstalled)
        let reinstall = Task { await collect(await manager.install("speech-a")) }
        for _ in 0..<20 { await Task.yield() }
        #expect(installer.installCalls == 1)
        await gate.release()
        await deletion.value
        #expect(await reinstall.value.last == .installed(bytes: 1_000))
        #expect(installer.installCalls == 2)
        #expect(h.folderExists("speech-a"))
        #expect(postDeleteFolderExisted.withLock { $0 } == [false])
    }
}
