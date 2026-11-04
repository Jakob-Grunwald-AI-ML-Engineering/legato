#if LEGATO_INTERNAL
import Foundation
import LegatoClaude
import LegatoSoniox

/// Faults for acceptance runs, from launch arguments only, in `LEGATO_INTERNAL` builds only. They change what the meeting
/// services see, never what is stored in the Keychain.
/// - `-LegatoMeetingsDropSonioxAfter <seconds>`: closes the first real Soniox socket that long after it connects, once, so
///   the real reconnect path runs against the real service.
/// - `-LegatoMeetingsNoSonioxKey`, `-LegatoMeetingsNoClaudeKey`: that key reads as missing.
enum MeetingsFaults {
    private static var arguments: [String] { CommandLine.arguments }
    static var noSonioxKey: Bool { arguments.contains("-LegatoMeetingsNoSonioxKey") }
    static var noClaudeKey: Bool { arguments.contains("-LegatoMeetingsNoClaudeKey") }
    static var dropSonioxAfter: Double? {
        guard let index = arguments.firstIndex(of: "-LegatoMeetingsDropSonioxAfter"), arguments.indices.contains(index + 1),
              let seconds = Double(arguments[index + 1]), seconds > 0 else { return nil }
        return seconds
    }

    /// Reads no Claude key and stores nothing.
    struct NoClaudeKey: APIKeyStore {
        func apiKey() throws -> String? { nil }
        func save(apiKey: String) throws {}
        func deleteKey() throws {}
    }

    /// A real Soniox socket that is closed once, `seconds` after the first connection.
    final class DropOnce: @unchecked Sendable {
        private let lock = NSLock()
        private var spent = false
        let seconds: Double
        init(seconds: Double) { self.seconds = seconds }
        func take() -> Bool { lock.lock(); defer { lock.unlock() }; defer { spent = true }; return !spent }
    }

    struct DroppingSocket: SonioxSocket {
        let inner = URLSessionSonioxSocket()
        let plan: DropOnce
        func connect(request: URLRequest) async throws {
            try await inner.connect(request: request)
            guard plan.take() else { return }
            let inner = inner, seconds = plan.seconds
            Task { try? await Task.sleep(for: .seconds(seconds)); await inner.close() }
        }
        func send(_ frame: SonioxFrame) async throws { try await inner.send(frame) }
        func receive() async throws -> SonioxFrame { try await inner.receive() }
        func close() async { await inner.close() }
    }
}
#endif
