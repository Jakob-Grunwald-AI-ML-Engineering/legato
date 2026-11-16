#if DEBUG || LEGATO_INTERNAL
import Foundation
import LegatoDevHarness
import LegatoKeyboardCore

/// One raw operation per exchange, chosen interactively by the operator. Full text stays in private debug output.
@MainActor enum KeyboardProbe {
    /// Survives a host relaunch so the operator can explicitly end their lease without waiting
    /// for expiry. App-scoped development identity; another app/group cannot claim this owner.
    private static let sessionID: String = {
        let key = "debug.keyboard-probe.client"
        if let saved = UserDefaults.standard.string(forKey: key) { return saved }
        let value = UUID().uuidString
        UserDefaults.standard.set(value, forKey: key)
        return value
    }()
    private static var exchanging = false

    static func register(_ harness: DevHarness) {
        harness.register("keyboard-probe") { command in
            guard let word = command.args.first, let action = FieldProbeRequest.Action(rawValue: word),
                  let backing = UserDefaultsLinkStore() else { throw ProbeError.invalid }
            var delta = 0, delay = 0
            switch action {
            case .begin, .read, .status, .end:
                guard command.args.count == 1 else { throw ProbeError.invalid }
            case .move:
                guard (2...3).contains(command.args.count), let value = Int(command.args[1]), value != Int.min else { throw ProbeError.invalid }
                delta = value
                if command.args.count == 3 {
                    guard let value = Int(command.args[2]) else { throw ProbeError.invalid }
                    delay = value
                }
            case .pause:
                guard command.args.count == 2, let value = Int(command.args[1]) else { throw ProbeError.invalid }
                delay = value
            }
            guard (0...10_000).contains(delay) else { throw ProbeError.invalid }
            let request = FieldProbeRequest(id: command.id, sessionID: sessionID, action: action, delta: delta, milliseconds: delay)
            return try harness.acceptOperation(command, reserve: {
                guard !exchanging else { throw ProbeError.busy }
                exchanging = true
            }) {
                defer { exchanging = false }
                let channel = FieldProbeLink(store: LinkStore(backing))
                channel.request(request)
                DarwinObserver.post(FieldProbeLink.note)
                let deadline = ContinuousClock.now + .seconds(20)
                while ContinuousClock.now < deadline {
                    try Task.checkCancellation()
                    if let reply = channel.takeReply(id: request.id) {
                        let data = try JSONEncoder().encode(reply)
                        return try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
                    }
                    try await Task.sleep(for: .milliseconds(20))
                }
                channel.cancelRequest(id: request.id)
                throw ProbeError.timeout
            }
        }
    }

    private enum ProbeError: Error, CustomStringConvertible {
        case invalid, busy, timeout
        var description: String {
            switch self {
            case .invalid: "Usage: keyboard-probe begin|read|status|end, move <native delta> [settle ms], or pause <ms>; delays must be 0...10000."
            case .busy: "The previous probe operation is still running. Wait for its result before choosing the next action."
            case .timeout: "The keyboard probe did not answer. Keep the Legato keyboard visible in a nonsecure test field and the internal host running."
            }
        }
    }
}
#endif
