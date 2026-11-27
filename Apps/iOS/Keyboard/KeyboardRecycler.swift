import Darwin
import Foundation
import LegatoKeyboardCore
import os

/// Ends the keyboard's process once it is hidden, idle and unhealthy (`KeyboardRecyclePolicy`, #342), so iOS starts a fresh one
/// on the next show: only a new process recovered a preview that stopped drawing. In every build; extension only (the app
/// compiles `KeyboardUI` for its harness, never this).
@MainActor
enum KeyboardRecycler {
    private static let policy = KeyboardRecyclePolicy()
    private static let log = Logger(subsystem: "de.gruenwald.legato", category: "keyboard-process")
    private static var check: Task<Void, Never>?
    private static var lastWait: PreviewDiagnostics.Recycle?

    /// The first look comes once a hide has settled; an unhealthy process that must wait (work still owed, too young) is looked
    /// at again a bounded number of times. Estimates.
    private static var firstDelay: Duration { .seconds(policy.settleSeconds + 0.5) }
    private static let retryDelay = Duration.seconds(10)
    private static let maxChecks = 15
    /// A check that fires later than this ran after the process was suspended: iOS may be resuming it to show the keyboard,
    /// so it looks again after a settle instead of acting at once.
    private static let lateTolerance = Duration.seconds(1)

    /// A keyboard hid or memory ran low: look at the process once things settle. A new appearance cancels it (`cancel`).
    static func schedule() {
        check?.cancel()
        check = Task { await run() }
    }

    static func cancel() {
        check?.cancel()
        check = nil
    }

    private static func run() async {
        var delay = firstDelay
        for _ in 0..<maxChecks {
            let due = ContinuousClock.now + delay
            try? await Task.sleep(until: due, clock: .continuous)
            guard !Task.isCancelled else { return }
            delay = retryDelay
            if ContinuousClock.now - due > lateTolerance {
                delay = firstDelay
                continue
            }
            let takeOpen = LinkClient().readLiveDictation().map { !$0.complete } ?? false
            let facts = KeyboardProcess.recycleFacts(takeOpen: takeOpen)
            switch policy.decide(facts) {
            case .healthy:
                return
            case .wait(let reason, let blocker):
                noteWait(.init(reason: reason, blocker: blocker, owesWork: facts.owesWork, quietSeconds: facts.quietSeconds))
                // A visible keyboard schedules the next look when it hides.
                if blocker == .visible { return }
            case .recycle(let reason):
                recycle(reason, facts: facts)
            }
        }
    }

    private static func noteWait(_ wait: PreviewDiagnostics.Recycle) {
        #if DEBUG || LEGATO_INTERNAL
        // Once per reason and blocker, not every retry.
        guard lastWait?.reason != wait.reason || lastWait?.blocker != wait.blocker else { return }
        lastWait = wait
        PreviewDiagnostics.keyboard.record(.recycleWait, sampleMemory: true, census: true, recycle: wait)
        #endif
    }

    private static func recycle(_ reason: KeyboardRecyclePolicy.Reason, facts: KeyboardRecyclePolicy.Facts) -> Never {
        log.notice("""
            recycle reason=\(reason.rawValue, privacy: .public) hidden=\(facts.hiddenControllers) \
            footprint=\(facts.footprintBytes ?? 0) available=\(facts.availableBytes) uptime=\(Int(facts.uptimeSeconds))
            """)
        #if DEBUG || LEGATO_INTERNAL
        // Written synchronously (`RotatingLineFile`), so it is on disk before the process ends.
        PreviewDiagnostics.keyboard.record(.processRecycled, sampleMemory: true, census: true,
                                           recycle: .init(reason: reason, blocker: nil, owesWork: facts.owesWork,
                                                          quietSeconds: facts.quietSeconds))
        #endif
        exit(0)
    }
}
