#if DEBUG || LEGATO_INTERNAL
import Foundation
import LegatoClaude

public enum DebugCredentialImport {
    /// Import a private file, never a secret in bridge arguments or results. No clients are started.
    public static func importDebugKeys(file: URL) throws -> [String: Any] {
        defer { try? FileManager.default.removeItem(at: file) }
        struct Keys: Decodable { let anthropic: String; let soniox: String }
        do {
            let keys = try JSONDecoder().decode(Keys.self, from: Data(contentsOf: file))
            guard !keys.anthropic.isEmpty, !keys.soniox.isEmpty else { throw DebugControlError.usage }
            try KeychainKeyStore().save(apiKey: keys.anthropic)
            try KeychainKeyStore(service: "de.gruenwald.legato.soniox").save(apiKey: keys.soniox)
            guard try KeychainKeyStore().apiKey() == keys.anthropic,
                  try KeychainKeyStore(service: "de.gruenwald.legato.soniox").apiKey() == keys.soniox else { throw DebugControlError.usage }
            return ["claudeStored": true, "sonioxStored": true]
        } catch let failure as KeychainKeyStore.KeychainError {
            throw DebugControlError.session("Credential import keychain status \(failure.status); private handoff file removed.")
        } catch { throw DebugControlError.session("Credential import failed; private handoff file removed.") }
    }
}
private enum DebugControlError: Error { case usage, session(String) }
#endif
