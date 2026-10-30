import Foundation

/// Legacy style tags retained for vocabulary correction evidence and persisted history.
public enum CleanupStyle: String, Sendable, Equatable, CaseIterable, Codable {
    case verbatim, message, markdown
}
