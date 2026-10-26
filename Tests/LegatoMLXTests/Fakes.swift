import Foundation
import LegatoCore
import LegatoModels
import Synchronization
@testable import LegatoMLX

/// Writes what the Hub would: a snapshot of files into the folder, and records what was asked for.
final class FakeFetcher: MLXFileFetcher {
    struct Call: Equatable { var repo: String; var folder: URL; var patterns: [String] }
    private let calls = Mutex<[Call]>([])
    let files: [String]
    let failure: (any Error & Sendable)?

    init(files: [String] = ["config.json", "tokenizer.json", "tokenizer_config.json", "model.safetensors"], failure: (any Error & Sendable)? = nil) {
        self.files = files
        self.failure = failure
    }

    var recorded: [Call] { calls.withLock { $0 } }

    func fetch(repo: String, to folder: URL, matching patterns: [String], progress: @escaping @Sendable (Double) -> Void) async throws {
        calls.withLock { $0.append(Call(repo: repo, folder: folder, patterns: patterns)) }
        progress(0.25)
        if let failure { throw failure }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for name in files { try Data("x".utf8).write(to: folder.appending(path: name)) }
        progress(1.0)
    }
}

/// An installer that only counts, and answers `isInstalled` from a flag.
final class CountingInstaller: ModelInstaller {
    private struct State { var installs = 0; var warms = 0; var installed: Bool }
    private let state: Mutex<State>
    let folderName: String

    init(folderName: String, installed: Bool) {
        self.folderName = folderName
        state = Mutex(State(installed: installed))
    }

    var installCalls: Int { state.withLock { $0.installs } }
    var warmCalls: Int { state.withLock { $0.warms } }

    func installFolder(root: URL) -> URL { root.appending(path: folderName, directoryHint: .isDirectory) }
    func isInstalled(root: URL) async -> Bool { state.withLock { $0.installed } }
    func install(root: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        state.withLock { $0.installs += 1; $0.installed = true }
    }
    func warm(root: URL) async throws { state.withLock { $0.warms += 1 } }
}

/// A scripted backend with a name, so tests can tell which one the registry chose.
struct NamedBackend: LLMBackend {
    let id: String
    var availabilityValue: LLMAvailability = .available
    var maxPromptCharacters: Int? { nil }
    var availability: LLMAvailability { get async { availabilityValue } }
    func respond(instructions: String, prompt: String) async throws -> String { prompt }
}

func tempRoot() -> URL {
    FileManager.default.temporaryDirectory.appending(path: "legato-mlx-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
}

func freshDefaults() -> (UserDefaults, String) {
    let suite = "legato-mlx-tests-\(UUID().uuidString)"
    return (UserDefaults(suiteName: suite)!, suite)
}
