import Foundation
import Security

/// The Claude API key in the Keychain: a generic password that stays on this device and is readable after
/// the first unlock (so a background meeting summary can use it).
///
/// Not unit-tested against the real Keychain: the command-line test runner has no entitlements. Use
/// ``InMemoryAPIKeyStore`` in tests.
public struct KeychainKeyStore: APIKeyStore {
    public static let service = "de.gruenwald.legato.claude"

    public struct KeychainError: Error, Equatable {
        public let status: OSStatus
    }

    private let account: String
    private let accessGroup: String?

    /// - Parameter accessGroup: the Keychain access group to share the key through (the phone app and its
    ///   extensions); `nil` keeps it private to the app.
    public init(account: String = "api-key", accessGroup: String? = nil) {
        self.account = account
        self.accessGroup = accessGroup
    }

    private var identity: [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: account,
            kSecUseDataProtectionKeychain as String: true,
        ]
        if let accessGroup { query[kSecAttrAccessGroup as String] = accessGroup }
        return query
    }

    public func apiKey() throws -> String? {
        var query = identity
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw KeychainError(status: status) }
        return String(data: data, encoding: .utf8)
    }

    public func save(apiKey: String) throws {
        let data = Data(apiKey.utf8)
        let update = SecItemUpdate(identity as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw KeychainError(status: update) }
        var item = identity
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    public func deleteKey() throws {
        let status = SecItemDelete(identity as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
    }
}
