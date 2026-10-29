import Foundation

/// Decides what an iOS memory warning does. The warning is system-wide and can arrive while Legato still has
/// gigabytes available, so models are released only when app-available memory is below ``floorBytes``, and a
/// load in progress is never cancelled: a release that would hit one waits for the load to finish.
@MainActor public final class MemoryWarningPolicy {
    /// Internal-tunable: below this much available memory a warning releases the models.
    public static let floorBytes: UInt64 = 400 * 1_048_576

    private let availableMemory: () -> UInt64
    private let isLoading: () -> Bool
    private let release: () async -> Void
    private let log: (String) -> Void
    private var releasePending = false

    public init(availableMemory: @escaping () -> UInt64, isLoading: @escaping () -> Bool,
                release: @escaping () async -> Void, log: @escaping (String) -> Void) {
        self.availableMemory = availableMemory
        self.isLoading = isLoading
        self.release = release
        self.log = log
    }

    public func handleWarning() async {
        let available = availableMemory()
        guard available < Self.floorBytes else { record(available, released: false); return }
        if isLoading() {
            releasePending = true
            log("memory.warning available=\(available / 1_048_576) action=deferred")
            return
        }
        record(available, released: true)
        await release()
    }

    /// Call when a load ends; completes a release deferred by a warning if memory is still below the floor.
    public func loadFinished() async {
        guard releasePending, !isLoading() else { return }
        releasePending = false
        let available = availableMemory()
        guard available < Self.floorBytes else { record(available, released: false); return }
        record(available, released: true)
        await release()
    }

    private func record(_ available: UInt64, released: Bool) {
        log("memory.warning available=\(available / 1_048_576) action=\(released ? "released" : "kept")")
    }
}
