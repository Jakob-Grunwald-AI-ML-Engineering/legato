import Foundation

/// What a catalog model is used for. Mirrors the three places the package consumes models.
public enum ModelKind: String, Sendable, Hashable, CaseIterable {
    /// A speech recognizer that emits partials while audio arrives (live dictation).
    case speechStreaming
    /// A speech recognizer that transcribes a finished recording (meeting post-pass).
    case speechBatch
    /// A language model used for text cleanup.
    case llm
}

/// An OS family a model can run on. Lets the iPhone list only the models flagged for it.
public enum ModelPlatform: String, Sendable, Hashable, CaseIterable {
    case iOS
    case macOS

    /// The platform this binary was built for.
    public static var current: ModelPlatform {
        #if os(macOS)
        .macOS
        #else
        .iOS
        #endif
    }
}

/// One selectable job a model can be picked for. Each role accepts exactly one ``ModelKind``.
public enum ModelRole: String, Sendable, Hashable, CaseIterable {
    /// The engine that transcribes while the user speaks.
    case liveDictation
    /// The batch model that re-transcribes a finished meeting recording.
    case postPass
    /// The language model that cleans up dictated text.
    case cleanup

    /// The only model kind this role accepts.
    public var kind: ModelKind {
        switch self {
        case .liveDictation: .speechStreaming
        case .postPass: .speechBatch
        case .cleanup: .llm
        }
    }
}

/// A downloadable model: one descriptor per folder on disk.
///
/// The `id` is the catalog key, the key of the installer in ``ModelManager`` and the value that
/// ``SelectionStore`` persists, so it must stay stable across releases.
public struct ModelDescriptor: Sendable, Hashable, Identifiable {
    public let id: String
    public let kind: ModelKind
    public let displayName: String
    /// Approximate download size, shown before the user commits to a pick.
    public let approxBytes: Int64
    /// BCP-47 tags the model can transcribe or write; empty when not language-specific.
    public let languages: [String]
    public let licence: String
    public let platforms: Set<ModelPlatform>
    /// The model family (for example "nemotron-latin"), for grouping in a picker. Descriptors that share a
    /// family and carry a ``tierMs`` are latency tiers of one model (see ``ModelFamily``).
    public let family: String
    /// The family's display name ("Nemotron Latin"); `displayName` when `nil`.
    public let familyName: String?
    /// The audio chunk this tier works on, in milliseconds: smaller answers sooner and is less accurate.
    /// `nil` for a model that is not a tier of a family.
    public let tierMs: Int?

    public init(
        id: String,
        kind: ModelKind,
        displayName: String,
        approxBytes: Int64,
        languages: [String] = [],
        licence: String,
        platforms: Set<ModelPlatform> = [.iOS, .macOS],
        family: String,
        familyName: String? = nil,
        tierMs: Int? = nil
    ) {
        self.id = id
        self.kind = kind
        self.displayName = displayName
        self.approxBytes = approxBytes
        self.languages = languages
        self.licence = licence
        self.platforms = platforms
        self.family = family
        self.familyName = familyName
        self.tierMs = tierMs
    }

    /// Whether the model is flagged to run on `platform`.
    public func supports(_ platform: ModelPlatform = .current) -> Bool {
        platforms.contains(platform)
    }
}

/// Where a model is in its life on this device.
public enum ModelState: Sendable, Hashable {
    case notInstalled
    /// Downloading; the value is the fraction done, in `0...1`.
    case downloading(Double)
    /// Downloaded and compiling for the Neural Engine for the first time.
    case warming
    /// Ready to use; `bytes` is the size of its folder on disk.
    case installed(bytes: Int64)
    /// The last install failed; the message is for display. Installing again retries.
    case failed(String)

    /// Whether an install that reached this state is over.
    public var isTerminal: Bool {
        switch self {
        case .notInstalled, .installed, .failed: true
        case .downloading, .warming: false
        }
    }
}

/// Why a ``ModelManager`` call could not do what was asked.
public enum ModelError: Error, Sendable, Hashable {
    /// No catalog entry (or no installer) for this id.
    case unknownModel(String)
    /// The model's kind does not fit the role it was picked for.
    case wrongKind(model: String, role: ModelRole)
    /// The install failed; the message is the installer's.
    case installFailed(model: String, message: String)
    /// The install was cancelled before the model became usable.
    case cancelled(model: String)
}
