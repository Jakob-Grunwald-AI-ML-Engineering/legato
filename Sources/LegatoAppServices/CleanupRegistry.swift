import Foundation
import LegatoCore
import LegatoCoreML
import LegatoModels
import LegatoPostProcessing

/// Resolves one explicit model in every app state. Reads never download, prepare, or substitute a backend.
public struct CleanupRegistry: Sendable {
    public enum Choice: Sendable, Equatable {
        case coreML(modelID: String)
        case foundationModels
        case itnOnly
    }
    public enum BackendPreference: String, Sendable, Equatable, CaseIterable {
        case coreML
        case foundationModels
    }
    public enum Skip: Sendable, Equatable, CustomStringConvertible {
        case coreMLUnavailable(modelID: String, reason: String)
        case foundationModelsUnavailable(reason: String)
        case noFoundationModels
        public var description: String {
            switch self {
            case .coreMLUnavailable(let id, let reason): "\(id) unavailable: \(reason)"
            case .foundationModelsUnavailable(let reason): "Apple Foundation Models unavailable: \(reason)"
            case .noFoundationModels: "Apple Foundation Models are not available on this device"
            }
        }
    }
    public struct Resolution: Sendable {
        public let choice: Choice
        public let backend: (any LLMBackend)?
        public let skipped: [Skip]
        public let execution: String?
    }
    private let models: ModelManager
    private let foundationModels: (any LLMBackend)?
    private let makeCoreMLBackend: @Sendable (String, URL) async -> (any LLMBackend)?
    private let cleanupGuard: CleanupGuard

    public init(models: ModelManager, foundationModels: (any LLMBackend)?, cleanupGuard: CleanupGuard = CleanupGuard(),
                makeCoreMLBackend: @escaping @Sendable (String, URL) async -> (any LLMBackend)? = { id, root in
                    guard let spec = CoreMLModels.spec(id: id) else { return nil }
                    return await CoreMLModelStore.shared.backend(for: spec, root: root)
                }) {
        self.models = models; self.foundationModels = foundationModels
        self.cleanupGuard = cleanupGuard; self.makeCoreMLBackend = makeCoreMLBackend
    }

    public func resolve(preference: BackendPreference = .foundationModels) async -> Resolution {
        if preference == .foundationModels {
            guard let foundationModels else { return .init(choice: .itnOnly, backend: nil, skipped: [.noFoundationModels], execution: nil) }
            switch await foundationModels.availability {
            case .available: return .init(choice: .foundationModels, backend: foundationModels, skipped: [], execution: nil)
            case .unavailable(let reason): return .init(choice: .itnOnly, backend: nil, skipped: [.foundationModelsUnavailable(reason: reason)], execution: nil)
            }
        }
        let selected = await models.selected(role: .cleanup)
        func unavailable(_ reason: String) -> Resolution {
            .init(choice: .itnOnly, backend: nil, skipped: [.coreMLUnavailable(modelID: selected ?? "Core ML", reason: reason)], execution: nil)
        }
        guard let selected else { return unavailable("Choose and prepare a Core ML model in Legato") }
        guard CoreMLModels.spec(id: selected) != nil else { return unavailable("This model is not in the Core ML catalog. Choose a model in Legato.") }
        guard case .installed = await models.state(of: selected) else { return unavailable("Model is not installed. Choose it in Legato to install and prepare it.") }
        guard let backend = await makeCoreMLBackend(selected, await models.root) else { return unavailable("Prepare the selected Core ML model in Legato") }
        switch await backend.availability {
        case .available: return .init(choice: .coreML(modelID: selected), backend: backend, skipped: [], execution: "CPU + Neural Engine requested; placement unverified")
        case .unavailable(let reason): return unavailable(reason)
        }
    }

    public func pipeline(style: CleanupStyle, itn: Bool, preference: BackendPreference,
                         timeout: Duration, context: String = "", vocabulary: [String] = []) async -> (pipeline: PostProcessingPipeline, resolution: Resolution) {
        let resolution = await resolve(preference: preference)
        var stages: [any TranscriptPostProcessor] = itn ? [ITNStage()] : []
        if let backend = resolution.backend {
            stages.append(LLMCleanupStage(backend: backend, cleanupGuard: style == .verbatim ? cleanupGuard : style.cleanupGuard,
                                          vocabulary: vocabulary, prompt: style.prompt, context: context))
        }
        return (PostProcessingPipeline(stages: stages, timeout: timeout), resolution)
    }
}
