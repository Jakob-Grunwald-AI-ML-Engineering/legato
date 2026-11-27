import Foundation

/// Whether the keyboard extension ends its own process so iOS starts a fresh one on the next show (#342). A long-lived process
/// can keep keyboard controllers UIKit never released, grow towards its memory limit, or stop drawing the dictation preview,
/// and only a new process recovers. The extension feeds the facts and acts; the policy never exits while the keyboard is
/// visible, owes work, or is still settling after a hide.
public struct KeyboardRecyclePolicy: Sendable {
    /// What makes the process unhealthy, in the order checked.
    public enum Reason: String, Codable, Sendable {
        case previewBlank, leakedControllers, memoryWarning, memoryFootprint
    }

    /// Why an unhealthy process is kept for now.
    public enum Blocker: String, Codable, Sendable {
        case visible, owesWork, settling, young
    }

    public enum Decision: Equatable, Sendable {
        case healthy
        case wait(Reason, Blocker)
        case recycle(Reason)
    }

    public struct Facts: Equatable, Sendable {
        /// Keyboards on screen: controllers marked visible, or view controllers whose view is in a window.
        public var visible: Int
        /// Controllers alive and not torn down while hidden (the one just hidden is released about a second later).
        public var hiddenControllers: Int
        /// A take, field edit, instruction or write is still in flight, or the app's published take is still open.
        public var owesWork: Bool
        /// Seconds since the last keyboard lifecycle event (load, appear, disappear).
        public var quietSeconds: Double
        public var uptimeSeconds: Double
        public var footprintBytes: UInt64?
        public var availableBytes: UInt64
        public var previewBlanks: Int
        public var memoryWarnings: Int

        public init(visible: Int, hiddenControllers: Int, owesWork: Bool, quietSeconds: Double, uptimeSeconds: Double,
                    footprintBytes: UInt64?, availableBytes: UInt64, previewBlanks: Int, memoryWarnings: Int) {
            self.visible = visible
            self.hiddenControllers = hiddenControllers
            self.owesWork = owesWork
            self.quietSeconds = quietSeconds
            self.uptimeSeconds = uptimeSeconds
            self.footprintBytes = footprintBytes
            self.availableBytes = availableBytes
            self.previewBlanks = previewBlanks
            self.memoryWarnings = memoryWarnings
        }

        /// The footprint's share of the process limit (footprint plus what is still available); nil when unknown.
        public var footprintFraction: Double? {
            guard let footprintBytes else { return nil }
            let limit = Double(footprintBytes) + Double(availableBytes)
            return limit > 0 ? Double(footprintBytes) / limit : nil
        }
    }

    // Thresholds are estimates, to measure on the phone (#342). The bad process held 6–7 leaked controllers at 117–130 MB of
    // about 185 MB (0.63–0.70); a healthy one releases each hidden controller within about a second.
    /// More hidden controllers than this, after the settle time, count as leaked.
    public var maxHiddenControllers = 2
    /// The footprint share of the limit at which the process counts as unhealthy.
    public var maxFootprintFraction = 0.75
    /// A hide must have settled this long: the hidden controller's release, Safari's Next/Previous re-show.
    public var settleSeconds = 3.0
    /// A younger process is kept, so a process that starts unhealthy cannot recycle on every hide.
    public var minimumUptimeSeconds = 120.0

    public init() {}

    public func reason(_ facts: Facts) -> Reason? {
        if facts.previewBlanks > 0 { return .previewBlank }
        if facts.hiddenControllers > maxHiddenControllers { return .leakedControllers }
        if facts.memoryWarnings > 0 { return .memoryWarning }
        if let fraction = facts.footprintFraction, fraction >= maxFootprintFraction { return .memoryFootprint }
        return nil
    }

    public func decide(_ facts: Facts) -> Decision {
        guard let reason = reason(facts) else { return .healthy }
        if facts.visible > 0 { return .wait(reason, .visible) }
        if facts.owesWork { return .wait(reason, .owesWork) }
        if facts.quietSeconds < settleSeconds { return .wait(reason, .settling) }
        if facts.uptimeSeconds < minimumUptimeSeconds { return .wait(reason, .young) }
        return .recycle(reason)
    }
}
