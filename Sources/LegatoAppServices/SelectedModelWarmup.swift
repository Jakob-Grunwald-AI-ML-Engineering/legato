import Foundation
import LegatoCore

/// Retains requested resources independently of microphone capture and individual waiters.
public actor SelectedModelWarmup {
    public struct Resource: Sendable {
        public let key: String
        public let lifecycle: any ModelResourceLifecycle
        public init(key: String, lifecycle: any ModelResourceLifecycle) { self.key = key; self.lifecycle = lifecycle }
        public init(key: String, prewarm: @escaping @Sendable () async throws -> Void, release: @escaping @Sendable () async -> Void) {
            self.init(key: key, lifecycle: Operations(prewarm: prewarm, release: release))
        }
    }
    public enum Role: Sendable, Hashable { case dictation, refine, meetingSummary, legacy }
    public enum PreparationError: Error { case needsForeground, superseded }
    public struct Lease: Sendable {
        fileprivate let id: UUID
        fileprivate let owner: SelectedModelWarmup
        public func release() async { await owner.release(id) }
    }
    private struct Operations: ModelResourceLifecycle {
        let prewarm: @Sendable () async throws -> Void
        let release: @Sendable () async -> Void
        func prewarmResources() async throws { try await prewarm() }
        func releaseWarmResources() async { await release() }
    }
    private struct Entry {
        let token = UUID()
        let resource: Resource
        var ready = false
        var task: Task<Void, any Error>?
    }
    private var entries: [String: Entry] = [:]
    private var requests: [Role: Set<String>] = [:]
    private var leases: [UUID: Set<String>] = [:]
    private var releases: [String: Task<Void, Never>] = [:]
    private var pressureRelease: Task<Void, Never>?
    private var epoch = 0

    public init() {}
    public func isReady(for keys: Set<String>) -> Bool {
        keys.allSatisfy { entries[$0]?.ready == true }
    }

    /// Starts independent foreground preparations without waiting for the entire retained union.
    public func setRequested(_ resources: [Resource], for role: Role, inBackground: Bool) {
        update(resources, for: role)
        if !inBackground { for resource in resources { start(resource.key) } }
    }
    private func update(_ resources: [Resource], for role: Role) {
        requests[role] = Set(resources.map(\.key))
        for resource in resources where entries[resource.key] == nil { entries[resource.key] = Entry(resource: resource) }
        retireUnused()
    }

    /// Compatibility for callers selecting one complete resource set. Role-based callers prepare subsets.
    public func prepare(_ resources: [Resource], inBackground: Bool) async throws {
        let keys = Set(resources.map(\.key))
        if inBackground, keys.contains(where: { entries[$0]?.ready != true && entries[$0]?.task == nil }) {
            throw PreparationError.needsForeground
        }
        update(resources, for: .legacy)
        // A legacy selection switch keeps the old native-settlement-before-reload guarantee.
        let retired = Array(releases.values)
        for task in retired { await task.value }
        try Task.checkCancellation()
        try await prepare(keys: keys, inBackground: inBackground)
    }

    public func prepare(keys: Set<String>, inBackground: Bool) async throws {
        for key in keys {
            guard let entry = entries[key] else { throw PreparationError.superseded }
            if !entry.ready && entry.task == nil {
                guard !inBackground else { throw PreparationError.needsForeground }
                start(key)
            }
        }
        for key in keys {
            guard let entry = entries[key] else { throw PreparationError.superseded }
            let token = entry.token
            if let task = entry.task { try await Self.waitForPreparation(task).get() }
            guard let current = entries[key], current.token == token, current.ready else { throw PreparationError.superseded }
            try Task.checkCancellation()
        }
    }

    /// A lease pins the admitted identities through the caller's entire operation, including summary merges.
    public func acquire(keys: Set<String>, inBackground: Bool) async throws -> Lease {
        guard keys.allSatisfy({ entries[$0] != nil }) else { throw PreparationError.needsForeground }
        let id = UUID()
        leases[id] = keys
        do {
            try await prepare(keys: keys, inBackground: inBackground)
            return Lease(id: id, owner: self)
        } catch {
            await release(id)
            throw error
        }
    }
    private func release(_ id: UUID) async {
        guard let keys = leases.removeValue(forKey: id) else { return }
        retireUnused()
        let retired = keys.compactMap { entries[$0] == nil ? releases[$0] : nil }
        for task in retired { await task.value }
    }

    private func start(_ key: String) {
        guard let entry = entries[key], !entry.ready, entry.task == nil else { return }
        let resource = entry.resource, token = entry.token
        let releaseBefore = releases[key], pressureBefore = pressureRelease
        entries[key]?.task = Task {
            await pressureBefore?.value
            await releaseBefore?.value
            do {
                try Task.checkCancellation()
                try await resource.lifecycle.prewarmResources()
                try Task.checkCancellation()
                if self.entries[key]?.token == token {
                    self.entries[key]?.ready = true
                    self.entries[key]?.task = nil
                }
            } catch {
                if self.entries[key]?.token == token { self.entries[key]?.task = nil }
                throw error
            }
        }
    }
    private func retireUnused() {
        let retained = requests.values.reduce(into: Set<String>()) { $0.formUnion($1) }
            .union(leases.values.reduce(into: Set<String>()) { $0.formUnion($1) })
        for key in entries.keys.filter({ !retained.contains($0) }) {
            guard let entry = entries.removeValue(forKey: key) else { continue }
            retire(key, entry: entry)
        }
    }
    private func retire(_ key: String, entry: Entry) {
        entry.task?.cancel()
        let previous = releases[key]
        releases[key] = Task {
            await previous?.value
            _ = await entry.task?.result
            await entry.resource.lifecycle.releaseWarmResources()
        }
    }
    private nonisolated static func waitForPreparation(_ task: Task<Void, any Error>) async throws -> Result<Void, any Error> {
        let (stream, continuation) = AsyncStream<Result<Void, any Error>>.makeStream(bufferingPolicy: .bufferingNewest(1))
        Task { continuation.yield(await task.result); continuation.finish() }
        var iterator = stream.makeAsyncIterator()
        guard let result = await iterator.next() else { throw CancellationError() }
        try Task.checkCancellation()
        return result
    }

    /// Deletion or an invalid install receipt revokes this identity without disturbing other resources.
    public func revoke(key: String) {
        guard let entry = entries.removeValue(forKey: key) else { return }
        retire(key, entry: entry)
        entries[key] = Entry(resource: entry.resource)
    }

    /// Revoke all readiness synchronously, then cancel/join preparation and native release.
    public func invalidate() async {
        epoch += 1
        let admitted = epoch
        let previous = pressureRelease
        let old = entries
        entries = [:]; requests = [:]; leases = [:]
        for (key, entry) in old { retire(key, entry: entry) }
        let pending = Array(releases.values)
        let task = Task { await previous?.value; for release in pending { await release.value } }
        pressureRelease = task
        await task.value
        if epoch == admitted { pressureRelease = nil }
    }
}
