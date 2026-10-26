import Foundation
import LegatoCore
import LegatoModels
import LegatoPostProcessing

/// Picks the backend for LLM cleanup: the user's MLX model, else Apple Foundation Models, else none.
///
/// The registry only reads. It never installs, downloads or warms a model: a selected model that is not
/// on disk simply falls through, and the user installs by picking (`ModelManager.select(_:role:)`).
public struct CleanupRegistry: Sendable {
    public enum Choice: Sendable, Equatable {
        /// The installed MLX model the user picked.
        case mlx(modelID: String)
        case foundationModels
        /// No LLM stage: only inverse text normalization runs.
        case itnOnly
    }

    private let models: ModelManager
    private let foundationModels: (any LLMBackend)?
    private let makeMLXBackend: @Sendable (MLXModelSpec, URL) -> any LLMBackend
    private let cleanupGuard: CleanupGuard

    /// - Parameters:
    ///   - models: the manager whose `cleanup` selection and install states decide.
    ///   - foundationModels: the fallback, or `nil` where it does not exist.
    ///   - makeMLXBackend: builds the backend for an installed model and its folder.
    public init(
        models: ModelManager,
        foundationModels: (any LLMBackend)?,
        cleanupGuard: CleanupGuard = CleanupGuard(),
        makeMLXBackend: @escaping @Sendable (MLXModelSpec, URL) -> any LLMBackend = { MLXBackend(spec: $0, folder: $1) }
    ) {
        self.models = models
        self.foundationModels = foundationModels
        self.cleanupGuard = cleanupGuard
        self.makeMLXBackend = makeMLXBackend
    }

    /// The first usable backend, in order MLX, Foundation Models, none.
    public func resolve() async -> (choice: Choice, backend: (any LLMBackend)?) {
        if let id = await models.selected(role: .cleanup),
           let spec = MLXModels.spec(id: id),
           case .installed = await models.state(of: id) {
            let root = await models.root
            let backend = makeMLXBackend(spec, spec.folder(root: root))
            if await backend.availability.isAvailable { return (.mlx(modelID: id), backend) }
        }
        if let foundationModels, await foundationModels.availability.isAvailable {
            return (.foundationModels, foundationModels)
        }
        return (.itnOnly, nil)
    }

    /// ITN, then LLM cleanup when a backend resolved.
    public func pipeline(timeout: Duration = .seconds(4)) async -> PostProcessingPipeline {
        var stages: [any TranscriptPostProcessor] = [ITNStage()]
        if let backend = await resolve().backend {
            stages.append(LLMCleanupStage(backend: backend, cleanupGuard: cleanupGuard))
        }
        return PostProcessingPipeline(stages: stages, timeout: timeout)
    }
}
