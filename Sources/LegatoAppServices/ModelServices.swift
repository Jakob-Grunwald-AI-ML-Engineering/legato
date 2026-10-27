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
    /// The live (streaming) models grouped by family, each with its latency tiers.
    public let streamingFamilies: [ModelFamily]
    private let selection: SelectionStore
    private let familySelection: FamilySelection
    /// The pick in flight per role; a newer pick (or Apple Speech) cancels it.
    private var picks: [ModelRole: Task<Void, Never>] = [:]
    /// The model each pick in `picks` installs.
    private var pickIDs: [ModelRole: (token: UUID, id: String)] = [:]

    /// - Parameters:
    ///   - root: where the models live (`<App Group>/Models` on the phone, `Application Support/Legato/Models`
    ///     on the Mac).
    ///   - defaults: where the picks and the engine settings persist.
    public convenience init(root: URL, defaults: UserDefaults, platform: ModelPlatform = .current) {
        self.init(root: root, defaults: defaults, platform: platform, installers: nil)
    }

    /// `installers`: replaces the catalog's real installers (tests); nil for the real ones.
    init(root: URL, defaults: UserDefaults, platform: ModelPlatform, installers custom: [String: any ModelInstaller]?) {
        FluidAudioModels.pinRevisions()
        selection = SelectionStore(defaults: defaults)
        familySelection = FamilySelection(selection: selection, tiers: FamilyTierStore(defaults: defaults))
        engineSettings = EngineSettings(defaults: defaults)
        let speech = FluidAudioCatalog.descriptors(platform: platform)
        let llms = MLXModels.descriptors(platform: platform)
        let installers = custom ?? FluidAudioCatalog.installers(platform: platform)
            .merging(MLXModels.installers(platform: platform)) { first, _ in first }
        catalog = speech + llms
        streamingFamilies = ModelFamily.groups(of: speech, kind: .speechStreaming)
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
    /// The models the after-meeting pass can use on this device, in catalog order.
    public var postPassModels: [ModelDescriptor] { catalog.filter { $0.kind == ModelRole.postPass.kind } }
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
    /// main actor with nil on success or the error. A newer pick for the role cancels this one's wait and the
    /// selection does not switch to it; its download stops too (``supersededPick(inFlight:next:)``), unless
    /// something else still waits for it, and its partial folder goes. A download cancelled by the user
    /// (``cancelDownload(_:)``, a delete) ends the pick without calling `done`: it is no failure.
    public func pick(_ id: String, role: ModelRole, done: @escaping @MainActor ((any Error)?) -> Void) {
        picks[role]?.cancel()
        let superseded = Self.supersededPick(inFlight: pickIDs[role]?.id, next: id)
        let manager = self.manager
        let token = UUID()
        pickIDs[role] = (token, id)
        picks[role] = Task {
            defer {
                if pickIDs[role]?.token == token {
                    picks[role] = nil
                    pickIDs[role] = nil
                }
            }
            do {
                try await manager.select(id, role: role, superseding: superseded)
                try Task.checkCancellation()
                done(nil)
            } catch {
                // Superseded by a newer pick: its own error (a cancelled install) is not this pick's to report.
                if Task.isCancelled || error is CancellationError { return }
                // The download was cancelled or the model deleted while it downloaded: the user's own doing.
                if case ModelError.cancelled = error { return }
                Self.log.error("pick \(id, privacy: .public) failed: \(String(describing: error), privacy: .public)")
                done(error)
            }
        }
    }

    /// The pick in flight that a pick of `next` replaces: any other model (another tier, another family),
    /// whose download then stops, so a flurry of picks never leaves several downloads running. Nil for the
    /// same model or nothing in flight.
    public nonisolated static func supersededPick(inFlight: String?, next: String) -> String? {
        guard let inFlight, inFlight != next else { return nil }
        return inFlight
    }

    // MARK: families

    /// The family the live pick belongs to, if a model is picked.
    public var activeFamily: ModelFamily? {
        familySelection.activeFamily(in: streamingFamilies, role: .liveDictation)
    }

    /// The tier shown for `family`: the live pick's tier when the family is live, else the remembered tier
    /// or the family default. `nil` for a model without tiers.
    public func chosenTier(of family: ModelFamily) -> Int? {
        familySelection.chosenTier(of: family, role: .liveDictation)
    }

    /// The catalog model a pick of `family` would use now: the one at its chosen tier.
    public func chosenModel(of family: ModelFamily) -> ModelDescriptor? {
        familySelection.activate(family, role: .liveDictation).flatMap { id in family.members.first { $0.id == id } }
    }

    /// "Nemotron multilingual · 1120 ms": the family with its chosen tier.
    public func liveLabel(of family: ModelFamily) -> String {
        chosenTier(of: family).map { "\(family.name) · \($0) ms" } ?? family.name
    }

    /// Makes `family` the live engine at its chosen tier. Only that tier downloads (see ``pick(_:role:done:)``).
    public func pick(family: ModelFamily, done: @escaping @MainActor ((any Error)?) -> Void) {
        guard let id = familySelection.activate(family, role: .liveDictation) else { return }
        pick(id, role: .liveDictation, done: done)
    }

    /// Makes `family` live at `tierMs`, downloading that tier first if it is missing.
    public func pick(family: ModelFamily, tierMs: Int, done: @escaping @MainActor ((any Error)?) -> Void) {
        guard let id = familySelection.choose(family, tierMs: tierMs, role: .liveDictation, activate: true) else { return }
        pick(id, role: .liveDictation, done: done)
    }

    /// Changes the latency tier of `family`. When the family is the live one, the new tier is picked (it
    /// downloads first; the old tier stays live until then) and this returns `true`. Otherwise the tier is
    /// only remembered for when the family is picked, and nothing downloads.
    @discardableResult
    public func setTier(_ tierMs: Int, of family: ModelFamily, done: @escaping @MainActor ((any Error)?) -> Void) -> Bool {
        guard let id = familySelection.choose(family, tierMs: tierMs, role: .liveDictation, activate: false) else { return false }
        pick(id, role: .liveDictation, done: done)
        return true
    }

    /// The Cancel control of a downloading model: stops its download for every waiter (a pick of it ends
    /// without switching and without an error) and removes the partial folder. Returns once it wound down.
    public func cancelDownload(_ id: String) async {
        for (role, pick) in pickIDs where pick.id == id {
            picks[role]?.cancel()
            picks[role] = nil
            pickIDs[role] = nil
        }
        await manager.cancel(id)
    }

    /// Back to the zero-download default for `role` (Apple Speech, or no MLX model): cancels a pick in
    /// flight and its download, unless something else still waits for it.
    public func clearPick(_ role: ModelRole) {
        picks[role]?.cancel()
        picks[role] = nil
        if let abandoned = pickIDs[role]?.id {
            let manager = self.manager
            Task { await manager.abandon(abandoned, besidesPicksFor: role) }
        }
        pickIDs[role] = nil
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
