import Foundation
import Synchronization

/// Remembers request ids already acted on. A request can arrive twice (the URL that opened the app and
/// the Darwin note plus inbox entry the keyboard also sent); only the first is admitted.
public final class RequestLedger: Sendable {
    private let capacity: Int
    private let maxAge: TimeInterval
    private let seen = Mutex<[String]>([])

    public init(capacity: Int = 64, maxAge: TimeInterval = LinkChannel.requestMaxAge) {
        self.capacity = max(capacity, 1)
        self.maxAge = maxAge
    }

    /// True the first time `id` is seen. The oldest ids are forgotten beyond the capacity.
    public func admit(id: String) -> Bool {
        seen.withLock { ids in
            guard !ids.contains(id) else { return false }
            ids.append(id)
            if ids.count > capacity { ids.removeFirst(ids.count - capacity) }
            return true
        }
    }

    public func contains(id: String) -> Bool { seen.withLock { $0.contains(id) } }

    /// An inbox request: admitted once, and only while it is recent (an old leftover must not start a dictation).
    public func admit(_ request: KeyboardRequest, now: Date) -> Bool {
        guard now.timeIntervalSince(request.at) <= maxAge else { return false }
        return admit(id: request.id)
    }
}
