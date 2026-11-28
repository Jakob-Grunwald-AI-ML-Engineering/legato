import Foundation

/// Runs a reload one at a time. A reload asked for while one runs makes it run once more afterwards (several such
/// asks fold into that one), and every caller returns only after a read that began after its ask. So an older read
/// never lands after a newer one, and a save the caller just made is always seen.
@MainActor public final class SerialReload {
    private var running: Task<Void, Never>?
    private var again = false

    public init() {}

    public func run(_ reload: @escaping @MainActor () async -> Void) async {
        if let running {
            again = true
            await running.value
            return
        }
        // The task clears itself in the same step as its last check: an ask after that starts a new one.
        let task = Task {
            repeat {
                again = false
                await reload()
            } while again
            running = nil
        }
        running = task
        await task.value
    }
}
