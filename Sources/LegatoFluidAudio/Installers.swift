import CoreML
import FluidAudio
import Foundation
import LegatoModels

/// Which Nemotron vocabulary a tier ships: the full multilingual one or the Latin-script-pruned one.
public enum NemotronVariant: String, Sendable, CaseIterable {
    case multilingual
    case latin

    /// The language hint FluidAudio maps to this variant's folder (`languageDirectory(for:)`).
    var languageHint: String {
        switch self {
        case .multilingual: "auto"
        case .latin: "en"
        }
    }
}

/// The Parakeet EOU chunk sizes Legato offers.
public enum EouChunk: Int, Sendable, CaseIterable {
    case ms160 = 160
    case ms320 = 320

    var repo: Repo {
        switch self {
        case .ms160: .parakeetEou160
        case .ms320: .parakeetEou320
        }
    }

    var chunkSize: StreamingChunkSize {
        switch self {
        case .ms160: .ms160
        case .ms320: .ms320
        }
    }
}

/// The Parakeet batch models Legato offers.
public enum ParakeetBatchModel: Sendable, CaseIterable {
    case v3
    case ultra

    var repo: Repo {
        switch self {
        case .v3: .parakeetV3
        case .ultra: .parakeetUltra
        }
    }

    var version: AsrModelVersion {
        switch self {
        case .v3: .v3
        case .ultra: .ultra
        }
    }
}

/// Compute settings every Legato FluidAudio model uses: the Neural Engine (Nemotron requires it).
enum FluidAudioCompute {
    static func configuration() -> MLModelConfiguration {
        MLModelConfigurationUtils.defaultConfiguration(computeUnits: .cpuAndNeuralEngine)
    }
}

private func exists(_ url: URL) -> Bool {
    FileManager.default.fileExists(atPath: url.path)
}

/// Whether `folder` still holds a download in flight: FluidAudio stages each file as `<name>.partial`
/// (plus `<name>.partial.etag`) and renames it when complete.
func hasPartialFiles(in folder: URL) -> Bool {
    guard let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil) else { return false }
    for case let url as URL in walker where url.lastPathComponent.hasSuffix(".partial")
        || url.lastPathComponent.hasSuffix(".partial.etag") {
        return true
    }
    return false
}

/// Every entry of `required` exists in `folder` and no download is still staged there.
private func isComplete(_ folder: URL, required: some Sequence<String>) -> Bool {
    required.allSatisfy { exists(folder.appendingPathComponent($0)) } && !hasPartialFiles(in: folder)
}

private func progressHandler(_ progress: @escaping @Sendable (Double) -> Void) -> ProgressHandler {
    { progress($0.fractionCompleted) }
}

// MARK: Nemotron

/// One Nemotron tier: `<root>/nemotron-multilingual/<latin|multilingual>/<chunk>ms`, one folder per tier.
public struct NemotronInstaller: ModelInstaller {
    public static let supportedChunks = [560, 1120, 2240]

    public let variant: NemotronVariant
    public let chunkMs: Int

    public init(variant: NemotronVariant, chunkMs: Int) {
        self.variant = variant
        self.chunkMs = chunkMs
    }

    public func installFolder(root: URL) -> URL {
        root.appendingPathComponent(Repo.nemotronMultilingual.folderName, isDirectory: true)
            .appendingPathComponent(variant.rawValue, isDirectory: true)
            .appendingPathComponent("\(chunkMs)ms", isDirectory: true)
    }

    public func isInstalled(root: URL) async -> Bool {
        isComplete(installFolder(root: root), required: [
            ModelNames.NemotronMultilingualStreaming.metadata,
            ModelNames.NemotronMultilingualStreaming.tokenizer,
            ModelNames.NemotronMultilingualStreaming.preprocessorFile,
            ModelNames.NemotronMultilingualStreaming.encoderFile,
            ModelNames.NemotronMultilingualStreaming.decoderFile,
            ModelNames.NemotronMultilingualStreaming.jointFile,
        ])
    }

    public func install(root: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        FluidAudioModels.pinRevisions()
        _ = try await StreamingNemotronMultilingualAsrManager.downloadVariant(
            languageCode: variant.languageHint,
            chunkMs: chunkMs,
            to: root,
            progressHandler: progressHandler(progress))
    }

    /// Loads through the same cache the live engine uses, so install-time preparation is retained.
    public func warm(root: URL) async throws {
        _ = try await NemotronModelCache.shared.models(at: installFolder(root: root))
    }
}

// MARK: Parakeet EOU

/// Parakeet EOU: `<root>/parakeet-eou-streaming/<chunk>ms`.
public struct ParakeetEouInstaller: ModelInstaller {
    public let chunk: EouChunk

    public init(chunk: EouChunk) {
        self.chunk = chunk
    }

    public func installFolder(root: URL) -> URL {
        root.appendingPathComponent(chunk.repo.folderName, isDirectory: true)
    }

    public func isInstalled(root: URL) async -> Bool {
        isComplete(installFolder(root: root), required: ModelNames.ParakeetEOU.requiredModels)
    }

    public func install(root: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        FluidAudioModels.pinRevisions()
        try await ModelHub.download(
            chunk.repo,
            to: root,
            additionalModelNames: ModelNames.ParakeetEOU.requiredModels,
            progressHandler: progressHandler(progress))
    }

    public func warm(root: URL) async throws {
        _ = try await EouModelCache.shared.manager(at: installFolder(root: root), chunk: chunk)
    }
}

// MARK: Parakeet batch

/// Parakeet v3 / Ultra: `<root>/<repo folder>`. `AsrModels` writes to the parent of the directory it is given.
public struct ParakeetBatchInstaller: ModelInstaller {
    public let model: ParakeetBatchModel

    public init(model: ParakeetBatchModel) {
        self.model = model
    }

    public func installFolder(root: URL) -> URL {
        root.appendingPathComponent(model.repo.folderName, isDirectory: true)
    }

    public func isInstalled(root: URL) async -> Bool {
        let folder = installFolder(root: root)
        return AsrModels.modelsExist(at: folder, version: model.version) && !hasPartialFiles(in: folder)
    }

    public func install(root: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        FluidAudioModels.pinRevisions()
        try await AsrModels.download(
            to: installFolder(root: root), version: model.version, progressHandler: progressHandler(progress))
    }

    public func warm(root: URL) async throws {
        _ = try await AsrModels.load(
            from: installFolder(root: root),
            configuration: FluidAudioCompute.configuration(),
            version: model.version)
    }
}

// MARK: Speakers and enhancement

/// Sortformer (live speakers): `<root>/diar-streaming-sortformer-coreml`, only the palettized streaming bundle.
public struct SortformerInstaller: ModelInstaller {
    public init() {}

    /// The bundle path inside the repository folder, which is also the download's variant key.
    static var bundle: String {
        ModelNames.Sortformer.bundle(for: FluidSortformerBackend.config) ?? ModelNames.Sortformer.defaultBundle
    }

    public func installFolder(root: URL) -> URL {
        root.appendingPathComponent(Repo.sortformer.folderName, isDirectory: true)
    }

    public func isInstalled(root: URL) async -> Bool {
        let folder = installFolder(root: root)
        return exists(folder.appendingPathComponent(Self.bundle)) && !hasPartialFiles(in: folder)
    }

    public func install(root: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        FluidAudioModels.pinRevisions()
        try await ModelHub.download(.sortformer, to: root, variant: Self.bundle, progressHandler: progressHandler(progress))
    }

    /// Loads the model once so CoreML compiles it for the Neural Engine; the compiled result is cached by the OS.
    public func warm(root: URL) async throws {
        _ = try await FluidSortformerBackend.load(root: root)
    }
}

/// The offline diarizer (speakers after meetings): `<root>/speaker-diarization-coreml`, the offline model set.
public struct OfflineDiarizerInstaller: ModelInstaller {
    public init() {}

    public func installFolder(root: URL) -> URL {
        root.appendingPathComponent(Repo.diarizer.folderName, isDirectory: true)
    }

    public func isInstalled(root: URL) async -> Bool {
        isComplete(installFolder(root: root), required: ModelNames.OfflineDiarizer.requiredModels)
    }

    public func install(root: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        FluidAudioModels.pinRevisions()
        try await ModelHub.download(.diarizer, to: root, variant: "offline", progressHandler: progressHandler(progress))
    }

    /// Nothing to do: like the batch speech models it compiles when the after-meeting pass first loads it.
    public func warm(root: URL) async throws {}
}

/// LocalVQE (echo and noise cancellation): `<root>/localvqe-coreml`, only the build the meeting runs.
public struct LocalVqeInstaller: ModelInstaller {
    public init() {}

    private static var modelFile: String {
        let config = FluidAudioModels.localVqeConfig
        return ModelNames.LocalVQE.modelFile(variant: config.variant, chunk: config.chunk)
    }

    public func installFolder(root: URL) -> URL {
        root.appendingPathComponent(Repo.localVqe.folderName, isDirectory: true)
    }

    public func isInstalled(root: URL) async -> Bool {
        isComplete(installFolder(root: root), required: [Self.modelFile])
    }

    public func install(root: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        FluidAudioModels.pinRevisions()
        let config = FluidAudioModels.localVqeConfig
        try await ModelHub.download(
            .localVqe, to: root, variant: ModelNames.LocalVQE.variantKey(variant: config.variant, chunk: config.chunk),
            progressHandler: progressHandler(progress))
    }

    public func warm(root: URL) async throws {
        _ = try LocalVqeManager(config: FluidAudioModels.localVqeConfig, modelDirectory: installFolder(root: root))
    }
}

// MARK: Catalog rows

/// The FluidAudio rows of the model catalog: descriptors plus the installer for each.
public enum FluidAudioModels {
    static let nemotronLanguages = ["en", "es", "fr", "it", "pt", "de", "zh", "ja"]
    static let latinLanguages = ["en", "es", "fr", "it", "pt", "de"]
    private static let parakeetV3Languages = [
        "bg", "hr", "cs", "da", "nl", "en", "et", "fi", "fr", "de", "el", "hu", "it",
        "lv", "lt", "mt", "pl", "pt", "ro", "sk", "sl", "es", "sv", "ru", "uk",
    ]
    private static let mb: Int64 = 1_000_000

    public static func nemotronID(_ variant: NemotronVariant, chunkMs: Int) -> String {
        "nemotron-\(variant.rawValue)-\(chunkMs)"
    }

    public static func eouID(_ chunk: EouChunk) -> String { "parakeet-eou-\(chunk.rawValue)" }

    public static let parakeetV3ID = "parakeet-v3"
    public static let parakeetUltraID = "parakeet-ultra"
    /// Streaming Sortformer: who speaks while a meeting records.
    public static let sortformerID = "sortformer-live"
    /// The offline diarizer: who spoke, after the meeting.
    public static let diarizerOfflineID = "diarizer-offline"
    /// LocalVQE: echo and noise cancellation for the meeting mic.
    public static let localVqeID = "localvqe-live"

    /// The LocalVQE build the meeting runs: v1.3 in 16 ms hops, so the cleaned mic is at most a hop late. On the
    /// CPU, which FluidAudio found fastest for it (the fp32 graph is too small to pay for Neural Engine dispatch).
    static let localVqeConfig = LocalVqeConfig(variant: .v13, chunk: .realtime16ms)

    private static let entries: [(descriptor: ModelDescriptor, installer: any ModelInstaller)] = {
        var rows: [(ModelDescriptor, any ModelInstaller)] = []
        for variant in NemotronVariant.allCases {
            for chunkMs in NemotronInstaller.supportedChunks {
                let multilingual = variant == .multilingual
                rows.append((
                    ModelDescriptor(
                        id: nemotronID(variant, chunkMs: chunkMs),
                        kind: .speechStreaming,
                        displayName: "Nemotron \(multilingual ? "multilingual" : "Latin") · \(chunkMs) ms",
                        approxBytes: (multilingual ? 665 : 612) * mb,
                        languages: multilingual ? nemotronLanguages : latinLanguages,
                        licence: "OpenMDW-1.1",
                        platforms: [.iOS, .macOS],
                        family: "nemotron-\(variant.rawValue)",
                        familyName: "Nemotron \(multilingual ? "multilingual" : "Latin")",
                        tierMs: chunkMs),
                    NemotronInstaller(variant: variant, chunkMs: chunkMs)))
            }
        }
        for chunk in EouChunk.allCases {
            rows.append((
                ModelDescriptor(
                    id: eouID(chunk),
                    kind: .speechStreaming,
                    displayName: "Parakeet EOU · \(chunk.rawValue) ms",
                    approxBytes: 225 * mb,
                    languages: ["en"],
                    licence: "NVIDIA Open Model License",
                    platforms: [.iOS, .macOS],
                    family: "parakeet-eou",
                    familyName: "Parakeet EOU",
                    tierMs: chunk.rawValue),
                ParakeetEouInstaller(chunk: chunk)))
        }
        rows.append((
            ModelDescriptor(
                id: parakeetV3ID,
                kind: .speechBatch,
                displayName: "Parakeet TDT v3",
                approxBytes: 520 * mb,
                languages: parakeetV3Languages,
                licence: "CC-BY-4.0",
                platforms: [.iOS, .macOS],
                family: "parakeet"),
            ParakeetBatchInstaller(model: .v3)))
        rows.append((
            ModelDescriptor(
                id: parakeetUltraID,
                kind: .speechBatch,
                displayName: "Parakeet Ultra",
                approxBytes: 640 * mb,
                languages: parakeetV3Languages,
                licence: "CC-BY-4.0",
                platforms: [.iOS, .macOS],
                family: "parakeet"),
            ParakeetBatchInstaller(model: .ultra)))
        rows.append((
            ModelDescriptor(
                id: sortformerID,
                kind: .speakersLive,
                displayName: "Sortformer",
                approxBytes: 97 * mb,
                licence: "NVIDIA Open Model License",
                platforms: [.iOS, .macOS],
                family: "sortformer"),
            SortformerInstaller()))
        rows.append((
            ModelDescriptor(
                id: diarizerOfflineID,
                kind: .speakersBatch,
                displayName: "Pyannote community-1",
                approxBytes: 22 * mb,
                licence: "CC-BY-4.0",
                platforms: [.iOS, .macOS],
                family: "pyannote"),
            OfflineDiarizerInstaller()))
        rows.append((
            ModelDescriptor(
                id: localVqeID,
                kind: .echoNoise,
                displayName: "LocalVQE",
                approxBytes: 20 * mb,
                licence: "Apache-2.0",
                platforms: [.iOS, .macOS],
                family: "localvqe"),
            LocalVqeInstaller()))
        return rows
    }()

    /// Catalog rows for every FluidAudio model.
    public static var descriptors: [ModelDescriptor] { entries.map(\.descriptor) }

    /// One installer per descriptor, keyed by ``ModelDescriptor/id``.
    public static var installers: [String: any ModelInstaller] {
        Dictionary(uniqueKeysWithValues: entries.map { ($0.descriptor.id, $0.installer) })
    }
}
