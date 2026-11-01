#if LEGATO_INTERNAL
import Foundation
import LegatoAppServices

@MainActor enum SessionProbe {
    // Session probe: no model backends remain in the shell.
    static func start() throws { throw SessionProbeError.noBackends }
}
#endif
