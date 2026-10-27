#if os(macOS)
import CoreGraphics
import Darwin
import Foundation
import Synchronization

/// One reading of the kernel's per-state CPU tick counters (summed over all cores). They are 32-bit and wrap.
public struct CPUTicks: Sendable, Equatable {
    public var user: UInt32
    public var system: UInt32
    public var idle: UInt32
    public var nice: UInt32

    public init(user: UInt32, system: UInt32, idle: UInt32, nice: UInt32) {
        self.user = user
        self.system = system
        self.idle = idle
        self.nice = nice
    }

    /// System-wide CPU load, 0 to 1, between `before` and these ticks (since boot when `before` is nil).
    /// Each counter's change is taken modulo 2^32, so a counter that wrapped still counts what passed.
    public func load(since before: CPUTicks?) -> Double {
        let then = before ?? CPUTicks(user: 0, system: 0, idle: 0, nice: 0)
        let busy = UInt64(user &- then.user) + UInt64(system &- then.system) + UInt64(nice &- then.nice)
        let total = busy + UInt64(idle &- then.idle)
        return total == 0 ? 0 : min(1, Double(busy) / Double(total))
    }
}

/// Reads how busy the Mac is and how long the user has been away, for deciding when heavy background work may run.
public final class MacActivitySampler: Sendable {
    private let previous = Mutex<CPUTicks?>(nil)

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
        let ticks = CPUTicks(
            user: info.cpu_ticks.0, system: info.cpu_ticks.1, idle: info.cpu_ticks.2, nice: info.cpu_ticks.3)
        let before = previous.withLock { state -> CPUTicks? in
            defer { state = ticks }
            return state
        }
        return ticks.load(since: before)
    }

    /// Seconds since the last keyboard, mouse or trackpad event of the session.
    public func secondsSinceInput() -> TimeInterval {
        let types: [CGEventType] = [.keyDown, .mouseMoved, .leftMouseDown, .rightMouseDown, .scrollWheel]
        return types.map { CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0) }.min() ?? 0
    }
}
#endif
