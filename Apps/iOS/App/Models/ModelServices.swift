import Foundation
import LegatoCore
import LegatoEngines
import LegatoFluidAudio
import LegatoMLX
import LegatoModels
import LegatoPostProcessing
import os

/// The app's one owner of the downloadable models: the catalog (FluidAudio speech models and MLX cleanup
/// models) with their install states and picks, the engine registry and the cleanup registry.
///
/// Nothing downloads implicitly: only a pick (`pick`, which installs and warms first: "load on pick") or
/// nothing at all. The previous pick stays live until the new one is installed.
@MainActor
final class ModelServices {
    private static let log = Logger(subsystem: "de.gruenwald.legato", category: "models")

    let manager: ModelManager
    let engines: EngineRegistry
    let cleanup: CleanupRegistry
    let engineSettings: EngineSettings
    /// The models on offer on this phone (the manager's catalog, readable without awaiting it).
    let catalog: [ModelDescriptor]
    private let selection: SelectionStore
    /// The pick in flight per role; a newer pick (or Apple Speech) cancels it.
    private var picks: [ModelRole: Task<Void, Never>] = [:]

    /// `<App Group container>/Models`, or the app's own Application Support when the App Group is
    /// unavailable (like the history file).
    static var modelsRoot: URL {
        let base = AppGroup.containerURL
            ?? URL.applicationSupportDirectory.appending(path: "Legato", directoryHint: .isDirectory)
        return base.appending(path: "Models", directoryHint: .isDirectory)
    }

    init() {
        FluidAudioModels.pinRevisions()
        let defaults = AppGroup.defaults
        selection = SelectionStore(defaults: defaults)
        engineSettings = EngineSettings(defaults: defaults)
        let speech = FluidAudioCatalog.descriptors()
        let llms = MLXModels.descriptors()
        let installers = FluidAudioCatalog.installers().merging(MLXModels.installers()) { first, _ in first }
        catalog = speech + llms
        manager = ModelManager(
            root: Self.modelsRoot,
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

    /// Live dictation models for this phone, in catalog order.
    var streamingModels: [ModelDescriptor] { catalog.filter { $0.kind == .speechStreaming } }
    /// Cleanup language models for this phone.
    var cleanupModels: [ModelDescriptor] { catalog.filter { $0.kind == .llm } }

    func selected(_ role: ModelRole) -> String? { selection.selected(for: role) }

    /// Picks `id` for `role`: installs and warms it first when missing, then switches. `done` runs on the
    /// main actor with nil on success or the error. A newer pick for the role cancels this one's wait (the
    /// download itself carries on; the selection does not switch to it).
    func pick(_ id: String, role: ModelRole, done: @escaping @MainActor ((any Error)?) -> Void) {
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
    func clearPick(_ role: ModelRole) {
        picks[role]?.cancel()
        picks[role] = nil
        selection.set(nil, for: role)
    }
}
