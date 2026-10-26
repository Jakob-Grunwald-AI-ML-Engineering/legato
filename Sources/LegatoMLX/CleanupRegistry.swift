import Foundation
import LegatoCore
import LegatoModels
import LegatoPostProcessing
#if canImport(UIKit)
import UIKit
#endif

/// Picks the backend for LLM cleanup: the user's MLX model (on the GPU, or on the CPU while the GPU is not
/// usable and ``BackgroundCleanup/cpu`` allows it), else Apple Foundation Models, else none.
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
    private let makeCPUBackend: @Sendable (MLXModelSpec, URL) -> any LLMBackend
    private let cleanupGuard: CleanupGuard
    private let canUseGPU: @Sendable () async -> Bool

    /// - Parameters:
    ///   - models: the manager whose `cleanup` selection and install states decide.
    ///   - foundationModels: the fallback, or `nil` where it does not exist.
    ///   - makeMLXBackend: builds the (GPU) backend for an installed model and its folder.
    ///   - makeCPUBackend: builds the CPU backend for an installed model and its folder, used while the GPU is
    ///     not usable and the background setting is ``BackgroundCleanup/cpu``.
    ///   - canUseGPU: asked on every resolve; `false` means the app is where the GPU is off limits (the phone's
    ///     background), and the ``BackgroundCleanup`` setting decides. ``defaultCanUseGPU`` is `true` on the
    ///     Mac and, on the phone, `true` unless the app is in the background.
    public init(
        models: ModelManager,
        foundationModels: (any LLMBackend)?,
        cleanupGuard: CleanupGuard = CleanupGuard(),
        makeMLXBackend: @escaping @Sendable (MLXModelSpec, URL) -> any LLMBackend = { MLXBackend(spec: $0, folder: $1) },
        makeCPUBackend: @escaping @Sendable (MLXModelSpec, URL) -> any LLMBackend = {
            MLXBackend(spec: $0, folder: $1, device: .cpu)
        },
        canUseGPU: @escaping @Sendable () async -> Bool = CleanupRegistry.defaultCanUseGPU
    ) {
        self.models = models
        self.foundationModels = foundationModels
        self.cleanupGuard = cleanupGuard
        self.makeMLXBackend = makeMLXBackend
        self.makeCPUBackend = makeCPUBackend
        self.canUseGPU = canUseGPU
    }

    /// What cleanup does while the GPU is not usable (the phone app in the background, where iOS refuses
    /// GPU work but allows the CPU and the Neural Engine). Stored as its raw value.
    public enum BackgroundCleanup: String, Sendable, Equatable, CaseIterable, Codable {
        /// The picked MLX model on the CPU: slower, same model and output.
        case cpu
        /// Apple Foundation Models (the picked MLX model is passed over).
        case foundationModels
        /// No language model: only ITN (when on) runs.
        case off
    }

    /// Whether this process may run GPU work now. iOS refuses GPU work from a background app, which is where
    /// v1 dictates; MLX then runs on the CPU (``BackgroundCleanup``). The phone asks `UIApplication`, which a host app has and an
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
        /// The picked MLX model (GPU, or as ``BackgroundCleanup`` says without it), else Foundation Models, else none.
        case auto
        /// Foundation Models only (an installed MLX pick is passed over), else none.
        case foundationModels
    }

    /// Why a backend earlier in the order was passed over.
    public enum Skip: Sendable, Equatable, CustomStringConvertible {
        /// The picked MLX model is not (fully) installed.
        case mlxNotInstalled(modelID: String)
        /// The GPU is not usable now (the app is in the background on the phone) and background cleanup is
        /// set to Foundation Models.
        case mlxNeedsForeground(modelID: String)
        /// The GPU is not usable now and background cleanup is off.
        case backgroundCleanupOff
        /// The MLX backend reported itself unusable.
        case mlxUnavailable(modelID: String, reason: String)
        case foundationModelsUnavailable(reason: String)
        /// This build or device has no Foundation Models backend.
        case noFoundationModels

        public var description: String {
            switch self {
            case .mlxNotInstalled(let id): "\(Self.name(id)) is not installed"
            case .mlxNeedsForeground(let id): "\(Self.name(id)) runs only in the foreground (background cleanup: Apple Foundation Models)"
            case .backgroundCleanupOff: "Background cleanup is off"
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
        /// Where an MLX model runs; nil for any other backend.
        public let device: ComputeDevice?

        public init(choice: Choice, backend: (any LLMBackend)?, skipped: [Skip], device: ComputeDevice? = nil) {
            self.choice = choice
            self.backend = backend
            self.skipped = skipped
            self.device = device
        }
    }

    /// The first usable backend for `preference`, in order MLX (``BackendPreference/auto`` only),
    /// Foundation Models, none, with the reasons the earlier ones were passed over. While the GPU is not
    /// usable, `background` decides: the MLX model on the CPU, Foundation Models, or no language model.
    /// The default keeps the call's old meaning (Foundation Models); the setting itself defaults to the CPU.
    public func resolve(preference: BackendPreference, background: BackgroundCleanup = .foundationModels) async -> Resolution {
        var skipped: [Skip] = []
        // Asked only when it matters: an installed MLX pick, or background cleanup off (which stops any model).
        if background == .off, await !canUseGPU() {
            return Resolution(choice: .itnOnly, backend: nil, skipped: [.backgroundCleanupOff])
        }
        if preference == .auto, let id = await models.selected(role: .cleanup), let spec = MLXModels.spec(id: id) {
            if case .installed = await models.state(of: id) {
                let gpu = await canUseGPU()
                if gpu || background == .cpu {
                    let root = await models.root
                    let device: ComputeDevice = gpu ? .gpu : .cpu
                    let backend = (gpu ? makeMLXBackend : makeCPUBackend)(spec, spec.folder(root: root))
                    switch await backend.availability {
                    case .available:
                        return Resolution(choice: .mlx(modelID: id), backend: backend, skipped: skipped, device: device)
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
    /// `context`: the cleaned text that came just before (live cleanup of one segment), shown to the model so
    /// the segment continues it; empty for a whole transcript.
    public func pipeline(
        style: CleanupStyle, itn: Bool, preference: BackendPreference, background: BackgroundCleanup = .foundationModels,
        timeout: Duration, context: String = ""
    ) async -> (pipeline: PostProcessingPipeline, resolution: Resolution) {
        let resolution = await resolve(preference: preference, background: background)
        var stages: [any TranscriptPostProcessor] = itn ? [ITNStage()] : []
        if let backend = resolution.backend {
            let guardrail = style == .verbatim ? cleanupGuard : style.cleanupGuard
            stages.append(LLMCleanupStage(backend: backend, cleanupGuard: guardrail, prompt: style.prompt, context: context))
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
