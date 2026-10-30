#if DEBUG || LEGATO_INTERNAL
import Foundation
import LegatoAgent
import LegatoClaude

/// Internal host controls call the same session methods as the native composer surfaces.
@MainActor public extension ComposerSession {
    static let debugCommands = ["composer-debug-start", "composer-debug-frame", "composer-debug-text", "composer-stop", "composer-insert-host", "composer-cancel", "composer-tap", "composer-pick", "composer-mode", "composer-undo", "composer-state"]
    func debugControl(_ command: String, args: [String]) async throws -> [String: Any] {
        func argument(_ index: Int) throws -> String {
            guard args.indices.contains(index) else { throw DebugControlError.usage }
            return args[index]
        }
        switch command {
        case "composer-debug-start":
            guard let mode = ComposerMode(rawValue: try argument(0)), args.count <= 2,
                  args.count < 2 || args[1] == "microphone-lease" else { throw DebugControlError.usage }
            await startDebug(mode: mode, microphoneLease: args.count == 2)
            if let error { throw DebugControlError.session(error) }
        case "composer-debug-frame": try await injectDebugFrame(argument(0))
        case "composer-debug-text":
            let final = try argument(1)
            guard ["partial", "final"].contains(final), let start = Double(try argument(2)) else { throw DebugControlError.usage }
            try await injectDebugText(argument(0), isFinal: final == "final", startMs: start)
        case "composer-stop": await stop()
        case "composer-insert-host": await insert()
        case "composer-cancel": await cancel()
        case "composer-tap":
            guard let offset = Double(try argument(2)), offset.isFinite, let origin = audioOrigin else { throw DebugControlError.usage }
            try await tap(lineID: argument(0), wordID: argument(1), timestamp: origin + offset / 1000)
        case "composer-pick": try await pick(lineID: argument(0), wordID: argument(1), text: argument(2))
        case "composer-mode":
            guard let mode = ComposerMode(rawValue: try argument(0)) else { throw DebugControlError.usage }
            await setMode(mode)
        case "composer-undo": await undo()
        case "composer-state": break
        default: throw DebugControlError.usage
        }
        await refreshDebugState()
        return debugState
    }
    /// Import a private file, never a secret in bridge arguments or results. No clients are started.
    static func importDebugKeys(file: URL) throws -> [String: Any] {
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
