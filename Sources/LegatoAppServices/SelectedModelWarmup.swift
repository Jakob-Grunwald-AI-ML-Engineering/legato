import Foundation
import LegatoCore

/// Owns only selected model resources, independently of audio capture and its lease.
public actor SelectedModelWarmup {
    public struct Resource: Sendable {
        public let key: String
        public let lifecycle: any ModelResourceLifecycle
        public init(key: String, lifecycle: any ModelResourceLifecycle) {
            self.key = key
            self.lifecycle = lifecycle
        }

        public init(
            key: String, prewarm: @escaping @Sendable () async throws -> Void,
            release: @escaping @Sendable () async -> Void
        ) {
            self.init(key: key, lifecycle: Operations(prewarm: prewarm, release: release))
        }
    }

    public enum PreparationError: Error { case needsForeground, superseded }
    private struct Operations: ModelResourceLifecycle {
        let prewarm: @Sendable () async throws -> Void
        let release: @Sendable () async -> Void
        func prewarmResources() async throws { try await prewarm() }
        func releaseWarmResources() async { await release() }
    }
    private struct Pending {
        let generation: Int
        let keys: Set<String>
        let task: Task<Void, any Error>
    }

    private var generation = 0
    private var selected: [String: Resource] = [:]
    private var ready: Set<String> = []
    private var pending: Pending?
    private var releasing: Task<Void, Never>?

    public init() {}
    public func isReady(for keys: Set<String>) -> Bool {
        pending == nil && releasing == nil && Set(selected.keys) == keys && ready == keys
    }

    /// A stable key identifies the resources of a model and its configuration, not a dictation run.
    /// Only foreground callers may begin cold preparation. A background caller can join preparation
    /// already admitted in the foreground or reuse resources that are ready.
    public func prepare(_ resources: [Resource], inBackground: Bool) async throws {
        let next = Dictionary(resources.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        let keys = Set(next.keys)
        if isReady(for: keys) { return }
        let operation: Pending
        if let pending, pending.keys == keys {
            operation = pending
        } else {
            guard !inBackground else { throw PreparationError.needsForeground }
            generation += 1
            let admitted = generation
            let previous = pending?.task
            previous?.cancel()
            let releaseBefore = releasing
            let retired = selected.values.filter { !keys.contains($0.key) }
            let reusable = ready.intersection(keys)
            selected = next
            ready = []
            releasing = nil
            let task = Task {
                // Cancellation never permits loading over an older in-flight preparation or release.
                await releaseBefore?.value
                _ = await previous?.result
                for resource in retired { await resource.lifecycle.releaseWarmResources() }
                try Task.checkCancellation()
                for resource in resources where !reusable.contains(resource.key) {
                    try Task.checkCancellation()
                    try await resource.lifecycle.prewarmResources()
                }
                try Task.checkCancellation()
            }
            operation = Pending(generation: admitted, keys: keys, task: task)
            pending = operation
        }
        // Waiting is cancellable even when native preparation is not. A cancelled waiter must
        // leave the shared load and its readiness bookkeeping available to the next admission.
        let result = try await Self.waitForPreparation(operation.task)
        do {
            try result.get()
            guard generation == operation.generation else { throw PreparationError.superseded }
            // Every waiter may publish the same completed generation; none may publish an older one.
            pending = nil
            ready = keys
        } catch {
            if generation == operation.generation { pending = nil; ready = [] }
            throw error
        }
        // Cancellation belongs to this waiter, not the shared resource load that completed. In
        // particular it must not clear readiness another waiter has already observed.
        try Task.checkCancellation()
    }

    private nonisolated static func waitForPreparation(_ task: Task<Void, any Error>) async throws -> Result<Void, any Error> {
        let (stream, continuation) = AsyncStream<Result<Void, any Error>>.makeStream(bufferingPolicy: .bufferingNewest(1))
        Task {
            continuation.yield(await task.result)
            continuation.finish()
        }
        var iterator = stream.makeAsyncIterator()
        guard let result = await iterator.next() else { throw CancellationError() }
        try Task.checkCancellation()
        return result
    }

    /// Revokes readiness before suspension, then joins preparation before relinquishing resources.
    /// Resource implementations own native-settlement details; MLX only relinquishes cache references.
    public func invalidate() async {
        generation += 1
        let admitted = generation
        ready = []
        let previous = pending?.task
        previous?.cancel()
        let releaseBefore = releasing
        let retired = Array(selected.values)
        pending = nil
        selected = [:]
        let release = Task {
            await releaseBefore?.value
            _ = await previous?.result
            for resource in retired { await resource.lifecycle.releaseWarmResources() }
        }
        releasing = release
        await release.value
        if generation == admitted { releasing = nil }
    }
}
