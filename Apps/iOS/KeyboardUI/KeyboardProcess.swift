import Darwin
import Foundation
import LegatoKeyboardCore
import UIKit

/// The keyboard process as a whole (#342): the keyboard controllers and input view controllers still alive, its memory, memory
/// warnings and blank previews. The one owner of these facts, for diagnostics and the recycle policy (`KeyboardRecyclePolicy`).
/// Everything registers weakly: this never keeps a keyboard alive.
@MainActor
enum KeyboardProcess {
    /// A count of what is alive, for diagnostics. No user text.
    struct Census: Codable, Equatable {
        /// Controller objects alive, torn down or not.
        var controllers: Int
        var visible: Int
        /// Alive, not torn down, not visible: the one just hidden, one UIKit may show again, or a leak.
        var hidden: Int
        /// Input view controllers alive whose view loaded, and those whose view is in a window.
        var hosts: Int
        var hostsInWindow: Int
        var memoryWarnings: Int
        var previewBlanks: Int
        var uptimeSeconds: Int
    }

    private struct WeakController { weak var value: KeyboardController? }
    private struct WeakHost { weak var value: UIViewController? }

    private static var controllers: [WeakController] = []
    private static var hosts: [WeakHost] = []
    private(set) static var memoryWarnings = 0
    private(set) static var previewBlanks = 0
    private static var lastPreviewBlankRecord: TimeInterval?
    /// Touched by the first registration, which comes with the extension's first view.
    private static let startedAt = ProcessInfo.processInfo.systemUptime

    static var uptime: TimeInterval { ProcessInfo.processInfo.systemUptime - startedAt }

    static func register(_ controller: KeyboardController) {
        controllers.removeAll { $0.value == nil }
        controllers.append(.init(value: controller))
    }

    static func registerHost(_ host: UIViewController) {
        _ = startedAt
        hosts.removeAll { $0.value == nil }
        hosts.append(.init(value: host))
    }

    static func noteMemoryWarning() { memoryWarnings += 1 }

    /// Counts a blank preview; true when it should also be written to the diagnostics (at most one every
    /// `previewBlankRecordInterval`, so a preview that stays blank does not flood the file).
    static func notePreviewBlank() -> Bool {
        previewBlanks += 1
        let now = ProcessInfo.processInfo.systemUptime
        if let last = lastPreviewBlankRecord, now - last < previewBlankRecordInterval { return false }
        lastPreviewBlankRecord = now
        return true
    }
    static let previewBlankRecordInterval: TimeInterval = 10

    private static var liveControllers: [KeyboardController] {
        controllers.removeAll { $0.value == nil }
        return controllers.compactMap(\.value)
    }

    static var census: Census {
        let all = liveControllers
        hosts.removeAll { $0.value == nil }
        let loaded = hosts.compactMap(\.value).filter(\.isViewLoaded)
        return Census(controllers: all.count, visible: all.filter(\.isVisible).count,
                      hidden: all.filter { !$0.isVisible && !$0.isTornDown }.count,
                      hosts: loaded.count, hostsInWindow: loaded.filter { $0.viewIfLoaded?.window != nil }.count,
                      memoryWarnings: memoryWarnings, previewBlanks: previewBlanks, uptimeSeconds: Int(uptime))
    }

    /// The facts the recycle policy decides on. Work is owed while a controller holds some (`KeyboardController.holdsWork`) or the
    /// app's published take is still open. A run the app holds for the keyboard's return is not open (#343): the next keyboard, one
    /// in a fresh process too, shows it again (`LiveDictationSnapshot.isHeldForKeyboard`).
    static func recycleFacts(sessionEnded: Bool, forced: Bool, published: LiveDictationSnapshot?) -> KeyboardRecyclePolicy.Facts {
        let census = census
        let takeOpen = published.map { !$0.complete && !$0.isHeldForKeyboard } ?? false
        let owesWork = takeOpen || liveControllers.contains { !$0.isTornDown && $0.holdsWork }
        return .init(sessionEnded: sessionEnded, visible: max(census.visible, census.hostsInWindow),
                     hiddenControllers: census.hidden, owesWork: owesWork, uptimeSeconds: uptime, previewBlanks: previewBlanks,
                     memoryWarnings: memoryWarnings, forced: forced)
    }

    // MARK: Memory

    /// What this process may still allocate before iOS ends it; the simulator reports 0. Diagnostics only.
    nonisolated static var availableMemory: Int { os_proc_available_memory() }

    /// The process's physical footprint, the figure iOS holds against its limit; nil when the kernel does not report it.
    nonisolated static func footprint() -> UInt64? {
        var info = task_vm_info_data_t()
        let capacity = MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size
        var count = mach_msg_type_number_t(capacity)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: capacity) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS, let offset = MemoryLayout<task_vm_info_data_t>.offset(of: \.phys_footprint),
              Int(count) * MemoryLayout<integer_t>.size >= offset + MemoryLayout<UInt64>.size else { return nil }
        return info.phys_footprint
    }
}
