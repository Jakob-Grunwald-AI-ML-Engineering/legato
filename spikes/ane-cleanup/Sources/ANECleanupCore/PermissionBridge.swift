import Foundation

/// Objective-C permission completions may run on any queue; neither closure inherits a UI actor.
public enum PermissionBridge {
    public nonisolated static func request(_ register: @Sendable (@escaping @Sendable (Bool) -> Void) -> Void) async -> Bool {
        await withCheckedContinuation { continuation in
            register { @Sendable granted in continuation.resume(returning: granted) }
        }
    }
}
