import Foundation
import UIKit

/// Shared permission/intent foreground transition. Retains the existing meeting admission's
/// bounded 3-second wait and 50-ms observation cadence; these are operational bounds, not measured latency.
@MainActor enum IOSForegroundAdmission {
    static func waitUntilActive(cancelled: () -> Bool = { false }) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while UIApplication.shared.applicationState == .inactive, ContinuousClock.now < deadline {
            try Task.checkCancellation()
            guard !cancelled() else { throw CancellationError() }
            try await Task.sleep(for: .milliseconds(50))
        }
        guard !cancelled(), UIApplication.shared.applicationState != .background else { throw CancellationError() }
        guard UIApplication.shared.applicationState == .active else {
            throw NSError(domain: "Recording", code: 2, userInfo: [NSLocalizedDescriptionKey: "Return to Legato and try again. Recording has not started."])
        }
    }
}
