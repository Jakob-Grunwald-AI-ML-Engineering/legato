import Foundation
import Synchronization
@testable import LegatoModels

struct FakeInstallError: Error, Equatable { var tag = "boom" }

/// A scriptable installer writing real files, so delete, size and partial-folder checks are real.
///
/// `install` writes a `.part` file, reports each of `steps`, optionally waits at `gate`, then replaces
/// the part with `weights.bin` (`weightsBytes` long), which is also the "installed" marker.
final class FakeInstaller: ModelInstaller {
    let folderName: String
    let steps: [Double]
    let weightsBytes: Int
    private let gate: AsyncStream<Void>?
    private let gateCont: AsyncStream<Void>.Continuation?
    private struct Counters {
        var installs = 0
        var warms = 0
        var cancelled = 0
        var reachedGate = false
        var failuresLeft = 0
        var warmFailuresLeft = 0
    }
    private let counters = Mutex(Counters())

    /// - Parameters:
    ///   - gated: hold the download after the first step until `release()`.
    ///   - failFirst: how many installs fail (after the first step) before one succeeds.
    ///   - warmFailFirst: how many warms throw before one succeeds.
    init(folderName: String, steps: [Double] = [0.25, 0.5, 0.75, 1.0], weightsBytes: Int = 1_000,
         gated: Bool = false, failFirst: Int = 0, warmFailFirst: Int = 0) {
        self.folderName = folderName
        self.steps = steps
        self.weightsBytes = weightsBytes
        if gated {
            let (s, c) = AsyncStream<Void>.makeStream()
            gate = s
            gateCont = c
        } else {
            gate = nil
            gateCont = nil
        }
        counters.withLock { $0.failuresLeft = failFirst; $0.warmFailuresLeft = warmFailFirst }
    }

    var installCalls: Int { counters.withLock { $0.installs } }
    var warmCalls: Int { counters.withLock { $0.warms } }
    var cancelledCalls: Int { counters.withLock { $0.cancelled } }
    var reachedGate: Bool { counters.withLock { $0.reachedGate } }

    /// Lets every waiting (and future) download pass the gate.
    func release() { gateCont?.finish() }

    func installFolder(root: URL) -> URL { root.appending(path: folderName, directoryHint: .isDirectory) }

    func isInstalled(root: URL) async -> Bool {
        FileManager.default.fileExists(atPath: installFolder(root: root).appending(path: "weights.bin").path)
    }

    func install(root: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        counters.withLock { $0.installs += 1 }
        let folder = installFolder(root: root)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let part = folder.appending(path: "weights.bin.part")
        try Data(count: 100).write(to: part)
        for (i, step) in steps.enumerated() {
            progress(step)
            if i == 0 {
                let shouldFail = counters.withLock { c -> Bool in
                    if c.failuresLeft > 0 { c.failuresLeft -= 1; return true }
                    return false
                }
                if shouldFail { throw FakeInstallError() }
                if let gate {
                    counters.withLock { $0.reachedGate = true }
                    for await _ in gate {}
                }
            }
            if Task.isCancelled {
                counters.withLock { $0.cancelled += 1 }
                throw CancellationError()
            }
            await Task.yield()
        }
        try Data(count: weightsBytes).write(to: folder.appending(path: "weights.bin"))
        try? FileManager.default.removeItem(at: part)
    }

    func warm(root: URL) async throws {
        let shouldFail = counters.withLock { c -> Bool in
            c.warms += 1
            if c.warmFailuresLeft > 0 { c.warmFailuresLeft -= 1; return true }
            return false
        }
        if shouldFail { throw FakeInstallError(tag: "warm") }
    }
}

/// A temp storage root, a throwaway defaults suite and a manager over fake installers.
struct Harness: @unchecked Sendable {
    let root: URL
    let suite: String
    let defaults: UserDefaults
    let store: SelectionStore
    let installers: [String: FakeInstaller]
    let manager: ModelManager

    static let speech = ModelDescriptor(
        id: "speech-a", kind: .speechStreaming, displayName: "Speech A", approxBytes: 1_000,
        languages: ["de", "en"], licence: "MIT", family: "fake")
    static let speechB = ModelDescriptor(
        id: "speech-b", kind: .speechStreaming, displayName: "Speech B", approxBytes: 1_000,
        languages: ["en"], licence: "MIT", family: "fake")
    static let batch = ModelDescriptor(
        id: "batch-a", kind: .speechBatch, displayName: "Batch A", approxBytes: 2_000,
        licence: "MIT", family: "fake")
    static let llm = ModelDescriptor(
        id: "llm-a", kind: .llm, displayName: "LLM A", approxBytes: 3_000,
        licence: "Apache-2.0", platforms: [.macOS], family: "fake")

    /// - Parameter installers: fake installers keyed by catalog id; the catalog is the descriptors
    ///   in `catalog`, which default to the four above.
    init(installers: [String: FakeInstaller], catalog: [ModelDescriptor]? = nil) {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "legato-models-\(UUID().uuidString)", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let suite = "legato.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let store = SelectionStore(defaults: defaults)
        self.root = root
        self.suite = suite
        self.defaults = defaults
        self.store = store
        self.installers = installers
        self.manager = ModelManager(
            root: root,
            catalog: catalog ?? [Self.speech, Self.speechB, Self.batch, Self.llm],
            installers: installers,
            selection: store)
    }

    /// One fake installer for `speech-a`; the common case.
    init(_ installer: FakeInstaller = FakeInstaller(folderName: "speech-a")) {
        self.init(installers: ["speech-a": installer])
    }

    func folderExists(_ name: String) -> Bool {
        FileManager.default.fileExists(atPath: root.appending(path: name).path)
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: root)
        defaults.removePersistentDomain(forName: suite)
    }
}

/// Polls until `condition` holds or a generous 30 s deadline passes (a hang guard, not a speed bound).
func eventually(_ condition: () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + .seconds(30)
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return await condition()
}

/// Drains a stream to its end.
func collect(_ stream: AsyncStream<ModelState>) async -> [ModelState] {
    var out: [ModelState] = []
    for await s in stream { out.append(s) }
    return out
}
