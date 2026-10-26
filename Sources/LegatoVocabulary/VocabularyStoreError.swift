import Foundation

/// Why a ``VocabularyStore`` call failed.
public enum VocabularyStoreError: Error, Sendable, Equatable {
    /// The file carries a schema version this build does not know. It is left untouched.
    case unsupportedVersion(Int)
    /// No entry has the given id.
    case notFound(UUID)
    /// Another entry already has the text.
    case duplicate(String)
}
