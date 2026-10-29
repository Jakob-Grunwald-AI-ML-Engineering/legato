import Foundation
import LegatoCore

/// Retains requested resources independently of microphone capture and individual waiters.
public actor SelectedModelWarmup {
    public enum State: Sendable, Equatable {
        case idle, preparing, ready, failed(String)
    }
    public struct Resource: Sendable {
        public let key: String
        public let lifecycle: any ModelResourceLifecycle
        /// The resource's rolling language-model session, if it has one (see ``rollingSession(key:)``).
        public let session: SessionSource?
        public init(key: String, lifecycle: any ModelResourceLifecycle, session: SessionSource? = nil) {
            self.key = key; self.lifecycle = lifecycle; self.session = session
        }
        public init(key: String, prewarm: @escaping @Sendable () async throws -> Void, release: @escaping @Sendable () async -> Void,
                    session: SessionSource? = nil) {
            self.init(key: key, lifecycle: Operations(prewarm: prewarm, release: release), session: session)
        }
    }
    /// How a prepared resource opens its rolling session: `make` over the prepared model (never loading it),
    /// then the `head` (instructions and examples) appended and prefilled.
    public struct SessionSource: Sendable {
        public let head: @Sendable () async -> [LLMSessionChunk]
        public let make: @Sendable () async throws -> any LLMSession
        public init(head: @escaping @Sendable () async -> [LLMSessionChunk], make: @escaping @Sendable () async throws -> any LLMSession) {
            self.head = head; self.make = make
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
        var failure: (any Error)?
        /// Opens the rolling session once the resource is ready; its value is the session (nil: none).
        var session: Task<(any LLMSession)?, Never>?
    }
    private var entries: [String: Entry] = [:]
    private var requests: [Role: Set<String>] = [:]
    private var leases: [UUID: Set<String>] = [:]
    private var releases: [String: Task<Void, Never>] = [:]
    private var pressureRelease: Task<Void, Never>?
    private var epoch = 0

    public init() {}
    public func state(for key: String) -> State {
        guard let entry = entries[key] else { return .idle }
        if entry.ready { return .ready }
        if let failure = entry.failure { return .failed(String(describing: failure)) }
        return entry.task == nil ? .idle : .preparing
    }
    /// A deliberate retry clears a failed attempt; reconciliation and reads never do.
    public func retry(keys: Set<String>, inBackground: Bool) {
        guard !inBackground else { return }
        for key in keys where entries[key]?.failure != nil {
            entries[key]?.failure = nil
            start(key)
        }
    }
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
        // Calling this compatibility API is an explicit preparation/retry request.
        retry(keys: keys, inBackground: inBackground)
        // A legacy selection switch keeps the old native-settlement-before-reload guarantee.
        let retired = Array(releases.values)
        for task in retired { await task.value }
        try Task.checkCancellation()
        try await prepare(keys: keys, inBackground: inBackground)
    }

    public func prepare(keys: Set<String>, inBackground: Bool) async throws {
        for key in keys {
            guard let entry = entries[key] else { throw PreparationError.superseded }
            if let failure = entry.failure { throw failure }
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
            // A waiter never admitted to the operation need not join native retirement.
            // retireUnused keeps that cleanup tracked and gates a later load on its settlement.
            leases.removeValue(forKey: id)
            retireUnused()
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
        guard let entry = entries[key], !entry.ready, entry.task == nil, entry.failure == nil else { return }
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
                    self.openSession(key)
                }
            } catch {
                if self.entries[key]?.token == token {
                    self.entries[key]?.task = nil
                    if !(error is CancellationError) { self.entries[key]?.failure = error }
                }
                throw error
            }
        }
    }
    // MARK: Rolling session

    /// The one rolling session of a prepared resource, warm (its head prefilled) and kept for the app's
    /// lifetime: every run appends to it and it scrolls by ``LLMSession/trim(keepingSuffix:)`` at the budget.
    /// Runs neither open nor close it; the entry owns it, so it ends only when the resource is released
    /// (memory pressure, a model change or deletion, teardown) and a later preparation opens a new one.
    /// Nil when the resource is not ready, has no session, or opening it failed (the next call retries).
    public func rollingSession(key: String) async -> (any LLMSession)? {
        guard let entry = entries[key], entry.ready, entry.resource.session != nil else { return nil }
        if entry.session == nil { openSession(key) }
        guard let task = entries[key]?.session else { return nil }
        let token = entry.token
        let session = await task.value
        guard entries[key]?.token == token else { return nil }  // released meanwhile
        if session == nil, entries[key]?.session == task { entries[key]?.session = nil }  // retry next time
        return session
    }

    private func openSession(_ key: String) {
        guard let entry = entries[key], entry.ready, entry.session == nil, let source = entry.resource.session else { return }
        entries[key]?.session = Task {
            guard let session = try? await source.make() else { return nil }
            do {
                for chunk in await source.head() { try await session.append(chunk) }
                try await session.warm()
                return session
            } catch {
                await session.close()
                return nil
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
            await entry.session?.value?.close()
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
