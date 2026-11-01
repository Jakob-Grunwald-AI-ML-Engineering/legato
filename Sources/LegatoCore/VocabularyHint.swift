import Foundation

/// A term the user wants recognised and spelled correctly, as an engine or the cleanup model should see it.
///
/// Hints carry **correct surfaces only**. Known mishearings ("kloud" for "Claude") never belong here: the
/// engines boost and may emit every string they are given, so a mishearing would be produced as written.
public struct VocabularyHint: Sendable, Hashable {
    /// The preferred spelling.
    public let text: String
    /// Alternative *correct* spellings of the same term (for example "Grunwald" next to "Grünwald").
    public let spellings: [String]

    public init(text: String, spellings: [String] = []) {
        self.text = text
        self.spellings = spellings
    }
}

/// Who a hint list is for. Each sink has its own length floors, applied by the provider before the cap.
public enum HintSink: Sendable {
    /// Nemotron custom-vocabulary biasing.
    case nemotron
    /// `SpeechAnalyzer` contextual strings.
    case appleSpeech
    /// The cleanup model's term list.
    case soniox
    case cleanup
}

/// Supplies vocabulary hints to the engines. The engine modules depend on this protocol only, never on the
/// vocabulary module itself.
public protocol VocabularyHintProvider: Sendable {
    /// At most `limit` hints for `sink`, best first.
    func hints(for sink: HintSink, limit: Int) async -> [VocabularyHint]
}
