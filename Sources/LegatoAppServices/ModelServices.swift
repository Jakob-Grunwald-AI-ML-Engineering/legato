import Foundation
import LegatoCore
import LegatoEngines
import LegatoFluidAudio
import LegatoMLX
import LegatoModels
import LegatoPostProcessing
import os

/// An app's one owner of the downloadable models: the catalog for this platform (FluidAudio speech models
/// and MLX cleanup models) with their install states and picks, the engine registry and the cleanup registry.
///
/// Nothing downloads implicitly: only a pick (`pick`, which installs and warms first: "load on pick") or
/// nothing at all. The previous pick stays live until the new one is installed.
@MainActor
public final class ModelServices {
    private static let log = Logger(subsystem: "de.gruenwald.legato", category: "models")

    public let manager: ModelManager
    public let engines: EngineRegistry
    public let cleanup: CleanupRegistry
    public let engineSettings: EngineSettings
    /// The models on offer on this device (the manager's catalog, readable without awaiting it).
    public let catalog: [ModelDescriptor]
    private let selection: SelectionStore
    /// The pick in flight per role; a newer pick (or Apple Speech) cancels it.
    private var picks: [ModelRole: Task<Void, Never>] = [:]

    /// - Parameters:
    ///   - root: where the models live (`<App Group>/Models` on the phone, `Application Support/Legato/Models`
    ///     on the Mac).
    ///   - defaults: where the picks and the engine settings persist.
    public init(root: URL, defaults: UserDefaults, platform: ModelPlatform = .current) {
        FluidAudioModels.pinRevisions()
        selection = SelectionStore(defaults: defaults)
        engineSettings = EngineSettings(defaults: defaults)
        let speech = FluidAudioCatalog.descriptors(platform: platform)
        let llms = MLXModels.descriptors(platform: platform)
        let installers = FluidAudioCatalog.installers(platform: platform)
            .merging(MLXModels.installers(platform: platform)) { first, _ in first }
        catalog = speech + llms
        manager = ModelManager(
            root: root,
            catalog: catalog,
            installers: installers,
            selection: selection,
            onDelete: { id, folder in
                if MLXModels.spec(id: id) != nil {
                    await MLXModels.release(folder: folder)
                } else {
                    await FluidAudioModels.release(folder: folder)
                }
            })
        engines = EngineRegistry(models: manager, settings: engineSettings)
        cleanup = CleanupRegistry(models: manager, foundationModels: FoundationModelsBackend())
    }

    /// Live dictation models for this device, in catalog order.
    public var streamingModels: [ModelDescriptor] { catalog.filter { $0.kind == .speechStreaming } }
    /// Cleanup language models for this device.
    public var cleanupModels: [ModelDescriptor] { catalog.filter { $0.kind == .llm } }

    public func selected(_ role: ModelRole) -> String? { selection.selected(for: role) }

    /// The name of the engine a history entry was dictated with (`DictationEntry.engineID`).
    public func engineName(for engineID: String) -> String {
        if engineID == "apple-speech" { return "Apple Speech" }
        return streamingModels.first { $0.id == engineID }?.displayName ?? engineID
    }

    /// The one language the engine settings name, if exactly one: cleanup then writes in it.
    public nonisolated static func singleLocale(_ settings: EngineSettings) -> Locale? {
        let locales = settings.preferredLocales
        return locales.count == 1 ? locales[0] : nil
    }

    /// Picks `id` for `role`: installs and warms it first when missing, then switches. `done` runs on the
    /// main actor with nil on success or the error. A newer pick for the role cancels this one's wait (the
    /// download itself carries on; the selection does not switch to it).
    public func pick(_ id: String, role: ModelRole, done: @escaping @MainActor ((any Error)?) -> Void) {
        picks[role]?.cancel()
        let manager = self.manager
        picks[role] = Task {
            do {
                try await manager.select(id, role: role)
                try Task.checkCancellation()
                done(nil)
            } catch is CancellationError {
                return
            } catch {
                Self.log.error("pick \(id, privacy: .public) failed: \(String(describing: error), privacy: .public)")
                done(error)
            }
        }
    }

    /// Back to the zero-download default for `role` (Apple Speech, or no MLX model): cancels a pick in flight.
    public func clearPick(_ role: ModelRole) {
        picks[role]?.cancel()
        picks[role] = nil
        selection.set(nil, for: role)
    }
}

/// Which engine new dictations use, for Settings.
public struct EngineStatus: Equatable, Sendable {
    /// The catalog id, nil for Apple Speech.
    public var modelID: String?
    public var name: String
    /// Why Apple Speech is used although a model was picked.
    public var fallback: String?

    public init(modelID: String? = nil, name: String = "Apple Speech", fallback: String? = nil) {
        self.modelID = modelID
        self.name = name
        self.fallback = fallback
    }
}

/// The engine new sessions get; replaced when the pick or the engine settings change.
@MainActor
public final class EngineBox {
    public var engine: any DictationEngine
    public init(_ engine: any DictationEngine) { self.engine = engine }
}

extension EngineFallback {
    /// Why Apple Speech is in use, for Settings.
    public var explanation: String {
        switch self {
        case .assetsNotInstalled: "the picked model is not installed"
        case .unknownModel(let id): "the picked model \(id) is not in this build's catalog"
        }
    }
}
