import Foundation
import Synchronization

/// Where the user's Claude API key lives. The Keychain in the apps (``KeychainKeyStore``), memory in tests.
public protocol APIKeyStore: Sendable {
    /// The stored key, or `nil` when there is none.
    func apiKey() throws -> String?
    func save(apiKey: String) throws
    func deleteKey() throws
}

/// A key store that keeps the key in memory only.
public final class InMemoryAPIKeyStore: APIKeyStore {
    private let key: Mutex<String?>

    public init(apiKey: String? = nil) { key = Mutex(apiKey) }

    public func apiKey() throws -> String? { key.withLock { $0 } }
    public func save(apiKey: String) throws { key.withLock { $0 = apiKey } }
    public func deleteKey() throws { key.withLock { $0 = nil } }
}
