import Foundation
import LegatoCoreML
import LegatoModels
import Synchronization
import Testing
@testable import LegatoAppServices

/// Downloads in two steps: a partial file at once, then, once released, the complete one. Waits
/// cancellably in between and records a cancelled download.
private final class GatedInstaller: ModelInstaller {
    private struct State { var released = false; var started = 0; var cancelled = 0 }
    private let state = Mutex(State())
    let folderName: String

    init(folderName: String) { self.folderName = folderName }

    var started: Int { state.withLock { $0.started } }
    var cancelled: Int { state.withLock { $0.cancelled } }
    func release() { state.withLock { $0.released = true } }

    func installFolder(root: URL) -> URL { root.appending(path: folderName, directoryHint: .isDirectory) }
    func isInstalled(root: URL) async -> Bool {
        FileManager.default.fileExists(atPath: installFolder(root: root).appending(path: "complete").path)
    }

    func install(root: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        state.withLock { $0.started += 1 }
        let folder = installFolder(root: root)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: folder.appending(path: "partial"))
        progress(0.3)
        do {
            while !state.withLock({ $0.released }) { try await Task.sleep(for: .milliseconds(2)) }
        } catch {
            state.withLock { $0.cancelled += 1 }
            throw error
        }
        try Data("x".utf8).write(to: folder.appending(path: "complete"))
    }

    func warm(root: URL) async throws {}
}

/// Collects the `done` calls of picks.
@MainActor private final class Done {
    var calls: [String] = []
    func callback(_ name: String) -> @MainActor ((any Error)?) -> Void {
        { [weak self] error in self?.calls.append(error.map { "\(name): \($0)" } ?? "\(name): ok") }
    }
}

@MainActor
private struct Rig {
    let root = FileManager.default.temporaryDirectory.appending(path: "legato-pick-cancel-\(UUID().uuidString)")
    let installers: [String: GatedInstaller]
    let services: ModelServices

    init() {
        // The real catalog (building the services downloads nothing), with every installer replaced.
        let catalog = ModelServices(
            root: root, defaults: UserDefaults(suiteName: "legato.pick-cancel.\(UUID().uuidString)")!, platform: .macOS
        ).catalog
        let installers = Dictionary(uniqueKeysWithValues: catalog.map { ($0.id, GatedInstaller(folderName: $0.id)) })
        self.installers = installers
        services = ModelServices(
            root: root, defaults: UserDefaults(suiteName: "legato.pick-cancel.\(UUID().uuidString)")!,
            platform: .macOS, installers: installers)
    }

    func folder(_ id: String) -> URL { installers[id]!.installFolder(root: root) }
    func leftovers(_ id: String) -> Bool { FileManager.default.fileExists(atPath: folder(id).path) }
    func state(_ id: String) async -> ModelState { await services.manager.state(of: id) }
    func downloading(_ id: String) async -> Bool {
        if case .downloading = await state(id) { return installers[id]!.started > 0 }
        return false
    }
}

/// Polls until `condition` holds or a generous 30 s deadline passes (a hang guard, not a speed bound).
private func until(_ condition: @MainActor () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + .seconds(30)
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return await condition()
}

private let multilingual = "nemotron-multilingual-560"
private let parakeet = "parakeet-eou-320"

@MainActor @Suite struct ModelPickCancelTests {
    @Test func pickingAnotherModelCancelsTheDownloadInFlight() async throws {
        let rig = Rig()
        let done = Done()
        rig.services.pick(multilingual, role: .liveDictation, done: done.callback("first"))
        #expect(await until { await rig.downloading(multilingual) })
        rig.services.pick(parakeet, role: .liveDictation, done: done.callback("second"))
        #expect(await until { rig.installers[multilingual]!.cancelled == 1 })
        #expect(await until { await rig.state(multilingual) == .notInstalled })
        #expect(!rig.leftovers(multilingual), "the cancelled download leaves no partial files")
        rig.installers[parakeet]!.release()
        #expect(await until { done.calls == ["second: ok"] })
        #expect(rig.services.selected(.liveDictation) == parakeet)
    }

    @Test func backToAppleSpeechCancelsTheDownloadInFlight() async throws {
        let rig = Rig()
        let done = Done()
        rig.services.pick(multilingual, role: .liveDictation, done: done.callback("pick"))
        let pick = try #require(rig.services.currentPickTask(for: .liveDictation))
        #expect(await until { await rig.downloading(multilingual) })
        let abandonment = try #require(rig.services.clearPickOperation(.liveDictation))
        await abandonment.value
        await pick.value
        #expect(await until { rig.installers[multilingual]!.cancelled == 1 })
        #expect(await until { await rig.state(multilingual) == .notInstalled })
        #expect(!rig.leftovers(multilingual))
        #expect(done.calls.isEmpty)
        #expect(rig.services.selected(.liveDictation) == nil)
    }

    @Test func aDownloadSomeoneElseWaitsForCarriesOn() async throws {
        let rig = Rig()
        let other = Task { for await _ in await rig.services.manager.install(multilingual) {} }
        #expect(await until { await rig.downloading(multilingual) })
        rig.services.pick(multilingual, role: .liveDictation, done: { _ in })
        let pick = try #require(rig.services.currentPickTask(for: .liveDictation))
        #expect(await until { await rig.services.manager.selectionWaiterCount(multilingual, role: .liveDictation) == 1 })
        let abandonment = try #require(rig.services.clearPickOperation(.liveDictation))
        await abandonment.value
        await pick.value
        #expect(rig.installers[multilingual]!.cancelled == 0)
        rig.installers[multilingual]!.release()
        await other.value
        #expect(await rig.state(multilingual) != .notInstalled)
    }

    @Test func cancellingADownloadStopsItWithoutAnErrorAndLeavesNoFiles() async throws {
        let rig = Rig()
        let done = Done()
        let previous = rig.services.selected(.liveDictation)
        rig.services.pick(multilingual, role: .liveDictation, done: done.callback("pick"))
        let pick = try #require(rig.services.currentPickTask(for: .liveDictation))
        #expect(await until { await rig.downloading(multilingual) })
        await rig.services.cancelDownload(multilingual)
        #expect(await until { await rig.state(multilingual) == .notInstalled })
        #expect(rig.installers[multilingual]!.cancelled == 1)
        #expect(!rig.leftovers(multilingual))
        await pick.value
        #expect(done.calls.isEmpty, "a cancel is no failure")
        #expect(rig.services.selected(.liveDictation) == previous)
    }

    @Test func cancellingACleanupModelDownloadWorksTheSame() async throws {
        let rig = Rig()
        let done = Done()
        let qwen = CoreMLModels.qwen3_1_7bID
        rig.services.pick(qwen, role: .cleanup, done: done.callback("pick"))
        let pick = try #require(rig.services.currentPickTask(for: .cleanup))
        #expect(await until { await rig.downloading(qwen) })
        await rig.services.cancelDownload(qwen)
        #expect(await until { await rig.state(qwen) == .notInstalled })
        #expect(!rig.leftovers(qwen))
        await pick.value
        #expect(done.calls.isEmpty)
    }

    @Test func deletingADownloadingModelReportsNoError() async throws {
        let rig = Rig()
        let done = Done()
        rig.services.pick(multilingual, role: .liveDictation, done: done.callback("pick"))
        let pick = try #require(rig.services.currentPickTask(for: .liveDictation))
        #expect(await until { await rig.downloading(multilingual) })
        await rig.services.manager.delete(multilingual)
        #expect(await rig.state(multilingual) == .notInstalled)
        await pick.value
        #expect(done.calls.isEmpty, "the row goes back to not installed, without an error")
    }
}
