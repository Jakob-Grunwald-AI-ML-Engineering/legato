import Foundation
import Synchronization
import Testing
@testable import LegatoModels

@Suite struct ModelManagerTests {
    // MARK: lifecycle

    @Test func installWalksNotInstalledDownloadingWarmingInstalled() async {
        let h = Harness()
        defer { h.cleanUp() }
        #expect(await h.manager.state(of: "speech-a") == .notInstalled)

        let states = await collect(await h.manager.install("speech-a"))

        #expect(states.last == .installed(bytes: 1_000))
        guard let warmingAt = states.firstIndex(of: .warming) else {
            Issue.record("never warmed: \(states)")
            return
        }
        #expect(warmingAt == states.count - 2, "warming directly precedes installed")
        let progress = states[..<warmingAt].compactMap { s -> Double? in
            if case .downloading(let p) = s { return p }
            return nil
        }
        #expect(progress.count == warmingAt, "only downloading states before warming")
        #expect(progress.count >= 2)
        #expect(progress.allSatisfy { (0...1).contains($0) })
        #expect(progress == progress.sorted(), "progress is monotonic")
        #expect(h.installers["speech-a"]!.warmCalls == 1)
        #expect(await h.manager.state(of: "speech-a") == .installed(bytes: 1_000))
    }

    @Test func installingAnInstalledModelDoesNotDownloadAgain() async {
        let h = Harness()
        defer { h.cleanUp() }
        _ = await collect(await h.manager.install("speech-a"))
        let again = await collect(await h.manager.install("speech-a"))
        #expect(again == [.installed(bytes: 1_000)])
        #expect(h.installers["speech-a"]!.installCalls == 1)
    }

    @Test func installingAnUnknownModelFails() async {
        let h = Harness()
        defer { h.cleanUp() }
        let states = await collect(await h.manager.install("nope"))
        #expect(states.count == 1)
        if case .failed = states.first {} else { Issue.record("expected failed, got \(states)") }
    }

    // MARK: cancel

    @Test func cancelLeavesNoPartialFolderAndReturnsToNotInstalled() async {
        let fake = FakeInstaller(folderName: "speech-a", gated: true)
        let h = Harness(fake)
        defer { h.cleanUp() }
        let stream = await h.manager.install("speech-a")
        #expect(await eventually { fake.reachedGate })
        #expect(h.folderExists("speech-a"), "precondition: a partial download is on disk")

        await h.manager.cancel("speech-a")

        let states = await collect(stream)
        #expect(states.last == .notInstalled)
        #expect(!h.folderExists("speech-a"))
        #expect(await h.manager.state(of: "speech-a") == .notInstalled)
        #expect(fake.warmCalls == 0)
    }

    // MARK: failure

    @Test func failedInstallShowsFailedAndRetryWorks() async {
        let fake = FakeInstaller(folderName: "speech-a", failFirst: 1)
        let h = Harness(fake)
        defer { h.cleanUp() }

        let first = await collect(await h.manager.install("speech-a"))
        if case .failed = first.last {} else { Issue.record("expected failed, got \(first)") }
        if case .failed = await h.manager.state(of: "speech-a") {} else {
            Issue.record("state should stay failed after a failed install")
        }

        let second = await collect(await h.manager.install("speech-a"))
        #expect(second.last == .installed(bytes: 1_000))
        #expect(fake.installCalls == 2)
        #expect(await h.manager.state(of: "speech-a") == .installed(bytes: 1_000))
    }

    // MARK: completion marker

    @Test func filesOnDiskWithoutTheMarkerAreNotInstalledAndTheStaleFolderIsReplaced() async throws {
        let fake = FakeInstaller(folderName: "speech-a")
        let h = Harness(fake)
        defer { h.cleanUp() }
        // What a download cut short leaves behind: every file the installer looks for, no marker.
        let folder = fake.installFolder(root: h.root)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(count: 10).write(to: folder.appending(path: "weights.bin"))
        try Data(count: 10).write(to: folder.appending(path: "stale.bin"))
        #expect(await fake.isInstalled(root: h.root), "precondition: the installer alone calls this installed")

        #expect(await h.manager.state(of: "speech-a") == .notInstalled)
        #expect(await h.manager.storageUsed() == 0)

        let states = await collect(await h.manager.install("speech-a"))
        #expect(states.last == .installed(bytes: 1_000))
        #expect(fake.installCalls == 1, "the model is downloaded again")
        #expect(!FileManager.default.fileExists(atPath: folder.appending(path: "stale.bin").path), "the stale folder was cleared first")
    }

    @Test func aFinishedInstallLeavesTheInstalledMarker() async throws {
        let fake = FakeInstaller(folderName: "speech-a")
        let h = Harness(fake)
        defer { h.cleanUp() }
        _ = await collect(await h.manager.install("speech-a"))
        let folder = fake.installFolder(root: h.root)
        #expect(InstallMarker.stage(in: folder, id: "speech-a") == .installed)
        #expect(InstallMarker.stage(in: folder, id: "another-model") == nil, "a marker names its model")
    }

    @Test func aMarkerWithoutTheFilesIsNotInstalled() async throws {
        let fake = FakeInstaller(folderName: "speech-a")
        let h = Harness(fake)
        defer { h.cleanUp() }
        try InstallMarker.write(in: fake.installFolder(root: h.root), id: "speech-a", stage: .installed)
        #expect(await h.manager.state(of: "speech-a") == .notInstalled)
    }

    @Test func aDownloadedOnlyMarkerIsNotInstalled() async throws {
        let fake = FakeInstaller(folderName: "speech-a")
        let h = Harness(fake)
        defer { h.cleanUp() }
        let folder = fake.installFolder(root: h.root)
        try Data(count: 10).write(to: { try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true); return folder.appending(path: "weights.bin") }())
        try InstallMarker.write(in: folder, id: "speech-a", stage: .downloaded)
        #expect(await h.manager.state(of: "speech-a") == .notInstalled)
    }

    // MARK: warm failure

    @Test func aFailedWarmIsRetriedWithoutDownloadingAgain() async {
        let fake = FakeInstaller(folderName: "speech-a", warmFailFirst: 1)
        let h = Harness(fake)
        defer { h.cleanUp() }

        let first = await collect(await h.manager.install("speech-a"))
        if case .failed = first.last {} else { Issue.record("expected failed, got \(first)") }
        if case .failed = await h.manager.state(of: "speech-a") {} else {
            Issue.record("a failed warm keeps the failed state")
        }

        let second = await collect(await h.manager.install("speech-a"))
        #expect(second.last == .installed(bytes: 1_000), "the retry clears the failure: \(second)")
        #expect(fake.warmCalls == 2, "warm runs again")
        #expect(fake.installCalls == 1, "the finished download is reused")
        #expect(await h.manager.state(of: "speech-a") == .installed(bytes: 1_000))
    }

    @Test func aFailedWarmThenARelaunchStillRetriesWarmOnly() async {
        let fake = FakeInstaller(folderName: "speech-a", warmFailFirst: 1)
        let h = Harness(fake)
        defer { h.cleanUp() }
        _ = await collect(await h.manager.install("speech-a"))

        // A new manager over the same root: no in-memory failure, only what the disk says.
        let relaunched = ModelManager(
            root: h.root, catalog: [Harness.speech], installers: ["speech-a": fake], selection: h.store)
        #expect(await relaunched.state(of: "speech-a") == .notInstalled)
        let states = await collect(await relaunched.install("speech-a"))
        #expect(states.last == .installed(bytes: 1_000))
        #expect(fake.installCalls == 1)
        #expect(fake.warmCalls == 2)
    }

    // MARK: sharing

    @Test func concurrentInstallsShareOneDownload() async {
        let fake = FakeInstaller(folderName: "speech-a", gated: true)
        let h = Harness(fake)
        defer { h.cleanUp() }
        let a = await h.manager.install("speech-a")
        let b = await h.manager.install("speech-a")
        fake.release()

        let (sa, sb) = await (collect(a), collect(b))

        #expect(sa.last == .installed(bytes: 1_000))
        #expect(sb.last == .installed(bytes: 1_000))
        #expect(fake.installCalls == 1)
    }

    @Test func aWaiterCancellingItsOwnStreamDoesNotCancelTheOthers() async {
        let fake = FakeInstaller(folderName: "speech-a", gated: true)
        let h = Harness(fake)
        defer { h.cleanUp() }
        let a = await h.manager.install("speech-a")
        let b = await h.manager.install("speech-a")
        let waiterA = Task { await collect(a) }
        #expect(await eventually { fake.reachedGate })

        waiterA.cancel()
        _ = await waiterA.value
        fake.release()
        let sb = await collect(b)

        #expect(sb.last == .installed(bytes: 1_000))
        #expect(fake.cancelledCalls == 0)
        #expect(fake.installCalls == 1)
    }

    @Test func explicitCancelEndsEveryWaiter() async {
        let fake = FakeInstaller(folderName: "speech-a", gated: true)
        let h = Harness(fake)
        defer { h.cleanUp() }
        let a = await h.manager.install("speech-a")
        let b = await h.manager.install("speech-a")
        #expect(await eventually { fake.reachedGate })

        await h.manager.cancel("speech-a")

        #expect(await collect(a).last == .notInstalled)
        #expect(await collect(b).last == .notInstalled)
        #expect(!h.folderExists("speech-a"))
    }

    // MARK: delete and storage

    @Test func deleteRemovesTheDeclaredFolderAndResetsState() async {
        let h = Harness()
        defer { h.cleanUp() }
        _ = await collect(await h.manager.install("speech-a"))
        #expect(h.folderExists("speech-a"))

        await h.manager.delete("speech-a")

        #expect(!h.folderExists("speech-a"))
        #expect(await h.manager.state(of: "speech-a") == .notInstalled)
    }

    @Test func deletingTheSelectedModelClearsItsSelection() async throws {
        let h = Harness()
        defer { h.cleanUp() }
        try await h.manager.select("speech-a", role: .liveDictation)
        #expect(await h.manager.selected(role: .liveDictation) == "speech-a")

        await h.manager.delete("speech-a")

        #expect(await h.manager.selected(role: .liveDictation) == nil)
    }

    @Test func deleteRemovesTheFolderOfAnInstallThatQueuedUpWhileItWasCancelling() async throws {
        // An observer that starts a new install the moment the old one reports `notInstalled` gets its
        // call onto the manager before `delete` resumes. `delete` must not strip the folder from under it.
        for round in 0..<40 {
            let fake = FakeInstaller(folderName: "speech-a", gated: true)
            let h = Harness(fake)
            defer { h.cleanUp() }
            let events = await h.manager.events(for: "speech-a")
            let reinstall = Task { () -> [ModelState] in
                for await state in events where state == .notInstalled && fake.installCalls > 0 {
                    return await collect(await h.manager.install("speech-a"))
                }
                return []
            }
            let first = await h.manager.install("speech-a")
            #expect(await eventually { fake.reachedGate })

            await h.manager.delete("speech-a")
            fake.release()
            _ = await reinstall.value
            _ = await collect(first)
            // Let any install that started after the delete finish.
            _ = await eventually {
                switch await h.manager.state(of: "speech-a") {
                case .downloading, .warming: false
                default: true
                }
            }

            let state = await h.manager.state(of: "speech-a")
            if case .failed(let message) = state {
                Issue.record("round \(round): an install lost its folder to delete: \(message)")
                return
            }
        }
    }

    @Test func deleteTellsTheEvictionHookAfterTheFolderIsGone() async {
        let fake = FakeInstaller(folderName: "speech-a")
        let calls = Mutex<[(id: String, folder: URL, folderExisted: Bool)]>([])
        let root = FileManager.default.temporaryDirectory
            .appending(path: "legato-models-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let defaults = UserDefaults(suiteName: "legato.tests.\(UUID().uuidString)")!
        let manager = ModelManager(
            root: root, catalog: [Harness.speech], installers: ["speech-a": fake],
            selection: SelectionStore(defaults: defaults),
            onDelete: { id, folder in
                calls.withLock { $0.append((id, folder, FileManager.default.fileExists(atPath: folder.path))) }
            })
        _ = await collect(await manager.install("speech-a"))

        await manager.delete("speech-a")

        let seen = calls.withLock { $0 }
        #expect(seen.count == 1)
        #expect(seen.first?.id == "speech-a")
        #expect(seen.first?.folder == fake.installFolder(root: root))
        #expect(seen.first?.folderExisted == false, "the hook runs once the files are gone")
    }

    @Test func deletingAnUnknownModelDoesNotCallTheHook() async {
        let calls = Mutex(0)
        let h = Harness()
        defer { h.cleanUp() }
        let manager = ModelManager(
            root: h.root, catalog: [Harness.speech], installers: ["speech-a": h.installers["speech-a"]!],
            selection: h.store, onDelete: { _, _ in calls.withLock { $0 += 1 } })
        await manager.delete("nope")
        #expect(calls.withLock { $0 } == 0)
    }

    @Test func storageUsedSumsInstalledFolders() async {
        let h = Harness(installers: [
            "speech-a": FakeInstaller(folderName: "speech-a", weightsBytes: 1_000),
            "batch-a": FakeInstaller(folderName: "batch-a", weightsBytes: 2_500),
            "llm-a": FakeInstaller(folderName: "llm-a", weightsBytes: 4_000),
        ])
        defer { h.cleanUp() }
        #expect(await h.manager.storageUsed() == 0)

        _ = await collect(await h.manager.install("speech-a"))
        _ = await collect(await h.manager.install("batch-a"))
        #expect(await h.manager.storageUsed() == 3_500)

        await h.manager.delete("speech-a")
        #expect(await h.manager.storageUsed() == 2_500)
    }

    // MARK: select (load on pick)

    @Test func selectStartsTheInstallAndSwitchesOnlyOnceInstalled() async throws {
        let fake = FakeInstaller(folderName: "speech-a", gated: true)
        let h = Harness(fake)
        defer { h.cleanUp() }
        h.store.set("previous", for: .liveDictation)

        let pick = Task { try await h.manager.select("speech-a", role: .liveDictation) }
        #expect(await eventually { fake.reachedGate }, "select started the install")
        #expect(fake.installCalls == 1)
        #expect(await h.manager.selected(role: .liveDictation) == "previous", "previous stays live while installing")

        fake.release()
        try await pick.value

        #expect(await h.manager.selected(role: .liveDictation) == "speech-a")
        #expect(h.store.selected(for: .liveDictation) == "speech-a", "persisted")
        #expect(await h.manager.state(of: "speech-a") == .installed(bytes: 1_000))
        #expect(fake.warmCalls == 1)
    }

    @Test func selectingAnInstalledModelSwitchesWithoutDownloading() async throws {
        let h = Harness()
        defer { h.cleanUp() }
        _ = await collect(await h.manager.install("speech-a"))
        try await h.manager.select("speech-a", role: .liveDictation)
        #expect(await h.manager.selected(role: .liveDictation) == "speech-a")
        #expect(h.installers["speech-a"]!.installCalls == 1)
    }

    @Test func aFailedSelectInstallKeepsThePreviousChoice() async {
        let fake = FakeInstaller(folderName: "speech-a", failFirst: 1)
        let h = Harness(fake)
        defer { h.cleanUp() }
        h.store.set("previous", for: .liveDictation)

        await #expect(throws: ModelError.self) {
            try await h.manager.select("speech-a", role: .liveDictation)
        }

        #expect(await h.manager.selected(role: .liveDictation) == "previous")
    }

    @Test func aCancelledSelectInstallKeepsThePreviousChoice() async {
        let fake = FakeInstaller(folderName: "speech-a", gated: true)
        let h = Harness(fake)
        defer { h.cleanUp() }
        h.store.set("previous", for: .liveDictation)
        let pick = Task { try await h.manager.select("speech-a", role: .liveDictation) }
        #expect(await eventually { fake.reachedGate })

        await h.manager.cancel("speech-a")

        await #expect(throws: ModelError.cancelled(model: "speech-a")) { try await pick.value }
        #expect(await h.manager.selected(role: .liveDictation) == "previous")
    }

    @Test func aLaterPickSupersedesAnEarlierOneStillInstalling() async throws {
        let slow = FakeInstaller(folderName: "speech-a", gated: true)
        let fast = FakeInstaller(folderName: "speech-b")
        let h = Harness(installers: ["speech-a": slow, "speech-b": fast])
        defer { h.cleanUp() }
        let first = Task { try await h.manager.select("speech-a", role: .liveDictation) }
        #expect(await eventually { slow.reachedGate })

        try await h.manager.select("speech-b", role: .liveDictation)
        slow.release()
        try await first.value

        #expect(await h.manager.selected(role: .liveDictation) == "speech-b", "the last pick wins")
        #expect(await h.manager.state(of: "speech-a") == .installed(bytes: 1_000), "the superseded model still installed")
    }

    @Test func aPickThatSupersedesAnotherCancelsItsInstallAndLeavesNoPartialFolder() async throws {
        let slow = FakeInstaller(folderName: "speech-a", gated: true)
        let fast = FakeInstaller(folderName: "speech-b")
        let h = Harness(installers: ["speech-a": slow, "speech-b": fast])
        defer { h.cleanUp() }
        h.store.set("previous", for: .liveDictation)
        let first = Task { try await h.manager.select("speech-a", role: .liveDictation) }
        #expect(await eventually { slow.reachedGate })
        #expect(h.folderExists("speech-a"), "precondition: a partial download is on disk")

        try await h.manager.select("speech-b", role: .liveDictation, superseding: "speech-a")
        #expect(slow.cancelledCalls == 1, "the superseded download was cancelled")
        slow.release() // a download that was not cancelled would finish now

        await #expect(throws: ModelError.cancelled(model: "speech-a")) { try await first.value }
        #expect(!h.folderExists("speech-a"), "no partial folder")
        #expect(await h.manager.state(of: "speech-a") == .notInstalled)
        #expect(await h.manager.selected(role: .liveDictation) == "speech-b")
    }

    @Test func aSupersededInstallThatAnotherCallerWaitsForKeepsGoing() async throws {
        let slow = FakeInstaller(folderName: "speech-a", gated: true)
        let fast = FakeInstaller(folderName: "speech-b")
        let h = Harness(installers: ["speech-a": slow, "speech-b": fast])
        defer { h.cleanUp() }
        let first = Task { try await h.manager.select("speech-a", role: .liveDictation) }
        #expect(await eventually { slow.reachedGate })
        let otherWaiter = await h.manager.install("speech-a")
        let watched = Task { await collect(otherWaiter) }

        try await h.manager.select("speech-b", role: .liveDictation, superseding: "speech-a")
        slow.release()
        try await first.value

        #expect(await watched.value.last == .installed(bytes: 1_000), "the other waiter got its model")
        #expect(slow.cancelledCalls == 0)
        #expect(await h.manager.selected(role: .liveDictation) == "speech-b", "the last pick still wins")
    }

    @Test func supersedingAModelThatIsNotInstallingChangesNothing() async throws {
        let h = Harness(installers: ["speech-a": FakeInstaller(folderName: "speech-a"), "speech-b": FakeInstaller(folderName: "speech-b")])
        defer { h.cleanUp() }
        _ = await collect(await h.manager.install("speech-a"))

        try await h.manager.select("speech-b", role: .liveDictation, superseding: "speech-a")

        #expect(await h.manager.state(of: "speech-a") == .installed(bytes: 1_000), "an installed model is never removed")
        #expect(await h.manager.selected(role: .liveDictation) == "speech-b")
    }

    @Test func selectRejectsAModelOfTheWrongKind() async {
        let h = Harness(installers: ["llm-a": FakeInstaller(folderName: "llm-a")])
        defer { h.cleanUp() }
        await #expect(throws: ModelError.wrongKind(model: "llm-a", role: .liveDictation)) {
            try await h.manager.select("llm-a", role: .liveDictation)
        }
        #expect(h.installers["llm-a"]!.installCalls == 0)
    }

    @Test func selectRejectsAnUnknownModel() async {
        let h = Harness()
        defer { h.cleanUp() }
        await #expect(throws: ModelError.unknownModel("nope")) {
            try await h.manager.select("nope", role: .liveDictation)
        }
    }

    // MARK: nothing implicit

    @Test func constructingAndReadingNeverInstalls() async {
        let a = FakeInstaller(folderName: "speech-a")
        let b = FakeInstaller(folderName: "batch-a")
        let h = Harness(installers: ["speech-a": a, "batch-a": b])
        defer { h.cleanUp() }

        _ = await h.manager.state(of: "speech-a")
        _ = await h.manager.state(of: "batch-a")
        _ = await h.manager.storageUsed()
        _ = await h.manager.selected(role: .liveDictation)
        let events = await h.manager.events(for: "speech-a")
        var it = events.makeAsyncIterator()
        #expect(await it.next() == .notInstalled, "events start with the current state")

        #expect(a.installCalls == 0 && a.warmCalls == 0)
        #expect(b.installCalls == 0 && b.warmCalls == 0)
        #expect(!h.folderExists("speech-a"))
    }

    @Test func eventsReportInstallProgressToObservers() async {
        let h = Harness()
        defer { h.cleanUp() }
        let events = await h.manager.events(for: "speech-a")
        let observer = Task { () -> [ModelState] in
            var seen: [ModelState] = []
            for await s in events {
                seen.append(s)
                if case .installed = s { break }
            }
            return seen
        }
        _ = await collect(await h.manager.install("speech-a"))
        let seen = await observer.value
        #expect(seen.first == .notInstalled)
        #expect(seen.contains(.warming))
        #expect(seen.last == .installed(bytes: 1_000))
    }
}
