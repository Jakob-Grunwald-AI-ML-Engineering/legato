import Foundation
import LegatoAppleSpeech
import LegatoCore
import LegatoFluidAudio
import LegatoModels

/// Live-engine tunables that persist in an injected `UserDefaults`. The chunk tier is not here: it is the
/// chosen catalog id.
public struct EngineSettings: Sendable {
    // UserDefaults is documented thread-safe but not annotated Sendable.
    nonisolated(unsafe) private let defaults: UserDefaults
    private let prefix: String

    public init(defaults: UserDefaults = .standard, prefix: String = "legato.engine.") {
        self.defaults = defaults
        self.prefix = prefix
    }

    /// Languages to expect while dictating. Empty means `auto`; one is that language hint.
    public var preferredLocales: [Locale] {
        get { (defaults.stringArray(forKey: prefix + "preferredLocales") ?? []).map(Locale.init(identifier:)) }
        nonmutating set { defaults.set(newValue.map(\.identifier), forKey: prefix + "preferredLocales") }
    }

    /// Silence, in milliseconds, that ends a live segment.
    public var silenceMs: Int {
        get {
            let stored = defaults.integer(forKey: prefix + "silenceMs")
            return stored > 0 ? stored : FluidAudioCatalog.defaultSilenceMs
        }
        nonmutating set { defaults.set(max(newValue, 1), forKey: prefix + "silenceMs") }
    }
}

/// Why the registry returned Apple Speech although the user picked a model.
public enum EngineFallback: Error, Sendable, Equatable {
    /// The picked model is not (fully) installed; ``DictationError/assetsNotInstalled`` is the reason the
    /// coordinator surfaces.
    case assetsNotInstalled
    /// The persisted id is not a speech streaming model in this catalog.
    case unknownModel(String)

    /// The ``DictationError`` this maps to, when there is one.
    public var dictationError: DictationError? {
        switch self {
        case .assetsNotInstalled: .assetsNotInstalled
        case .unknownModel: nil
        }
    }
}

/// The live engine the registry chose and how it was configured.
public struct EngineResolution: Sendable {
    public let engine: any DictationEngine
    /// The catalog id behind `engine`; `nil` for Apple Speech.
    public let modelID: String?
    public let preferredLocales: [Locale]
    public let silenceMs: Int
    /// Why Apple Speech is in use despite a pick; `nil` when nothing was picked or the pick is live.
    public let fallback: EngineFallback?
}

/// Maps the persisted model choices to engines. Pure lookup: it never starts an install or a warm-up;
/// only ``ModelManager/select(_:role:)`` and ``ModelManager/install(_:)`` do.
public struct EngineRegistry: Sendable {
    public let models: ModelManager
    public let settings: EngineSettings

    public init(models: ModelManager, settings: EngineSettings = EngineSettings()) {
        self.models = models
        self.settings = settings
    }

    /// The live dictation engine for the persisted `.liveDictation` pick, or Apple Speech when nothing is
    /// picked, the id is unknown, or the model is not installed.
    ///
    /// `localeOverride` is the language of one meeting: it replaces the global preferred locales for this
    /// engine only (the setting is not touched). `nil` keeps the global locales.
    public func liveEngine(localeOverride: Locale? = nil) async -> EngineResolution {
        let locales = localeOverride.map { [$0] } ?? settings.preferredLocales
        let silenceMs = settings.silenceMs
        func apple(_ fallback: EngineFallback?) -> EngineResolution {
            EngineResolution(
                engine: AppleSpeechEngine(), modelID: nil, preferredLocales: locales, silenceMs: silenceMs,
                fallback: fallback)
        }
        guard let id = await models.selected(role: .liveDictation) else { return apple(nil) }
        let catalog = await models.catalog
        guard catalog.contains(where: { $0.id == id && $0.kind == .speechStreaming }),
            let engine = FluidAudioCatalog.liveEngine(
                id: id, preferredLocales: locales, silenceMs: silenceMs, models: models)
        else { return apple(.unknownModel(id)) }
        guard case .installed = await models.state(of: id) else { return apple(.assetsNotInstalled) }
        return EngineResolution(
            engine: engine, modelID: id, preferredLocales: locales, silenceMs: silenceMs, fallback: nil)
    }

    /// The batch transcriber for the persisted `.postPass` pick; `nil` when nothing is picked, the id is
    /// unknown, or the model is not installed.
    public func postPassTranscriber() async -> (any BatchTranscriber)? {
        guard let id = await models.selected(role: .postPass) else { return nil }
        let catalog = await models.catalog
        guard catalog.contains(where: { $0.id == id && $0.kind == .speechBatch }),
            case .installed = await models.state(of: id)
        else { return nil }
        return FluidAudioCatalog.batchTranscriber(id: id, models: models)
    }

    // MARK: Meeting models

    /// A fresh streaming diarizer for the meeting's live mix, or `nil` when the live speakers model is not
    /// installed. Uses the `.liveSpeakers` pick, else the catalog's one live speakers model. Each call builds
    /// a new one: two meetings never share a diarizer's state.
    public func liveDiarizer() async -> (any SpeakerDiarizer)? {
        guard let id = await installedModel(role: .liveSpeakers, fallback: FluidAudioModels.sortformerID) else { return nil }
        return FluidAudioCatalog.liveDiarizer(id: id, models: models)
    }

    /// A fresh diarizer for a finished recording, or `nil` when the
    /// after-meeting speakers model is not installed.
    public func batchDiarizer() async -> (any BatchDiarizer)? {
        guard let id = await installedModel(role: .meetingSpeakers, fallback: FluidAudioModels.diarizerOfflineID) else {
            return nil
        }
        return FluidAudioCatalog.batchDiarizer(id: id, models: models)
    }

    /// A fresh mic enhancer (echo and noise cancellation) for one meeting, or `nil` when its model is not installed.
    public func micEnhancer() async -> (any MicEnhancer)? {
        guard let id = await installedModel(role: .echoNoiseCancellation, fallback: FluidAudioModels.localVqeID) else {
            return nil
        }
        return FluidAudioCatalog.micEnhancer(id: id, models: models)
    }

    /// The model id for `role` if it is installed: the persisted pick when it is a catalog model of the role's
    /// kind, else `fallback`. Pure lookup, like the rest of the registry.
    private func installedModel(role: ModelRole, fallback: String) async -> String? {
        let catalog = await models.catalog
        var id = fallback
        if let picked = await models.selected(role: role), catalog.contains(where: { $0.id == picked && $0.kind == role.kind }) {
            id = picked
        }
        guard catalog.contains(where: { $0.id == id && $0.kind == role.kind }),
            case .installed = await models.state(of: id)
        else { return nil }
        return id
    }
}
