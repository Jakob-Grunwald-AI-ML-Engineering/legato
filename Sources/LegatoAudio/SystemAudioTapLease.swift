#if os(macOS)
import Foundation
import LegatoCore
import Synchronization

/// A fully built tap belongs to one attempt, even when that attempt finishes after a newer start.
/// Closing a lease is idempotent; its native IO block stays alive until the IOProc is destroyed.
final class SystemAudioTapLease: Sendable {
    let needsRebuild: @Sendable () -> Bool
    private let cleanup: Mutex<(@Sendable () -> Void)?>

    init(needsRebuild: @escaping @Sendable () -> Bool = { false }, close: @escaping @Sendable () -> Void) {
        self.needsRebuild = needsRebuild
        cleanup = Mutex(close)
    }
    func close() {
        let action = cleanup.withLock { action in defer { action = nil }; return action }
        action?()
    }
    deinit { close() }
}

typealias SystemAudioTapBuilder = @Sendable (AudioFormatSpec, @escaping @Sendable (AudioChunk) -> Void) async throws -> SystemAudioTapLease
#endif
