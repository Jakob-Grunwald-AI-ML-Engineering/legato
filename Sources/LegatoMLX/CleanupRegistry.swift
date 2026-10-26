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
        let resolution = await resolve(preference: .auto)
        return (resolution.choice, resolution.backend)
    }

    /// Which backends ``resolve(preference:)`` may pick.
    public enum BackendPreference: String, Sendable, Equatable, CaseIterable {
        /// The picked MLX model while the GPU is usable, else Foundation Models, else none.
        case auto
        /// Foundation Models only (an installed MLX pick is passed over), else none.
        case foundationModels
    }

    /// Why a backend earlier in the order was passed over.
    public enum Skip: Sendable, Equatable, CustomStringConvertible {
        /// The picked MLX model is not (fully) installed.
        case mlxNotInstalled(modelID: String)
        /// The GPU is not usable now (the app is in the background on the phone).
        case mlxNeedsForeground(modelID: String)
        /// The MLX backend reported itself unusable.
        case mlxUnavailable(modelID: String, reason: String)
        case foundationModelsUnavailable(reason: String)
        /// This build or device has no Foundation Models backend.
        case noFoundationModels

        public var description: String {
            switch self {
            case .mlxNotInstalled(let id): "\(Self.name(id)) is not installed"
            case .mlxNeedsForeground(let id): "\(Self.name(id)) needs the app in front (no GPU in the background)"
            case .mlxUnavailable(let id, let reason): "\(Self.name(id)) is unavailable: \(reason)"
            case .foundationModelsUnavailable(let reason): "Apple Foundation Models unavailable: \(reason)"
            case .noFoundationModels: "Apple Foundation Models are not available on this device"
            }
        }

        private static func name(_ id: String) -> String { MLXModels.spec(id: id)?.displayName ?? id }
    }

    /// The backend a cleanup run uses and why earlier ones were passed over.
    public struct Resolution: Sendable {
        public let choice: Choice
        public let backend: (any LLMBackend)?
        public let skipped: [Skip]
    }

    /// The first usable backend for `preference`, in order MLX (``BackendPreference/auto`` only),
    /// Foundation Models, none, with the reasons the earlier ones were passed over.
    public func resolve(preference: BackendPreference) async -> Resolution {
        var skipped: [Skip] = []
        if preference == .auto, let id = await models.selected(role: .cleanup), let spec = MLXModels.spec(id: id) {
            if case .installed = await models.state(of: id) {
                if await canUseGPU() {
                    let root = await models.root
                    let backend = makeMLXBackend(spec, spec.folder(root: root))
                    switch await backend.availability {
                    case .available: return Resolution(choice: .mlx(modelID: id), backend: backend, skipped: skipped)
                    case .unavailable(let reason): skipped.append(.mlxUnavailable(modelID: id, reason: reason))
                    }
                } else {
                    skipped.append(.mlxNeedsForeground(modelID: id))
                }
            } else {
                skipped.append(.mlxNotInstalled(modelID: id))
            }
        }
        if let foundationModels {
            switch await foundationModels.availability {
            case .available: return Resolution(choice: .foundationModels, backend: foundationModels, skipped: skipped)
            case .unavailable(let reason): skipped.append(.foundationModelsUnavailable(reason: reason))
            }
        } else {
            skipped.append(.noFoundationModels)
        }
        return Resolution(choice: .itnOnly, backend: nil, skipped: skipped)
    }

    /// The pipeline for one run: ITN (when `itn`), then LLM cleanup in `style` when a backend resolved, each
    /// stage limited to `timeout`. Resolves afresh on every call, so GPU access is checked per run.
    public func pipeline(
        style: CleanupStyle, itn: Bool, preference: BackendPreference, timeout: Duration
    ) async -> (pipeline: PostProcessingPipeline, resolution: Resolution) {
        let resolution = await resolve(preference: preference)
        var stages: [any TranscriptPostProcessor] = itn ? [ITNStage()] : []
        if let backend = resolution.backend {
            let guardrail = style == .verbatim ? cleanupGuard : style.cleanupGuard
            stages.append(LLMCleanupStage(backend: backend, cleanupGuard: guardrail, prompt: style.prompt))
        }
        return (PostProcessingPipeline(stages: stages, timeout: timeout), resolution)
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
