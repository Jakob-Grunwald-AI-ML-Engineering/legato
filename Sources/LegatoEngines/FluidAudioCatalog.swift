import Foundation
import LegatoCore
import LegatoFluidAudio
import LegatoModels

/// The speech side of the model catalog: FluidAudio descriptors and installers for one platform, and the
/// storage root they live under. Nothing here downloads.
public enum FluidAudioCatalog {
    /// The live model the catalog suggests until the bench table decides: Nemotron multilingual, 1120 ms.
    /// A suggestion only; nothing is selected or installed until the user picks it.
    public static let suggestedLiveModelID = FluidAudioModels.nemotronID(.multilingual, chunkMs: 1120)

    /// Silence that ends a live segment unless the settings say otherwise.
    public static let defaultSilenceMs = 1200

    /// `Application Support/Legato/Models`. Never FluidAudio's own default folder.
    public static func defaultRoot() -> URL {
        URL.applicationSupportDirectory
            .appending(path: "Legato", directoryHint: .isDirectory)
            .appending(path: "Models", directoryHint: .isDirectory)
    }

    /// The speech descriptors that run on `platform`.
    public static func descriptors(platform: ModelPlatform = .current) -> [ModelDescriptor] {
        FluidAudioModels.descriptors.filter { $0.supports(platform) }
    }

    /// The installers for ``descriptors(platform:)``, keyed by descriptor id.
    public static func installers(platform: ModelPlatform = .current) -> [String: any ModelInstaller] {
        let all = FluidAudioModels.installers
        return Dictionary(uniqueKeysWithValues: descriptors(platform: platform).compactMap { d in
            all[d.id].map { (d.id, $0) }
        })
    }

    /// A manager over the speech catalog for `platform`, storing under `root`.
    public static func makeManager(
        root: URL = defaultRoot(),
        selection: SelectionStore = SelectionStore(),
        platform: ModelPlatform = .current
    ) -> ModelManager {
        ModelManager(
            root: root,
            catalog: descriptors(platform: platform),
            installers: installers(platform: platform),
            selection: selection)
    }

    /// The streaming engine for a catalog id (tier included), or `nil` when the id is not a FluidAudio
    /// streaming model. Constructing an engine never loads or downloads anything.
    public static func liveEngine(
        id: String,
        preferredLocales: [Locale],
        silenceMs: Int,
        models: ModelManager
    ) -> (any DictationEngine)? {
        for variant in NemotronVariant.allCases {
            for chunkMs in NemotronInstaller.supportedChunks where FluidAudioModels.nemotronID(variant, chunkMs: chunkMs) == id {
                return NemotronEngine(
                    variant: variant, chunkMs: chunkMs, preferredLocales: preferredLocales,
                    silenceMs: silenceMs, models: models, modelID: id)
            }
        }
        for chunk in EouChunk.allCases where FluidAudioModels.eouID(chunk) == id {
            return ParakeetEouEngine(chunk: chunk, silenceMs: silenceMs, models: models, modelID: id)
        }
        return nil
    }

    /// The batch transcriber for a catalog id, or `nil` when the id is not a FluidAudio batch model.
    public static func batchTranscriber(id: String, models: ModelManager) -> (any BatchTranscriber)? {
        if id == FluidAudioModels.parakeetV3ID { return ParakeetTranscriber(model: .v3, models: models, modelID: id) }
        if id == FluidAudioModels.parakeetUltraID { return ParakeetTranscriber(model: .ultra, models: models, modelID: id) }
        return nil
    }
}
