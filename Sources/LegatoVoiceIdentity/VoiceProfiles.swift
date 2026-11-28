import Foundation

/// The microphone a voice recording came through. `kind` is `AudioInputCandidate.Kind`'s raw value (LegatoAudio
/// owns the classification) or `unknown` for a profile saved before routes were recorded.
/// `key` decides replace-versus-add: the built-in microphones of one device are one route; any other input is its
/// kind plus its name, so two headset models are two routes.
public struct VoiceInputRoute: Codable, Sendable, Hashable {
    public var kind: String
    public var name: String
    public init(kind: String, name: String) { self.kind = kind; self.name = name }
    public static let unknown = VoiceInputRoute(kind: "unknown", name: "")
    public var key: String {
        kind == "builtIn" || kind == "unknown" ? kind : "\(kind):\(name.trimmingCharacters(in: .whitespaces).lowercased())"
    }
    /// What a row shows: the device's own name, or a stand-in for a profile with no recorded route.
    public var displayName: String {
        if kind == "unknown" || name.isEmpty { return kind == "unknown" ? "Earlier setup" : "Microphone" }
        return name
    }
}

/// A place or situation the user records their voice in. It is only a name: the user speaks naturally there.
public struct VoiceSituation: Codable, Sendable, Hashable, Identifiable {
    public let id: String
    public var name: String
    public var isCustom: Bool
    public init(id: String, name: String, isCustom: Bool) { self.id = id; self.name = name; self.isCustom = isCustom }
    /// The first setup is this setting.
    public static let alone = VoiceSituation(id: "alone", name: "Alone", isCustom: false)
    public static let suggested: [VoiceSituation] = [
        alone,
        VoiceSituation(id: "office", name: "Office", isCustom: false),
        VoiceSituation(id: "train", name: "Train", isCustom: false),
        VoiceSituation(id: "car", name: "Car", isCustom: false),
        VoiceSituation(id: "tv", name: "Home with TV on", isCustom: false),
        VoiceSituation(id: "bed", name: "In bed", isCustom: false),
    ]
}

/// One hidden profile: the voice of one setting through one microphone route.
public struct VoiceProfile: Codable, Sendable, Equatable {
    public var situationID: String
    public var situationName: String
    public var route: VoiceInputRoute
    public var embedding: [Float]
    public var date: Date
    /// The model revision that produced `embedding`; profiles of another revision are not matched.
    public var revision: String
    /// The kept recording this profile was computed from, if recordings were kept.
    public var recordingID: String?
    public init(situationID: String, situationName: String, route: VoiceInputRoute, embedding: [Float], date: Date,
                revision: String, recordingID: String? = nil) {
        self.situationID = situationID; self.situationName = situationName; self.route = route
        self.embedding = embedding; self.date = date; self.revision = revision; self.recordingID = recordingID
    }
}

/// The user's voice: every profile plus the settings they named themselves. Stored as `profiles.json`.
public struct VoiceProfileSet: Codable, Sendable, Equatable {
    public var version = 2
    public var profiles: [VoiceProfile] = []
    public var customSituations: [VoiceSituation] = []
    public init(profiles: [VoiceProfile] = [], customSituations: [VoiceSituation] = []) {
        self.profiles = profiles; self.customSituations = customSituations
    }

    /// Suggested settings first, then the user's own, in the order they were added.
    public var situations: [VoiceSituation] { VoiceSituation.suggested + customSituations }

    /// Recording a setting on a route it already has replaces that profile; on another route it adds one.
    public mutating func upsert(_ profile: VoiceProfile) {
        if let index = profiles.firstIndex(where: { $0.situationID == profile.situationID && $0.route.key == profile.route.key }) {
            profiles[index] = profile
        } else { profiles.append(profile) }
    }

    /// A trimmed, non-empty name that no setting uses yet (compared case-insensitively).
    @discardableResult
    public mutating func addSituation(named name: String) -> VoiceSituation? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !situations.contains(where: { $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }) else { return nil }
        let situation = VoiceSituation(id: "custom-" + UUID().uuidString.lowercased(), name: String(trimmed.prefix(40)), isCustom: true)
        customSituations.append(situation)
        return situation
    }

    /// Only the user's own settings can be deleted; their profiles go with them.
    public mutating func removeSituation(id: String) {
        guard customSituations.contains(where: { $0.id == id }) else { return }
        customSituations.removeAll { $0.id == id }
        profiles.removeAll { $0.situationID == id }
    }

    /// The embeddings the matcher may compare against: this model revision, the expected size, finite.
    public func matchable(revision: String, dimension: Int = 192) -> [[Float]] {
        profiles.filter { $0.revision == revision && $0.embedding.count == dimension && $0.embedding.allSatisfy(\.isFinite) }
            .map(\.embedding)
    }

    /// The best cosine of a normalized `vector` against normalized profile embeddings; nil when nothing is comparable.
    public static func bestScore(_ vector: [Float], among embeddings: [[Float]]) -> Float? {
        embeddings.filter { $0.count == vector.count }
            .map { zip($0, vector).reduce(Float(0)) { $0 + $1.0 * $1.1 } }
            .max()
    }

    /// Below this best cosine to the saved profiles, a new setting recording asks whether someone else was reading.
    /// An estimate, set low on purpose: the check only asks and never rejects, and the user's own voice on another
    /// microphone has scored 0.22–0.29 against a profile from a different one, so a stricter value would ask real users.
    /// It catches only a clearly different voice: between twelve macOS `say` voices reading the setup sentences, the
    /// median score was 0.39 and only 17% of pairs fell below 0.2 (the same voice reading other text: 0.96–0.99).
    /// Calibrate it once kept recordings of real users on several microphones exist.
    public static let differentVoiceScore: Float = 0.2

    /// Whether a new recording's `embedding` sounds like someone other than the saved voice: its best match among
    /// the comparable profiles is below ``differentVoiceScore``. False when nothing can be compared (the first setup).
    public func soundsDifferent(_ embedding: [Float], revision: String) -> Bool {
        guard let best = Self.bestScore(embedding, among: matchable(revision: revision, dimension: embedding.count)) else { return false }
        return best < Self.differentVoiceScore
    }

    /// A `profile.json` from before profile sets: its one embedding becomes the Alone setting on an unknown route.
    public static func migrating(legacy data: Data, date: Date) -> VoiceProfileSet? {
        struct Legacy: Decodable { let revision: String; let embedding: [Float] }
        guard let legacy = try? JSONDecoder().decode(Legacy.self, from: data) else { return nil }
        return VoiceProfileSet(profiles: [VoiceProfile(situationID: VoiceSituation.alone.id, situationName: VoiceSituation.alone.name,
                                                       route: .unknown, embedding: legacy.embedding, date: date, revision: legacy.revision)])
    }

}

/// The JSON shape of every voice file (profiles, recording sidecars): ISO 8601 dates, sorted keys.
public enum VoiceJSON {
    public static var encoder: JSONEncoder {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
    public static var decoder: JSONDecoder {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
