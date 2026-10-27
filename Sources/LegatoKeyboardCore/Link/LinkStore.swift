import Foundation
import Synchronization

/// Where the link's JSON values live: the App Group's `UserDefaults` in the apps, memory in tests.
public protocol LinkValueStore: Sendable {
    func data(forKey key: String) -> Data?
    func set(_ data: Data?, forKey key: String)
    /// Every stored key that starts with `prefix` (the per-choice keys are listed this way).
    func keys(withPrefix prefix: String) -> [String]
}

public final class MemoryLinkStore: LinkValueStore {
    private let values = Mutex<[String: Data]>([:])
    public init() {}
    public func data(forKey key: String) -> Data? { values.withLock { $0[key] } }
    public func set(_ data: Data?, forKey key: String) { values.withLock { $0[key] = data } }
    public func keys(withPrefix prefix: String) -> [String] { values.withLock { $0.keys.filter { $0.hasPrefix(prefix) }.sorted() } }
}

/// The App Group's `UserDefaults` (thread-safe by contract, hence `@unchecked`). Read fresh after every
/// Darwin note; never cache a value across notes.
public struct UserDefaultsLinkStore: LinkValueStore, @unchecked Sendable {
    private let defaults: UserDefaults

    /// nil when the App Group is unavailable (misconfigured signing).
    public init?(suiteName: String = LinkChannel.appGroupID) {
        guard let defaults = UserDefaults(suiteName: suiteName) else { return nil }
        self.defaults = defaults
    }

    public func data(forKey key: String) -> Data? { defaults.data(forKey: key) }
    public func set(_ data: Data?, forKey key: String) {
        if let data { defaults.set(data, forKey: key) } else { defaults.removeObject(forKey: key) }
    }
    public func keys(withPrefix prefix: String) -> [String] {
        defaults.dictionaryRepresentation().keys.filter { $0.hasPrefix(prefix) }.sorted()
    }
}

/// Typed JSON access to the link values. Dates are seconds since 1970; absent optionals are omitted.
public struct LinkStore: Sendable {
    private let backing: any LinkValueStore

    public init(_ backing: any LinkValueStore) {
        self.backing = backing
    }

    public func write<T: Encodable>(_ value: T, forKey key: String) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        guard let data = try? encoder.encode(value) else { return }
        backing.set(data, forKey: key)
    }

    /// nil when nothing is stored or the stored value doesn't decode (e.g. a newer version wrote it).
    public func read<T: Decodable>(_ type: T.Type, forKey key: String) -> T? {
        guard let data = backing.data(forKey: key) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try? decoder.decode(type, from: data)
    }

    public func remove(forKey key: String) { backing.set(nil, forKey: key) }

    public func keys(withPrefix prefix: String) -> [String] { backing.keys(withPrefix: prefix) }
}
