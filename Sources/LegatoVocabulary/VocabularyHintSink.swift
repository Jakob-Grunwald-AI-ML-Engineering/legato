/// Where a hint list is going; each destination has its own length floor.
public enum VocabularyHintSink: Sendable, Equatable, CaseIterable {
    /// Nemotron's custom-vocabulary boosting. Skips terms shorter than 3 letters.
    case nemotron
    /// Apple Speech's contextual strings. Also takes 2-letter all-caps acronyms.
    case appleSpeech
    /// The cleanup model's `<terms>` line. Also takes 2-letter all-caps acronyms.
    case soniox
    case cleanup
}
