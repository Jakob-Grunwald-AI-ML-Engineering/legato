import Foundation
import LegatoCore
import LegatoAppleSpeech
import LegatoCoreML
import LegatoEngines
import LegatoFluidAudio
import LegatoModels
import LegatoPostProcessing
import os
import Observation

/// Native resource boundaries replaced by latched resources in admission integration tests.
struct ModelServiceResources: Sendable {
    let speech: SelectedModelWarmup.Resource
    let foundation: any LLMBackend & ModelResourceLifecycle
    let coreML: @Sendable (String, URL) async -> any LLMBackend & ModelResourceLifecycle
}

@MainActor @Observable public final class CleanupPreparationStatus {
    public enum State: Equatable { case idle, preparing, ready, failed, missing }
    public fileprivate(set) var state: State = .idle
    public fileprivate(set) var modelID: String?
    public fileprivate(set) var message: String?
    public fileprivate(set) var usingFoundationModels = false
    public fileprivate(set) var foundationAvailable = false
    public var description: String {
        switch state {
        case .idle: "The selected model will prepare when Legato is active."
        case .preparing: foundationAvailable
            ? "Preparing the selected model. Cleanup can use Apple Foundation Models meanwhile."
            : "Preparing the selected model."
        case .ready: usingFoundationModels
            ? "The selected model is ready for the next dictation. This dictation uses Apple Foundation Models."
            : "The selected model is ready."
        case .failed, .missing: message ?? "The selected model is unavailable."
        }
    }
}

/// An app's one owner of the downloadable models: the catalog for this platform (FluidAudio speech models
/// and Core ML cleanup models) with their install states and picks, the engine registry and the cleanup registry.
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
    private let meetingSettings: MeetingSettings
    private let modelRoot: URL
    private let warmup = SelectedModelWarmup()
    private let speechResources: AppleSpeechEngine
    private let foundationResources: any LLMBackend & ModelResourceLifecycle
    private let resourceOverrides: ModelServiceResources?
    public let cleanupPreparation = CleanupPreparationStatus()
    public var cleanupPreparationNotice: String? { cleanupPreparation.state == .failed ? cleanupPreparation.message : nil }
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
    ///   - vocabulary: where the live engines get their vocabulary hints.
    public convenience init(
        root: URL, defaults: UserDefaults, platform: ModelPlatform = .current,
        vocabulary: (any VocabularyHintProvider)? = nil
    ) {
        self.init(root: root, defaults: defaults, platform: platform, installers: nil, vocabulary: vocabulary)
    }

    /// `installers`: replaces the catalog's real installers (tests); nil for the real ones.
    init(
        root: URL, defaults: UserDefaults, platform: ModelPlatform, installers custom: [String: any ModelInstaller]?,
        vocabulary: (any VocabularyHintProvider)? = nil, resources: ModelServiceResources? = nil
    ) {
        CleanupSelectionMigration.migrate(defaults)
        self.modelRoot = root
        resourceOverrides = resources
        foundationResources = resources?.foundation ?? FoundationModelsBackend()
        meetingSettings = MeetingSettings(defaults: defaults)
        speechResources = AppleSpeechEngine(vocabulary: vocabulary)
        FluidAudioModels.pinRevisions()
        selection = SelectionStore(defaults: defaults)
        familySelection = FamilySelection(selection: selection, tiers: FamilyTierStore(defaults: defaults))
        engineSettings = EngineSettings(defaults: defaults)
        let speech = FluidAudioCatalog.descriptors(platform: platform)
        let llms = CoreMLModels.descriptors(platform: platform)
        let installers = custom ?? FluidAudioCatalog.installers(platform: platform)
            .merging(CoreMLModels.installers(platform: platform)) { first, _ in first }
        catalog = speech + llms
        streamingFamilies = ModelFamily.groups(of: speech, kind: .speechStreaming)
        manager = ModelManager(
            root: root,
            catalog: catalog,
            installers: installers,
            selection: selection,
            onWillDelete: { id, folder in
                if CoreMLModels.spec(id: id) != nil {
                    await CoreMLModels.release(folder: folder)
                } else {
                    await FluidAudioModels.release(folder: folder)
                }
            })
        engines = EngineRegistry(models: manager, settings: engineSettings, vocabulary: vocabulary)
        let resourceOwner = warmup, nativeOverrides = resources
        cleanup = CleanupRegistry(models: manager,
            foundationModels: ResourceLeasedBackend(backend: foundationResources, owner: resourceOwner, key: "cleanup:foundation-models"), makeCoreMLBackend: { id, root in
            guard let spec = CoreMLModels.spec(id: id) else { return nil }
            let backend: any LLMBackend
            if let nativeOverrides { backend = await nativeOverrides.coreML(id, root) }
            else { backend = await CoreMLModelStore.shared.backend(for: spec, root: root) }
            return ResourceLeasedBackend(backend: backend, owner: resourceOwner, key: "cleanup:" + id)
        })
    }

    /// Reconciles retention for every selected consumer without waiting for their union.
    public func reconcileSelectedModels(options: CleanupOptions, inBackground: Bool) async {
        let requests = await selectedResourceRequests(options: options)
        for role in [SelectedModelWarmup.Role.dictation, .refine, .meetingSummary] {
            await warmup.setRequested(requests[role] ?? [], for: role, inBackground: inBackground)
        }
    }
    func selectedResourceRequests(options: CleanupOptions) async -> [SelectedModelWarmup.Role: [SelectedModelWarmup.Resource]] {
        let speech = await speechResource()
        let refine = await cleanupResource(backend: options.backend)
        let meeting = await cleanupResource(backend: meetingSettings.backend)
        var dictation = [speech] + (options.enabled ? [refine] : [])
        if options.enabled, options.backend == .coreML, await effectiveDictationBackend(options: options) == .foundationModels {
            dictation.append(await cleanupResource(backend: .foundationModels))
        }
        return [.dictation: dictation, .refine: [refine], .meetingSummary: [meeting]]
    }

    /// Admission awaits only resources required by dictation; Refine and meetings prepare independently.
    public func prepareSelectedModels(options: CleanupOptions, inBackground: Bool) async throws {
        await reconcileSelectedModels(options: options, inBackground: inBackground)
        let effective = await effectiveDictationBackend(options: options)
        if effective == .foundationModels && options.backend == .coreML && options.enabled {
            let speech = await speechResource(), local = await cleanupResource(backend: .coreML)
            let foundation = await cleanupResource(backend: .foundationModels)
            await warmup.setRequested([speech, local, foundation], for: .dictation, inBackground: inBackground)
        }
        let keys = await dictationKeys(options: options, backend: effective)
        try await warmup.prepare(keys: keys, inBackground: inBackground)
    }
    public func selectedModelsAreWarm(options: CleanupOptions) async -> Bool {
        await warmup.isReady(for: dictationKeys(options: options, backend: effectiveDictationBackend(options: options)))
    }
    private func dictationKeys(options: CleanupOptions, backend: CleanupBackendChoice) async -> Set<String> {
        var keys: Set<String> = [await speechResource().key]
        if options.enabled { keys.insert(await cleanupResource(backend: backend).key) }
        return keys
    }
    private func effectiveDictationBackend(options: CleanupOptions) async -> CleanupBackendChoice {
        cleanupPreparation.foundationAvailable = await foundationResources.availability.isAvailable
        guard options.enabled, options.backend == .coreML, let id = selected(.cleanup),
              CoreMLModels.spec(id: id) != nil, case .installed = await manager.state(of: id),
              !(await warmup.isReady(for: ["cleanup:" + id])),
              cleanupPreparation.foundationAvailable else { return options.backend }
        return .foundationModels
    }

    /// A new dictation freezes the exact admitted backend object; later readiness affects the next run.
    public func acquireDictationCleanup(options: CleanupOptions, inBackground: Bool) async throws -> CleanupRunLease? {
        guard options.enabled else { return nil }
        let selectedID = selected(.cleanup)
        try await prepareSelectedModels(options: options, inBackground: inBackground)
        let backend = await effectiveDictationBackend(options: options)
        let resource = await cleanupResource(backend: backend)
        // Reconcile may have removed the bridge if Core ML became ready meanwhile. Re-registering the
        // effective resource is safe and preserves the selected local preparation independently.
        if backend == .foundationModels && options.backend == .coreML {
            await warmup.setRequested([await speechResource(), await cleanupResource(backend: .coreML), resource],
                                     for: .dictation, inBackground: inBackground)
        }
        let lease = try await warmup.acquire(keys: [resource.key], inBackground: inBackground)
        do {
            try Task.checkCancellation()
            guard options.backend != .coreML || selected(.cleanup) == selectedID else { throw CancellationError() }
            let resolution = await cleanup.resolve(preference: backend.preference)
            try Task.checkCancellation()
            guard options.backend != .coreML || selected(.cleanup) == selectedID else { throw CancellationError() }
            cleanupPreparation.usingFoundationModels = backend == .foundationModels && options.backend == .coreML
            return CleanupRunLease(resolution: resolution, release: { [weak self] in
                await lease.release()
                await self?.dictationCleanupEnded()
            })
        } catch { await lease.release(); throw error }
    }
    private func dictationCleanupEnded() { cleanupPreparation.usingFoundationModels = false }

    public func retryCleanupPreparation(inBackground: Bool) async {
        guard let id = selected(.cleanup), case .installed = await manager.state(of: id),
              case .failed = await warmup.state(for: "cleanup:" + id), !inBackground else { return }
        cleanupPreparation.message = nil
        await warmup.retry(keys: ["cleanup:" + id], inBackground: false)
    }

    public func releaseSelectedModels() async {
        cleanupPreparation.state = .idle
        cleanupPreparation.message = nil
        cleanupPreparation.usingFoundationModels = false
        await warmup.invalidate()
    }
    public func cleanupChoice(for modelID: String) -> CleanupBackendChoice { .coreML }

    public func acquireSummaryBackend(backend: CleanupBackendChoice, inBackground: Bool) async throws -> SummaryBackendLease {
        let id = selected(.cleanup)
        let resource = await cleanupResource(backend: backend)
        await warmup.setRequested([resource], for: .meetingSummary, inBackground: inBackground)
        let lease = try await warmup.acquire(keys: [resource.key], inBackground: inBackground)
        let model: any LLMBackend
        if backend == .foundationModels { model = foundationResources }
        else if let id, let spec = CoreMLModels.spec(id: id) {
            model = await CoreMLModelStore.shared.backend(for: spec, root: modelRoot)
        } else {
            await lease.release()
            throw LLMError.unavailable(reason: "Choose a Core ML model in Legato.")
        }
        guard await model.availability.isAvailable else {
            await lease.release()
            throw LLMError.unavailable(reason: "The selected summary model is unavailable. Open Legato to prepare it.")
        }
        return SummaryBackendLease(backend: model, release: { await lease.release() })
    }
    public func acquireRefine(options: CleanupOptions, inBackground: Bool) async throws -> SelectedModelWarmup.Lease {
        let resource = await cleanupResource(backend: options.backend)
        await warmup.setRequested([resource], for: .refine, inBackground: inBackground)
        return try await warmup.acquire(keys: [resource.key], inBackground: inBackground)
    }

    private func speechResource() async -> SelectedModelWarmup.Resource {
        if let resourceOverrides { return resourceOverrides.speech }
        let root = modelRoot, speech = speechResources, locale = Self.singleLocale(engineSettings)
        if let id = selected(.liveDictation), let installer = FluidAudioCatalog.installers()[id],
           case .installed = await manager.state(of: id) {
            let folder = installer.installFolder(root: root)
            return .init(key: "speech:" + id, prewarm: {
                try await FluidAudioModels.prewarmSelected(id: id, root: root)
            }, release: { await FluidAudioModels.release(folder: folder) })
        }
        return .init(key: "speech:apple:" + (locale?.identifier ?? "auto"), prewarm: {
            try await speech.prewarmResources(locale: locale)
        }, release: { await speech.releaseWarmResources() })
    }
    private func cleanupResource(backend: CleanupBackendChoice) async -> SelectedModelWarmup.Resource {
        let root = modelRoot, manager = self.manager, fallback = foundationResources, nativeOverrides = resourceOverrides
        if backend == .foundationModels {
            return .init(key: "cleanup:foundation-models", prewarm: {
                if await fallback.availability.isAvailable { try await fallback.prewarmResources() }
            }, release: { await fallback.releaseWarmResources() })
        }
        let id = selected(.cleanup) ?? "unselected", key = "cleanup:" + (selected(.cleanup) ?? "unselected")
        if cleanupPreparation.modelID != id {
            cleanupPreparation.modelID = id
            cleanupPreparation.state = .idle
            cleanupPreparation.message = nil
        }
        if case .installed = await manager.state(of: id) { } else {
            if await warmup.isReady(for: [key]) { await warmup.revoke(key: key) }
            setCleanupPreparation(id: id, state: .missing, message: "Choose and install the selected Core ML model in Legato.")
        }
        return .init(key: key, prewarm: { [weak self] in
            guard case .installed = await manager.state(of: id), let spec = CoreMLModels.spec(id: id) else {
                await self?.setCleanupPreparation(id: id, state: .missing, message: "Choose and install the selected Core ML model in Legato.")
                throw LLMError.unavailable(reason: "Choose and install the selected Core ML model in Legato before preparation.")
            }
            await self?.setCleanupPreparation(id: id, state: .preparing, message: nil)
            do {
                if let nativeOverrides { try await nativeOverrides.coreML(id, root).prewarmResources() }
                else { try await CoreMLModelStore.shared.backend(for: spec, root: root).prepare() }
                try Task.checkCancellation()
                await self?.setCleanupPreparation(id: id, state: .ready, message: nil)
            } catch is CancellationError { throw CancellationError() }
            catch {
                await self?.setCleanupPreparation(id: id, state: .failed,
                    message: "The selected cleanup model could not be prepared. Apple Foundation Models will be used when available. Retry preparation in Legato.")
                throw error
            }
        }, release: {
            if let nativeOverrides { await nativeOverrides.coreML(id, root).releaseWarmResources() }
            else if let spec = CoreMLModels.spec(id: id) { await CoreMLModels.release(folder: spec.folder(root: root)) }
        })
    }

    private func setCleanupPreparation(id: String, state: CleanupPreparationStatus.State, message: String?) {
        guard selected(.cleanup) == id else { return }
        cleanupPreparation.modelID = id
        cleanupPreparation.state = state
        cleanupPreparation.message = message
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

    /// Back to the zero-download default for `role` (Apple Speech, or no local cleanup model): cancels a pick in
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
