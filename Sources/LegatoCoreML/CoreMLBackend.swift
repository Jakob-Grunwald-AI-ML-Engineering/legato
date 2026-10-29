import Foundation
import LegatoCore
import Synchronization

struct CoreMLGeneration: Sendable {
    let text: String
    let stopReason: String
    /// The generated token ids (stop token excluded): what the native state holds after `text`.
    var tokens: [Int] = []
    /// Prompt tokens this call prefilled (all of them unless a prefix was reused).
    var prefilled = 0
    /// Seconds spent in prefill, as the runtime measured it.
    var prefillSeconds: Double = 0
}
protocol CoreMLDriving: Sendable {
    var contextLength: Int { get }
    /// Tokens per batched prefill call; a remainder below it is prefilled one token per call.
    var batchSize: Int { get }
    /// The checkpoint's chat format, for session continuations.
    var promptFamily: CoreMLPromptFamily { get }
    func tokens(instructions: String, examples: [LLMExample], prompt: String) async throws -> [Int]
    /// Raw tokens of already rendered text (no special tokens added).
    func encode(_ text: String) async throws -> [Int]
    func generate(tokens: [Int], outputLimit: Int) async throws -> CoreMLGeneration
    /// Like ``generate(tokens:outputLimit:)``; `reusingPrefix` > 0 promises the native state already holds
    /// `tokens[0..<reusingPrefix]` from this driver's previous generation, so only the rest is prefilled.
    func generate(tokens: [Int], reusingPrefix: Int, outputLimit: Int) async throws -> CoreMLGeneration
}
extension CoreMLDriving {
    var batchSize: Int { 1 }
    var promptFamily: CoreMLPromptFamily { .qwen3 }
    func encode(_ text: String) async throws -> [Int] { throw LLMError.unavailable(reason: "This Core ML driver cannot keep a session.") }
    func generate(tokens: [Int], reusingPrefix: Int, outputLimit: Int) async throws -> CoreMLGeneration {
        guard reusingPrefix == 0 else { throw LLMError.unavailable(reason: "This Core ML driver cannot keep a session.") }
        return try await generate(tokens: tokens, outputLimit: outputLimit)
    }
}

/// Owns native work through actual settlement; a cancellation request alone never permits a second worker.
final class CoreMLCancellation: Sendable {
    private struct State {
        var running = false
        var cancelled = false
        var waiters: [CheckedContinuation<Void, Never>] = []
    }
    private let state = Mutex(State())
    func begin() throws {
        try state.withLock {
            guard !$0.running else { throw LLMError.unavailable(reason: "Core ML is busy settling another operation.") }
            $0.running = true; $0.cancelled = false
        }
    }
    func check() throws { try state.withLock { if $0.cancelled { throw CancellationError() } } }
    func cancel() { state.withLock { $0.cancelled = true } }
    func settle() {
        let waiters = state.withLock { value in
            value.running = false
            let waiters = value.waiters; value.waiters.removeAll(); return waiters
        }
        for waiter in waiters { waiter.resume() }
    }
    func waitUntilSettled() async {
        await withCheckedContinuation { continuation in
            let waiting = state.withLock { value in
                if value.running { value.waiters.append(continuation); return true }
                return false
            }
            if !waiting { continuation.resume() }
        }
    }
}

/// A prepared, serialized Core ML cleanup model. Responses never download or cold-load resources.
public actor CoreMLBackend: LLMBackend, ModelResourceLifecycle {
    public nonisolated let spec: CoreMLModelSpec
    public nonisolated let folder: URL
    public nonisolated var id: String { "coreml:\(spec.id)" }
    public nonisolated let maxPromptCharacters: Int? = nil
    private nonisolated let cancellation = CoreMLCancellation()
    private let loader: @Sendable (CoreMLCancellation) async throws -> any CoreMLDriving
    private var runtime: (any CoreMLDriving)?
    private var preparation: Task<any CoreMLDriving, any Error>?
    private var releasing: Task<Void, Never>?
    private var epoch = 0
    private var loadSerial = 0
    private let outputLimit: Int
    /// Who the native KV state belongs to and the exact tokens it holds. `nil` whenever anything else
    /// (a stateless call, another session, an error, a trim) may have changed it: the next turn starts fresh.
    private var kv: (session: UUID, tokens: [Int])?
    /// Sessions that may still run turns. Unloading ends them all (session-length lease on the resources).
    private var openSessions: Set<UUID> = []
    nonisolated var cancellationForTesting: CoreMLCancellation { cancellation }

    public init(spec: CoreMLModelSpec, folder: URL, outputTokenLimit: Int = 1_024) {
        self.spec = spec; self.folder = folder; self.outputLimit = outputTokenLimit
        self.loader = { cancellation in
            try CoreMLInstaller.validateInstalled(folder: folder, spec: spec)
            return try await NativeCoreMLDriver.load(spec: spec, folder: folder, cancellation: cancellation)
        }
    }
    init(spec: CoreMLModelSpec, folder: URL, outputTokenLimit: Int = 1_024,
         loader: @escaping @Sendable (CoreMLCancellation) async throws -> any CoreMLDriving) {
        self.spec = spec; self.folder = folder; self.outputLimit = outputTokenLimit; self.loader = loader
    }
    public var availability: LLMAvailability {
        runtime != nil && releasing == nil ? .available : .unavailable(reason: "Prepare \(spec.displayName) in the foreground before cleanup.")
    }
    public func isPrepared() -> Bool { runtime != nil && releasing == nil }
    public func prepare() async throws {
        try Task.checkCancellation()
        guard releasing == nil else { throw LLMError.unavailable(reason: "Core ML resources are being released.") }
        if runtime != nil { return }
        let task: Task<any CoreMLDriving, any Error>
        let preparingEpoch = epoch
        let preparingSerial: Int
        if let preparation {
            task = preparation
            preparingSerial = loadSerial
        } else {
            loadSerial += 1
            preparingSerial = loadSerial
            try cancellation.begin()
            let loader = loader, cancellation = cancellation
            task = Task.detached {
                defer { cancellation.settle() }
                try Task.checkCancellation(); try cancellation.check()
                let driver = try await loader(cancellation)
                try Task.checkCancellation(); try cancellation.check()
                return driver
            }
            preparation = task
        }
        do {
            let driver = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: { [cancellation] in cancellation.cancel(); task.cancel() }
            try Task.checkCancellation(); try cancellation.check()
            guard epoch == preparingEpoch, releasing == nil else { throw CancellationError() }
            runtime = driver; preparation = nil
        } catch {
            if epoch == preparingEpoch, loadSerial == preparingSerial { preparation = nil }
            throw error
        }
    }
    public nonisolated func cancel() { cancellation.cancel() }
    public nonisolated func waitUntilSettled() async { await cancellation.waitUntilSettled() }
    public func unload() async {
        if let releasing { await releasing.value; return }
        epoch += 1
        let currentEpoch = epoch
        cancellation.cancel()
        let preparation = preparation, cancellation = cancellation
        let task = Task {
            preparation?.cancel()
            _ = await preparation?.result
            await cancellation.waitUntilSettled()
        }
        releasing = task
        openSessions.removeAll(); kv = nil
        await task.value
        if epoch == currentEpoch { runtime = nil; self.preparation = nil; releasing = nil }
    }
    public func prewarmResources() async throws { try await prepare() }
    public func releaseWarmResources() async { await unload() }
    public func respond(instructions: String, prompt: String) async throws -> String {
        try await respond(instructions: instructions, examples: [], prompt: prompt)
    }
    public func respond(instructions: String, examples: [LLMExample], prompt: String) async throws -> String {
        guard let runtime, releasing == nil else { throw LLMError.unavailable(reason: "Core ML resources are not prepared.") }
        try cancellation.begin()
        defer { cancellation.settle() }
        kv = nil  // A stateless generation replaces the native state.
        return try await withTaskCancellationHandler {
            try Task.checkCancellation(); try cancellation.check()
            let tokens = try await runtime.tokens(instructions: instructions, examples: examples, prompt: prompt)
            try CoreMLPrompt.validate(input: tokens.count, outputLimit: outputLimit, context: runtime.contextLength)
            try Task.checkCancellation(); try cancellation.check()
            let generated = try await runtime.generate(tokens: tokens, outputLimit: outputLimit)
            try Task.checkCancellation(); try cancellation.check()
            guard generated.stopReason == "eos_token" else { throw LLMError.failed("Core ML output was incomplete.") }
            guard !generated.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw LLMError.emptyResponse }
            return generated.text
        } onCancel: { [cancellation] in cancellation.cancel() }
    }

    // MARK: Sessions

    /// A persistent session over the prepared model: turn N prefills only the tokens turn N-1 did not leave
    /// in the native state. Never prepares or loads; unloading ends the session.
    public func makeSession() async throws -> any LLMSession {
        guard let runtime, releasing == nil else { throw LLMError.unavailable(reason: "Core ML resources are not prepared.") }
        let id = UUID()
        openSessions.insert(id)
        return CoreMLSession(backend: self, id: id, family: runtime.promptFamily,
                             tokenBudget: runtime.contextLength - outputLimit - 2)
    }

    func sessionRuntime(_ id: UUID) throws -> any CoreMLDriving {
        guard openSessions.contains(id) else { throw LLMSessionError.closed }
        guard let runtime, releasing == nil else { throw LLMError.unavailable(reason: "Core ML resources are not prepared.") }
        return runtime
    }

    /// One session turn over the full turn `tokens`, under the same single-worker guard as ``respond``.
    func sessionTurn(_ id: UUID, tokens: [Int]) async throws -> CoreMLGeneration {
        let runtime = try sessionRuntime(id)
        try CoreMLPrompt.validate(input: tokens.count, outputLimit: outputLimit, context: runtime.contextLength)
        try cancellation.begin()
        defer { cancellation.settle() }
        let reuse: Int
        if let kv, kv.session == id, kv.tokens.count < tokens.count, tokens.starts(with: kv.tokens) {
            // ANEMLL prefills full batches and the remainder one token per call, which costs far more per
            // token. Start up to a batch earlier, re-prefilling held positions with the same tokens, so the
            // new tokens fill whole batches.
            let batch = max(1, runtime.batchSize)
            let aligned = kv.tokens.count - (batch - (tokens.count - kv.tokens.count) % batch) % batch
            reuse = max(0, aligned)
        } else {
            reuse = 0  // Prefix mismatch, other owner or no state: a fresh native state.
        }
        kv = nil  // Until this generation settles successfully, the state is unknown.
        let limit = outputLimit
        let generated = try await withTaskCancellationHandler {
            try Task.checkCancellation(); try cancellation.check()
            let generated = try await runtime.generate(tokens: tokens, reusingPrefix: reuse, outputLimit: limit)
            try Task.checkCancellation(); try cancellation.check()
            return generated
        } onCancel: { [cancellation] in cancellation.cancel() }
        guard generated.stopReason == "eos_token" else { throw LLMError.failed("Core ML output was incomplete.") }
        if openSessions.contains(id) { kv = (id, tokens + generated.tokens) }
        return generated
    }

    func resetSession(_ id: UUID) { if kv?.session == id { kv = nil } }

    func closeSession(_ id: UUID) {
        openSessions.remove(id)
        resetSession(id)
    }
}

/// Install warm-up and cleanup resolution share the same owner. Entries are released only after native settlement.
public actor CoreMLModelStore {
    public static let shared = CoreMLModelStore()
    private struct PendingRelease {
        let token: UUID
        let task: Task<Void, Never>
    }
    private var backends: [String: CoreMLBackend] = [:]
    private var releases: [String: PendingRelease] = [:]
    private let makeBackend: @Sendable (CoreMLModelSpec, URL) -> CoreMLBackend
    public init() { self.makeBackend = { CoreMLBackend(spec: $0, folder: $1) } }
    init(makeBackend: @escaping @Sendable (CoreMLModelSpec, URL) -> CoreMLBackend) { self.makeBackend = makeBackend }

    public func backend(for spec: CoreMLModelSpec, root: URL) async -> CoreMLBackend {
        let folder = spec.folder(root: root).standardizedFileURL
        // Every release task includes its actor-cache cleanup before completing. Rechecking also joins
        // a later release that began while this acquisition was waiting for an earlier one.
        while let release = releases[folder.path] { await release.task.value }
        if let backend = backends[folder.path] { return backend }
        let backend = makeBackend(spec, folder)
        backends[folder.path] = backend
        return backend
    }
    public func release(folder: URL) async {
        let key = folder.standardizedFileURL.path
        if let release = releases[key] { await release.task.value; return }
        guard let backend = backends[key] else { return }
        let token = UUID()
        let task = Task { [self] in
            await backend.unload()
            finishRelease(key: key, backend: backend, token: token)
        }
        // Reserve this folder before yielding, so acquisition cannot borrow the retiring owner.
        releases[key] = PendingRelease(token: token, task: task)
        await task.value
    }
    private func finishRelease(key: String, backend: CoreMLBackend, token: UUID) {
        guard releases[key]?.token == token else { return }
        if backends[key] === backend { backends[key] = nil }
        releases[key] = nil
    }
    public func releaseAll() async {
        for key in Array(backends.keys) { await release(folder: URL(filePath: key)) }
    }
}
