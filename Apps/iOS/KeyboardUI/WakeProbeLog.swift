#if DEBUG
import Foundation
import OSLog

/// Debug builds only: the Darwin wake probe. The app logs when it posts the "text to insert" note, the
/// keyboard (a separate process) when it receives it and when it inserts the text (or why not). Every line
/// carries `t=<ms since 1970>`, so Console.app (filter: category `wake-probe`) shows the latency, and a
/// post with no `wake.recv` after it is a drop. Lines carry no user text.
enum WakeProbeLog {
    private static let logger = Logger(subsystem: "de.gruenwald.legato", category: "wake-probe")

    static func log(_ event: String, _ fields: String = "") {
        let ms = Int((Date().timeIntervalSince1970 * 1000).rounded())
        logger.notice("wake.\(event, privacy: .public) t=\(ms, privacy: .public) \(fields, privacy: .public)")
    }
}
#endif
