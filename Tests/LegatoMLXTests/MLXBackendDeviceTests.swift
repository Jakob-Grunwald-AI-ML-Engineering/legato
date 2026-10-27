import Foundation
import LegatoCore
import LegatoModels
import LegatoPostProcessing
import Synchronization
import Testing
@testable import LegatoMLX

private let qwen = MLXModels.spec(id: MLXModels.qwen3_1_7bID)!

/// A generator that records the device of every load and generation and streams scripted chunks. Each chunk
/// is handed out only when the consumer asks for it, so the test sees how many were pulled.
private final class RecordingGenerator: MLXGenerating {
    private struct State {
        var loads: [ComputeDevice] = []
        var streams: [ComputeDevice] = []
        var pulled = 0
        var terminated = false
    }

    private let state = Mutex(State())
    let chunks: [String]
    /// Runs before chunk `index` is handed out (index from 0).
    let beforeChunk: @Sendable (Int) async -> Void

    init(chunks: [String] = ["Hello", " world."], beforeChunk: @escaping @Sendable (Int) async -> Void = { _ in }) {
        self.chunks = chunks
        self.beforeChunk = beforeChunk
    }

    var loads: [ComputeDevice] { state.withLock { $0.loads } }
    var streams: [ComputeDevice] { state.withLock { $0.streams } }
    var pulled: Int { state.withLock { $0.pulled } }
    var terminated: Bool { state.withLock { $0.terminated } }

    func load(spec: MLXModelSpec, folder: URL, device: ComputeDevice) async throws {
        state.withLock { $0.loads.append(device) }
    }

    func stream(
        spec: MLXModelSpec, folder: URL, instructions: String, examples: [LLMExample], prompt: String,
        device: ComputeDevice
    ) async throws -> AsyncThrowingStream<String, any Error> {
        state.withLock { $0.streams.append(device) }
        let chunks = chunks
        let beforeChunk = beforeChunk
        // Demand-driven: a chunk is made only when the consumer asks for it. The cursor goes away with the
        // stream, which is how the test sees that the consumer dropped it.
        let cursor = Cursor { [self] in self.state.withLock { $0.terminated = true } }
        return AsyncThrowingStream<String, any Error>(unfolding: { [self] in
            let next = cursor.advance()
            guard next < chunks.count else { return nil }
            await beforeChunk(next)
            self.state.withLock { $0.pulled += 1 }
            return chunks[next]
        })
    }
}

private final class Cursor: Sendable {
    private let index = Mutex(0)
    private let onRelease: @Sendable () -> Void

    init(onRelease: @escaping @Sendable () -> Void) { self.onRelease = onRelease }
    deinit { onRelease() }

    func advance() -> Int { index.withLock { i in defer { i += 1 }; return i } }
}

/// A complete-looking model folder, so the backend's on-disk check passes.
private func completeFolder() throws -> URL {
    let folder = qwen.folder(root: tempRoot())
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    for name in ["config.json", "tokenizer.json", "model.safetensors"] {
        try Data("x".utf8).write(to: folder.appending(path: name))
    }
    return folder
}

private func backend(
    device: ComputeDevice = .gpu, gpu: @escaping @Sendable () async -> Bool, generator: RecordingGenerator
) throws -> MLXBackend {
    MLXBackend(spec: qwen, folder: try completeFolder(), device: device, canUseGPU: gpu, generator: generator)
}

@Suite("MLXBackend picks the device per call")
struct MLXBackendDeviceTests {
    @Test func aGpuBackendLoadsAndGeneratesOnTheCpuWhileTheGpuIsNotUsable() async throws {
        let generator = RecordingGenerator()
        let reply = try await backend(gpu: { false }, generator: generator).respond(instructions: "i", prompt: "p")
        #expect(reply == "Hello world.")
        #expect(generator.loads == [.cpu])
        #expect(generator.streams == [.cpu])
    }

    @Test func theDeviceIsDecidedAtEachCallNotWhenTheBackendIsMade() async throws {
        let gpu = Mutex(true)
        let generator = RecordingGenerator()
        let mlx = try backend(gpu: { gpu.withLock { $0 } }, generator: generator)
        _ = try await mlx.respond(instructions: "i", prompt: "p")
        gpu.withLock { $0 = false }
        _ = try await mlx.respond(instructions: "i", prompt: "p")
        #expect(generator.loads == [.gpu, .cpu])
        #expect(generator.streams == [.gpu, .cpu])
    }

    @Test func losingTheGpuBetweenTheLoadAndTheGenerationGeneratesOnTheCpu() async throws {
        let calls = Mutex(0)
        let generator = RecordingGenerator()
        // First ask (the load): usable. Every later ask: not.
        let mlx = try backend(gpu: { calls.withLock { $0 += 1; return $0 == 1 } }, generator: generator)
        _ = try await mlx.respond(instructions: "i", prompt: "p")
        #expect(generator.loads == [.gpu])
        #expect(generator.streams == [.cpu])
    }

    @Test func aCpuBackendNeverTouchesTheGpu() async throws {
        let generator = RecordingGenerator()
        _ = try await backend(device: .cpu, gpu: { true }, generator: generator).respond(instructions: "i", prompt: "p")
        #expect(generator.loads == [.cpu])
        #expect(generator.streams == [.cpu])
    }

    @Test func losingTheGpuMidGenerationStopsIssuingWork() async throws {
        let gpu = Mutex(true)
        let generator = RecordingGenerator(chunks: ["a", "b", "c", "d", "e"]) { index in
            if index == 1 { gpu.withLock { $0 = false } }
        }
        let mlx = try backend(gpu: { gpu.withLock { $0 } }, generator: generator)
        await #expect(throws: LLMError.self) { try await mlx.respond(instructions: "i", prompt: "p") }
        #expect(generator.pulled == 2)
        #expect(generator.terminated)
    }

    @Test func aCancelledGenerationStopsPullingTokens() async throws {
        let started = AsyncStream<Void>.makeStream()
        let generator = RecordingGenerator(chunks: Array(repeating: "x", count: 50)) { index in
            if index == 1 {
                started.continuation.yield()
                // Hold the second token until the caller is cancelled.
                while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(5)) }
            }
        }
        let mlx = try backend(gpu: { true }, generator: generator)
        let run = Task { try await mlx.respond(instructions: "i", prompt: "p") }
        for await _ in started.stream { break }
        run.cancel()
        await #expect(throws: CancellationError.self) { try await run.value }
        #expect(generator.pulled <= 2)
        #expect(generator.terminated)
    }

    @Test func aCancelledCallDoesNotStartTheGeneration() async throws {
        let generator = RecordingGenerator()
        let mlx = try backend(gpu: { true }, generator: generator)
        let run = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await mlx.respond(instructions: "i", prompt: "p")
        }
        await #expect(throws: CancellationError.self) { try await run.value }
        #expect(generator.streams.isEmpty)
    }

    @Test func theRegistrysGpuBackendAsksTheRegistrysGpuCheck() async throws {
        let root = tempRoot()
        let folder = qwen.folder(root: root)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for name in ["config.json", "tokenizer.json", "model.safetensors"] {
            try Data("x".utf8).write(to: folder.appending(path: name))
        }
        let (defaults, _) = freshDefaults()
        let installer = CountingInstaller(folderName: "mlx/\(qwen.folderName)", installed: true)
        let store = SelectionStore(defaults: defaults)
        store.set(qwen.id, for: .cleanup)
        try InstallMarker.write(in: installer.installFolder(root: root), id: qwen.id, stage: .installed)
        let manager = ModelManager(root: root, catalog: [qwen.descriptor], installers: [qwen.id: installer], selection: store)
        let gpu = Mutex(true)
        let registry = CleanupRegistry(models: manager, foundationModels: nil, canUseGPU: { gpu.withLock { $0 } })
        let resolution = await registry.resolve(preference: .auto, background: .cpu)
        let mlx = try #require(resolution.backend as? MLXBackend)
        #expect(mlx.device == .gpu)
        #expect(await mlx.currentDevice() == .gpu)
        gpu.withLock { $0 = false }
        #expect(await mlx.currentDevice() == .cpu)
    }
}
