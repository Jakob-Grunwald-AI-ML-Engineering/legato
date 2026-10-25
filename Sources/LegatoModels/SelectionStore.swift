import Foundation

/// Persists which catalog model the user picked for each ``ModelRole``.
///
/// Backed by an injected `UserDefaults` (the apps pass their App Group suite) under a key prefix. A role
/// with no entry means "use the zero-download default" (Apple Speech, Apple Foundation Models).
public struct SelectionStore: Sendable {
    // UserDefaults is documented thread-safe but not annotated Sendable.
    nonisolated(unsafe) private let defaults: UserDefaults
    private let prefix: String

    public init(defaults: UserDefaults = .standard, prefix: String = "legato.model.selection.") {
        self.defaults = defaults
        self.prefix = prefix
    }

    /// The persisted model id for `role`, if the user has picked one.
    public func selected(for role: ModelRole) -> String? {
        defaults.string(forKey: key(role))
    }

    /// Persists `id` for `role`; `nil` clears it back to the default.
    public func set(_ id: String?, for role: ModelRole) {
        if let id {
            defaults.set(id, forKey: key(role))
        } else {
            defaults.removeObject(forKey: key(role))
        }
    }

    private func key(_ role: ModelRole) -> String { prefix + role.rawValue }
}
