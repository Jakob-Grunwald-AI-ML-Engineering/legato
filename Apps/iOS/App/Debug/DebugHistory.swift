#if DEBUG || LEGATO_INTERNAL
import Foundation
import LegatoDevHarness

/// Exact-ID diagnostics through the existing persisted History owner. Never lists other entries.
@MainActor enum DebugHistory {
    static func register(_ harness: DevHarness) {
        harness.register("history-entry") { command in
            guard command.args.count == 1, let id = UUID(uuidString: command.args[0]) else { throw Failure.invalidID }
            guard let entry = try await AppController.shared.history.recent(limit: Int.max).first(where: { $0.id == id }) else {
                return ["found": false, "id": id.uuidString]
            }
            let data = try JSONEncoder().encode(entry)
            let object = try JSONSerialization.jsonObject(with: data)
            return ["found": true, "entry": object]
        }
    }
    private enum Failure: Error { case invalidID }
}
#endif
