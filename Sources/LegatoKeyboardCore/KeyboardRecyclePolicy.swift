import Foundation

/// Whether the keyboard extension ends its own process so iOS starts a fresh one on the next show (#342). A long-lived process
/// can keep keyboard controllers UIKit never released or stop drawing the dictation preview, and only a new process recovers.
/// The extension feeds the facts and acts only once the host's session with the keyboard has ended (the host left the
/// foreground): a process ended under a host still holding it makes iOS show Apple's keyboard on the next show instead. The
/// policy never exits while a keyboard is visible or owes work.
public struct KeyboardRecyclePolicy: Sendable {
    /// What makes the process unhealthy, in the order checked. Memory use alone is not one: the simulator reports no available
    /// memory at all, and the phone's limit is not known well enough to set a share of it; iOS's own warning stands for it.
    public enum Reason: String, Codable, Sendable {
        case previewBlank, leakedControllers, memoryWarning
        /// A debug build was told to (`KeyboardRecycler`), to test the recycle itself.
        case forced
    }

    /// Why an unhealthy process is kept for now.
    public enum Blocker: String, Codable, Sendable {
        /// The host's session with the keyboard is still open: the host is in front.
        case sessionOpen
        case visible, owesWork, young
    }

    public enum Decision: Equatable, Sendable {
        case healthy
        case wait(Reason, Blocker)
        case recycle(Reason)
    }

    public struct Facts: Equatable, Sendable {
        /// The host's session with the keyboard ended (the host left the foreground) and no new one began.
        public var sessionEnded: Bool
        /// Keyboards on screen: controllers marked visible, or view controllers whose view is in a window.
        public var visible: Int
        /// Controllers alive and not torn down while hidden: the one just hidden, or ones UIKit never released.
        public var hiddenControllers: Int
        /// A take, field edit, instruction or write is still in flight, or the app's published take is still open.
        public var owesWork: Bool
        public var uptimeSeconds: Double
        public var previewBlanks: Int
        public var memoryWarnings: Int
        public var forced: Bool

        public init(sessionEnded: Bool, visible: Int, hiddenControllers: Int, owesWork: Bool, uptimeSeconds: Double,
                    previewBlanks: Int, memoryWarnings: Int, forced: Bool = false) {
            self.sessionEnded = sessionEnded
            self.visible = visible
            self.hiddenControllers = hiddenControllers
            self.owesWork = owesWork
            self.uptimeSeconds = uptimeSeconds
            self.previewBlanks = previewBlanks
            self.memoryWarnings = memoryWarnings
            self.forced = forced
        }
    }

    // Thresholds are estimates, to measure on the phone (#342). The bad process held 6–7 leaked controllers. A healthy one still
    // holds the keyboards it hid during the session as its host leaves (UIKit releases them when the next session begins): 1–3
    // over 16 shows in the simulator.
    /// More hidden controllers than this count as leaked.
    public var maxHiddenControllers = 4
    /// A younger process is kept, so a process that starts unhealthy does not cold-start the keyboard after every app switch.
    public var minimumUptimeSeconds = 60.0

    public init() {}

    public func reason(_ facts: Facts) -> Reason? {
        if facts.forced { return .forced }
        if facts.previewBlanks > 0 { return .previewBlank }
        if facts.hiddenControllers > maxHiddenControllers { return .leakedControllers }
        if facts.memoryWarnings > 0 { return .memoryWarning }
        return nil
    }

    public func decide(_ facts: Facts) -> Decision {
        guard let reason = reason(facts) else { return .healthy }
        if !facts.sessionEnded { return .wait(reason, .sessionOpen) }
        if facts.visible > 0 { return .wait(reason, .visible) }
        if facts.owesWork { return .wait(reason, .owesWork) }
        if !facts.forced, facts.uptimeSeconds < minimumUptimeSeconds { return .wait(reason, .young) }
        return .recycle(reason)
    }
}
