#if os(macOS)
import CoreGraphics
import Darwin
import Foundation
import Synchronization

/// Reads how busy the Mac is and how long the user has been away, for deciding when heavy background work may run.
public final class MacActivitySampler: Sendable {
    private let previous = Mutex<(busy: UInt64, total: UInt64)?>(nil)

    public init() {}

    /// System-wide CPU load, 0 to 1, since the previous call (since boot on the first). 0 when the kernel will not say.
    public func cpuLoad() -> Double {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard status == KERN_SUCCESS else { return 0 }
        let ticks = [info.cpu_ticks.0, info.cpu_ticks.1, info.cpu_ticks.2, info.cpu_ticks.3].map(UInt64.init)
        let idle = ticks[Int(CPU_STATE_IDLE)]
        let total = ticks.reduce(0, +)
        let busy = total - idle
        let before = previous.withLock { state -> (busy: UInt64, total: UInt64)? in
            defer { state = (busy, total) }
            return state
        }
        let dBusy = busy - (before?.busy ?? 0), dTotal = total - (before?.total ?? 0)
        return dTotal == 0 ? 0 : min(1, Double(dBusy) / Double(dTotal))
    }

    /// Seconds since the last keyboard, mouse or trackpad event of the session.
    public func secondsSinceInput() -> TimeInterval {
        let types: [CGEventType] = [.keyDown, .mouseMoved, .leftMouseDown, .rightMouseDown, .scrollWheel]
        return types.map { CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0) }.min() ?? 0
    }
}
#endif
