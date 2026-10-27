import Foundation

/// Completes a partly typed word from a dictionary, asynchronously because the platform checkers live on the main actor.
///
/// Language codes are bare ("de", "en"). An implementation returns its completions best first, with the
/// languages interleaved so that no language crowds out another.
public protocol WordCompleting: Sendable {
    func completions(prefix: String, languages: [String]) async -> [String]
}
