import Foundation
import Synchronization

/// Coalesces user language choices until the driver reaches a safe segment boundary.
final class LiveLanguageUpdates: Sendable {
    struct Update: Sendable { let revision: Int; let preferred: [Locale] }
    private let state = Mutex(Update(revision: 0, preferred: []))

    func request(_ locale: Locale?) {
        state.withLock { $0 = Update(revision: $0.revision + 1, preferred: locale.map { [$0] } ?? []) }
    }

    func newer(than revision: Int) -> Update? {
        state.withLock { $0.revision > revision ? $0 : nil }
    }
}
