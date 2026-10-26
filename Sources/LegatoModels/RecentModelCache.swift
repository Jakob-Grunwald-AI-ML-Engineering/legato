import Foundation

/// Loaded models keyed by model folder, shared across sessions and engine instances, so only the first
/// request per folder pays the load. Keeps at most `capacity` folders (one by default): asking for another
/// folder releases the least recently used one, because a loaded speech model holds about a gigabyte.
///
/// A model that is still in use keeps working after it leaves the cache; the cache just stops holding it.
public actor RecentModelCache<Model: Sendable> {
    private var loads: [String: Task<Model, any Error>] = [:]
    /// Resident folder keys, least recently used first.
    private var recency: [String] = []
    public nonisolated let capacity: Int
    private let onEvict: (@Sendable (Model) async -> Void)?

    /// - Parameter onEvict: called with a model the cache let go of, for example to free its buffers.
    public init(capacity: Int = 1, onEvict: (@Sendable (Model) async -> Void)? = nil) {
        self.capacity = max(capacity, 1)
        self.onEvict = onEvict
    }

    /// The folders held now, least recently used first.
    public var residentFolders: [String] { recency }

    /// The model for `folder`: the cached one, one still loading, or a fresh `load()`. A failed or
    /// cancelled load is not cached.
    public func model(at folder: URL, load: @escaping @Sendable () async throws -> Model) async throws -> Model {
        let key = Self.key(folder)
        if let existing = loads[key] {
            touch(key)
            return try await existing.value
        }
        let task = Task { try await load() }
        loads[key] = task
        touch(key)
        while recency.count > capacity, let oldest = recency.first, oldest != key {
            release(oldest)
        }
        do {
            return try await task.value
        } catch {
            if loads[key] == task {
                loads[key] = nil
                recency.removeAll { $0 == key }
            }
            throw error
        }
    }

    /// Releases the model of `folder`, if held (for example after its files were deleted).
    public func evict(folder: URL) {
        release(Self.key(folder))
    }

    /// Releases every model, for example on a memory warning.
    public func evictAll() {
        for key in recency { release(key) }
    }

    private func release(_ key: String) {
        recency.removeAll { $0 == key }
        guard let task = loads.removeValue(forKey: key), let onEvict else { return }
        Task {
            if let model = try? await task.value { await onEvict(model) }
        }
    }

    private func touch(_ key: String) {
        recency.removeAll { $0 == key }
        recency.append(key)
    }

    private static func key(_ folder: URL) -> String { folder.standardizedFileURL.path }
}
