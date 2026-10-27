import Foundation
import LegatoCore
import LegatoAppServices

/// The actual ANEMLL worker boundary; tests substitute resource operations, never model inference.
public protocol ParityRuntime: LLMBackend {
    func prepare() async throws
    func isLoaded() async -> Bool
    func cancel() async
    func waitUntilSettled() async
    func unload() async throws
}
public enum ParityPreparationError: Error { case needsForeground, busy, cancelled }
public enum ParityBootstrap {
    public static let revision = "0977a61d00e39118aab5ed1e510f1d228df5eefd"
    public static let modelDirectory = "Models/qwen3-1.7b"
    public static func apply(defaults: UserDefaults) {
        let marker = "aneParity.bootstrapVersion"
        guard defaults.integer(forKey: marker) < 1 else { return }
        let settings = CleanupSettingsStore(defaults: defaults)
        settings.enabled = true
        settings.delivery = .replace
        settings.style = .verbatim
        settings.timeoutSeconds = 4
        defaults.set(1, forKey: marker)
    }
}

/// Retains only weights. Microphone ownership and expiry remain entirely with DictationCoordinator.
public actor ParityModelOwner: LLMBackend {
    public nonisolated let id = "anemll-coreml"
    public nonisolated let maxPromptCharacters: Int? = nil
    private let runtime: any ParityRuntime
    private var resetting = false
    private var preparing = false
    private var invoking = false
    private var epoch = 0
    private var settlementWaiters: [CheckedContinuation<Void, Never>] = []
    public init(runtime: any ParityRuntime) { self.runtime = runtime }
    public var availability: LLMAvailability {
        get async {
            let admittedEpoch = epoch
            let loaded = await runtime.isLoaded()
            guard !resetting, !preparing, admittedEpoch == epoch, loaded else {
                return .unavailable(reason: "Foreground model preparation is required")
            }
            let availability = await runtime.availability
            guard !resetting, !preparing, admittedEpoch == epoch else {
                return .unavailable(reason: "The model was reset")
            }
            return availability
        }
    }
    public func prepare(inBackground: Bool) async throws {
        guard !resetting, !preparing else { throw ParityPreparationError.busy }
        preparing = true
        defer { preparing = false; signalSettlement() }
        let admittedEpoch = epoch
        let loaded = await runtime.isLoaded()
        guard !resetting, admittedEpoch == epoch else { throw ParityPreparationError.cancelled }
        if inBackground, !loaded { throw ParityPreparationError.needsForeground }
        // A timed-out response may still be settling. Do not reuse its KV state or load over it.
        await runtime.waitUntilSettled()
        try Task.checkCancellation()
        guard !resetting, admittedEpoch == epoch else { throw ParityPreparationError.cancelled }
        let stillLoaded = await runtime.isLoaded()
        guard !resetting, admittedEpoch == epoch else { throw ParityPreparationError.cancelled }
        if stillLoaded { return }
        guard !inBackground else { throw ParityPreparationError.needsForeground }
        try await runtime.prepare()
        try Task.checkCancellation()
        guard !resetting, admittedEpoch == epoch else { throw ParityPreparationError.cancelled }
    }
    public func reset() async throws {
        guard !resetting else { throw ParityPreparationError.busy }
        resetting = true; epoch += 1
        defer { resetting = false }
        await runtime.cancel()
        // Also join owner calls queued before cancellation: their runtime task may not have begun yet.
        if preparing || invoking {
            await withCheckedContinuation { settlementWaiters.append($0) }
        }
        await runtime.waitUntilSettled()
        try await runtime.unload()
    }
    public func respond(instructions: String, prompt: String) async throws -> String {
        try await respond(instructions: instructions, examples: [], prompt: prompt)
    }
    public func respond(instructions: String, examples: [LLMExample], prompt: String) async throws -> String {
        guard !resetting, !preparing, !invoking else {
            throw LLMError.unavailable(reason: "The prepared ANEMLL worker is not available")
        }
        let admittedEpoch = epoch
        let loaded = await runtime.isLoaded()
        guard loaded, !resetting, !preparing, !invoking, admittedEpoch == epoch else {
            throw LLMError.unavailable(reason: "The prepared ANEMLL worker changed during admission")
        }
        invoking = true
        defer { invoking = false; signalSettlement() }
        return try await runtime.respond(instructions: instructions, examples: examples, prompt: prompt)
    }
    private func signalSettlement() {
        guard !preparing, !invoking else { return }
        let waiting = settlementWaiters; settlementWaiters = []
        for continuation in waiting { continuation.resume() }
    }
}

/// Reserves new-start admission across asynchronous model preparation. Stop never waits on this gate.
@MainActor public final class ParityAdmission {
    private var pendingID: UUID?
    private var cancelPending: (() -> Void)?
    public init() {}
    public private(set) var isResetting = false
    public var isPreparing: Bool { pendingID != nil || isResetting }
    public func reset(operation: @MainActor () async -> Void) async {
        guard !isResetting else { return }
        isResetting = true
        cancel()
        defer { isResetting = false }
        await operation()
    }
    public func cancel() { cancelPending?() }
    public func stop<Value>(operation: @MainActor () async -> Value) async -> Value {
        cancel()
        return await operation()
    }
    public func admit<Value: Sendable>(
        isIdle: @escaping @MainActor () -> Bool,
        canStart: @escaping @MainActor () -> Bool = { true },
        prepare: @escaping @MainActor () async throws -> Void,
        operation: @escaping @MainActor () async -> Value
    ) async throws -> Value {
        guard pendingID == nil, !isResetting, isIdle(), canStart() else { throw ParityPreparationError.busy }
        let id = UUID(); pendingID = id
        let task = Task { @MainActor in
            try await prepare()
            try Task.checkCancellation()
            guard isIdle(), canStart() else { throw ParityPreparationError.busy }
            let value = await operation()
            try Task.checkCancellation()
            return value
        }
        cancelPending = { task.cancel() }
        defer { if pendingID == id { pendingID = nil; cancelPending = nil } }
        return try await task.value
    }
}
