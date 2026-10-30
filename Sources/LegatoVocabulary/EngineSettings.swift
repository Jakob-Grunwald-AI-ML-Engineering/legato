import Foundation

/// Live-engine tunables that persist in an injected `UserDefaults`. The chunk tier is not here: it is the
/// chosen catalog id.
public struct EngineSettings: Sendable {
    // UserDefaults is documented thread-safe but not annotated Sendable.
    nonisolated(unsafe) private let defaults: UserDefaults
    private let prefix: String

    public init(defaults: UserDefaults = .standard, prefix: String = "legato.engine.") {
        self.defaults = defaults
        self.prefix = prefix
    }

    /// Languages to expect while dictating. Empty means `auto`; one is that language hint.
    public var preferredLocales: [Locale] {
        get { (defaults.stringArray(forKey: prefix + "preferredLocales") ?? []).map(Locale.init(identifier:)) }
        nonmutating set { defaults.set(newValue.map(\.identifier), forKey: prefix + "preferredLocales") }
    }

    /// Silence, in milliseconds, that ends a live segment.
    public var silenceMs: Int {
        get {
            let stored = defaults.integer(forKey: prefix + "silenceMs")
            return stored > 0 ? stored : 1200
        }
        nonmutating set { defaults.set(max(newValue, 1), forKey: prefix + "silenceMs") }
    }
}

