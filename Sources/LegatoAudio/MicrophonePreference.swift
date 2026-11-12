import Foundation

/// Which microphone a capture asks `AutomaticInputSource` for.
///
/// - `automatic`: Legato's ranking (`AudioInputCandidate.ordered`): built-in, then wired or USB, then Bluetooth
///   (AirPods), then a Continuity iPhone or iPad. The system default is ignored, so an iPhone that macOS made the
///   default does not take over.
/// - `systemDefault`: the system's default input first.
/// - `device`: one input by its persistent UID (Core Audio's device UID on the Mac). When it is gone or fails, the
///   capture continues as `automatic`.
public enum MicrophonePreference: Equatable, Sendable {
    case automatic, systemDefault, device(uid: String)

    /// The stored form: `automatic`, `system` or `device:<uid>`.
    public var storageValue: String {
        switch self {
        case .automatic: "automatic"
        case .systemDefault: "system"
        case .device(let uid): "device:" + uid
        }
    }

    /// Anything unknown or empty reads as `automatic`.
    public init(storageValue: String?) {
        switch storageValue {
        case "system": self = .systemDefault
        case let value? where value.hasPrefix("device:") && value.count > "device:".count:
            self = .device(uid: String(value.dropFirst("device:".count)))
        default: self = .automatic
        }
    }

    /// The dictation microphone setting (Mac Settings, Dictation).
    public static let dictationKey = "dictation.microphone"
    /// The name of the device last chosen, to label it in Settings while it is disconnected.
    public static let dictationNameKey = "dictation.microphone.name"
    public static func dictation(in defaults: UserDefaults = .standard) -> Self {
        Self(storageValue: defaults.string(forKey: dictationKey))
    }
}

extension AudioInputCandidate {
    /// The order a capture tries inputs in under `preference`. Automatic is `ordered(_:)`. An explicit choice (the
    /// system default, or a device by UID) goes first when it is present and can deliver audio, whatever its kind;
    /// the automatic order follows as the fallback. `defaultID` is the `id` of the system's default input.
    public static func ordered(_ inputs: [Self], preference: MicrophonePreference, defaultID: String?) -> [Self] {
        let automatic = ordered(inputs)
        let chosen: Self?
        switch preference {
        case .automatic: return automatic
        case .systemDefault: chosen = defaultID.flatMap { id in inputs.first { $0.id == id } }
        case .device(let uid): chosen = inputs.first { ($0.uid ?? $0.id) == uid }
        }
        guard let chosen, chosen.isSelectable else { return automatic }
        return [chosen] + automatic.filter { $0.id != chosen.id }
    }

    /// Inputs a user may pick by name: present and delivering at least one channel at a real rate. Wider than
    /// `isUsable`, which also leaves out aggregate and virtual devices from the automatic choice.
    public var isSelectable: Bool {
        available && !id.isEmpty && (channels.map { $0 > 0 } ?? true) && (sampleRate.map { $0.isFinite && $0 > 0 } ?? true)
    }

    /// The UID a preference stores for this input.
    public var preferenceUID: String { uid ?? id }
}
