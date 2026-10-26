import Foundation
import LegatoCore
import LegatoModels
import LegatoPostProcessing
#if canImport(UIKit)
import UIKit
#endif

/// Picks the backend for LLM cleanup: the user's MLX model (while the GPU is usable), else Apple
/// Foundation Models, else none.
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
    private let canUseGPU: @Sendable () async -> Bool

    /// - Parameters:
    ///   - models: the manager whose `cleanup` selection and install states decide.
    ///   - foundationModels: the fallback, or `nil` where it does not exist.
    ///   - makeMLXBackend: builds the backend for an installed model and its folder.
    ///   - canUseGPU: asked on every ``resolve()`` that would pick an MLX model; `false` falls through to
    ///     Foundation Models or ITN only. ``defaultCanUseGPU`` is `true` on the Mac and, on the phone,
    ///     `true` unless the app is in the background.
    public init(
        models: ModelManager,
        foundationModels: (any LLMBackend)?,
        cleanupGuard: CleanupGuard = CleanupGuard(),
        makeMLXBackend: @escaping @Sendable (MLXModelSpec, URL) -> any LLMBackend = { MLXBackend(spec: $0, folder: $1) },
        canUseGPU: @escaping @Sendable () async -> Bool = CleanupRegistry.defaultCanUseGPU
    ) {
        self.models = models
        self.foundationModels = foundationModels
        self.cleanupGuard = cleanupGuard
        self.makeMLXBackend = makeMLXBackend
        self.canUseGPU = canUseGPU
    }

    /// Whether this process may run GPU work now. MLX needs the GPU, and iOS refuses GPU work from a
    /// background app, which is where v1 dictates. The phone asks `UIApplication`, which a host app has and an
    /// app extension does not (an extension passes its own check to the initializer); the Mac has no such rule.
    public static let defaultCanUseGPU: @Sendable () async -> Bool = {
        #if canImport(UIKit) && !os(macOS)
        await MainActor.run { UIApplication.shared.applicationState != .background }
        #else
        true
        #endif
    }

    /// The first usable backend, in order MLX, Foundation Models, none.
    public func resolve() async -> (choice: Choice, backend: (any LLMBackend)?) {
        if let id = await models.selected(role: .cleanup),
           let spec = MLXModels.spec(id: id),
           case .installed = await models.state(of: id),
           await canUseGPU() {
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
