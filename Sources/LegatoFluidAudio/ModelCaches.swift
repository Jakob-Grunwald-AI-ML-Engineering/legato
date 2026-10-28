import FluidAudio
import Foundation
import LegatoCore
import LegatoModels

/// Keeps the selected live weights independently of incidental meeting-model LRU activity. Loaded
/// objects are never reset or cleaned up by this owner; per-run decoding remains with the engine.
actor SelectedSpeechModelCache<Model: Sendable> {
    private let cache: RecentModelCache<Model>
    private var selected: (folder: String, model: Model)?
    nonisolated let capacity: Int
    init(capacity: Int = 1) { self.capacity = capacity; cache = RecentModelCache(capacity: capacity) }
    func model(at folder: URL, load: @escaping @Sendable () async throws -> Model) async throws -> Model {
        if let selected, selected.folder == folder.standardizedFileURL.path { return selected.model }
        return try await cache.model(at: folder, load: load)
    }
    func retainSelected(_ model: Model, at folder: URL) { selected = (folder.standardizedFileURL.path, model) }
    func clearSelected() { selected = nil }
    func evict(folder: URL) async {
        if selected?.folder == folder.standardizedFileURL.path { selected = nil }
        await cache.evict(folder: folder)
    }
    func evictAll() async { selected = nil; await cache.evictAll() }
    func evictUnselected(exceptFolder: URL?) async {
        let keeping = exceptFolder?.standardizedFileURL.path
        // An incidental caller can hold an older selection snapshot across suspension. Only the
        // selection owner clears a pin; meeting maintenance always preserves the current one too.
        for folder in await cache.residentFolders where folder != keeping && folder != selected?.folder {
            await cache.evict(folder: URL(fileURLWithPath: folder))
        }
    }
}

/// Selected Nemotron weights plus a one-folder cache for incidental meeting use.
actor NemotronModelCache {
    static let shared = NemotronModelCache()

    private let cache = SelectedSpeechModelCache<SharedNemotronMultilingualModels>(capacity: 1)

    nonisolated var capacity: Int { cache.capacity }

    func models(at folder: URL) async throws -> SharedNemotronMultilingualModels {
        try await cache.model(at: folder) {
            try await StreamingNemotronMultilingualAsrManager.preloadShared(
                from: folder, configuration: FluidAudioCompute.configuration())
        }
    }

    func evict(folder: URL) async { await cache.evict(folder: folder) }
    func evictAll() async { await cache.evictAll() }
    func pin(at folder: URL) async throws { await cache.retainSelected(try await models(at: folder), at: folder) }
    func clearSelected() async { await cache.clearSelected() }
    func evictUnselected(exceptFolder: URL?) async { await cache.evictUnselected(exceptFolder: exceptFolder) }
}

/// The loaded Parakeet EOU manager, shared by every engine instance (the registry builds a new engine per
/// call). One live session runs at a time, and `prepare` resets the manager before it starts one. Evicting
/// only drops the cache's reference, so a session still using the manager is not cut short.
actor EouModelCache {
    static let shared = EouModelCache()

    private let cache = SelectedSpeechModelCache<StreamingEouAsrManager>(capacity: 1)

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
    func pin(at folder: URL, chunk: EouChunk) async throws {
        await cache.retainSelected(try await manager(at: folder, chunk: chunk), at: folder)
    }
    func clearSelected() async { await cache.clearSelected() }
    func evictUnselected(exceptFolder: URL?) async { await cache.evictUnselected(exceptFolder: exceptFolder) }
}

extension FluidAudioModels {
    /// Prepares only installed selected live weights. No decoder reset, callback change or microphone
    /// operation occurs here; a later engine prepare owns those per-run operations.
    public static func prewarmSelected(id: String, root: URL) async throws {
        try Task.checkCancellation()
        guard let installer = installers[id], descriptors.contains(where: { $0.id == id && $0.kind == .speechStreaming }) else {
            throw ModelError.unknownModel(id)
        }
        guard await installer.isInstalled(root: root) else { throw DictationError.assetsNotInstalled }
        let folder = installer.installFolder(root: root)
        if installer is NemotronInstaller {
            try await NemotronModelCache.shared.pin(at: folder)
            try Task.checkCancellation()
            await EouModelCache.shared.clearSelected()
        } else if let eou = installer as? ParakeetEouInstaller {
            try await EouModelCache.shared.pin(at: folder, chunk: eou.chunk)
            try Task.checkCancellation()
            await NemotronModelCache.shared.clearSelected()
        }
        try Task.checkCancellation()
        await releaseUnselected(exceptFolder: folder)
    }

    /// Meeting maintenance relinquishes incidental model references while preserving selected live
    /// weights. This never calls a live manager's reset/cleanup or cuts short an active consumer.
    public static func releaseUnselected(exceptFolder: URL?) async {
        await NemotronModelCache.shared.evictUnselected(exceptFolder: exceptFolder)
        await EouModelCache.shared.evictUnselected(exceptFolder: exceptFolder)
    }

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
