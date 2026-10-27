/// The cleanup style a diff came from. Only a verbatim cleanup, which fixes without rewriting, teaches the vocabulary.
public enum CleanupLearningStyle: Sendable, Equatable {
    /// Light fixes only: spelling, punctuation, the odd misheard word.
    case verbatim
    /// A rewrite; its changes say nothing about single words.
    case message
}
