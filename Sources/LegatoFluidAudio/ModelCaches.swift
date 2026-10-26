import FluidAudio
import Foundation
import LegatoModels

/// Nemotron models, one tier at a time (about 1 GB resident each).
actor NemotronModelCache {
    static let shared = NemotronModelCache()

    private let cache = RecentModelCache<SharedNemotronMultilingualModels>(capacity: 1)

    nonisolated var capacity: Int { cache.capacity }

    func models(at folder: URL) async throws -> SharedNemotronMultilingualModels {
        try await cache.model(at: folder) {
            try await StreamingNemotronMultilingualAsrManager.preloadShared(
                from: folder, configuration: FluidAudioCompute.configuration())
        }
    }

    func evict(folder: URL) async { await cache.evict(folder: folder) }
    func evictAll() async { await cache.evictAll() }
}

/// The loaded Parakeet EOU manager, shared by every engine instance (the registry builds a new engine per
/// call). One live session runs at a time, and `prepare` resets the manager before it starts one. Evicting
/// only drops the cache's reference, so a session still using the manager is not cut short.
actor EouModelCache {
    static let shared = EouModelCache()

    private let cache = RecentModelCache<StreamingEouAsrManager>(capacity: 1)

    nonisolated var capacity: Int { cache.capacity }

    func manager(at folder: URL, chunk: EouChunk) async throws -> StreamingEouAsrManager {
        try await cache.model(at: folder) {
            let manager = StreamingEouAsrManager(
                configuration: FluidAudioCompute.configuration(), chunkSize: chunk.chunkSize)
            try await manager.loadModels(from: folder)
            return manager
        }
    }

    func evict(folder: URL) async { await cache.evict(folder: folder) }
    func evictAll() async { await cache.evictAll() }
}

extension FluidAudioModels {
    /// Lets go of the loaded models of `folder`. Pass it as the model manager's `onDelete` (as
    /// ``FluidAudioCatalog``'s manager does) so deleting a model also frees its memory.
    public static func release(folder: URL) async {
        await NemotronModelCache.shared.evict(folder: folder)
        await EouModelCache.shared.evict(folder: folder)
    }
}

/// Releases every cached speech model (about 1 GB resident for Nemotron), for example on a memory warning.
public func releaseCachedNemotronModels() async {
    await NemotronModelCache.shared.evictAll()
    await EouModelCache.shared.evictAll()
}
