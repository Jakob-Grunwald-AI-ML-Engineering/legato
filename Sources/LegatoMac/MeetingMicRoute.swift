import Foundation

/// Which input device a Mac meeting records from.
public struct MeetingMicChoice: Sendable, Equatable {
    /// The device to record from; nil when not even the default input is known.
    public var device: UInt32?
    /// The device is the call app's, not just the system default.
    public var followsCall: Bool

    public init(device: UInt32?, followsCall: Bool) {
        self.device = device
        self.followsCall = followsCall
    }

    /// What the meeting mic is pinned to: the call app's device, or nil to stay on (and follow) the default input.
    public var pinned: UInt32? { followsCall ? device : nil }
}

/// The pure rule behind the meeting mic's device: record from what the call app records from.
///
/// Opening the default input instead can pick a mic nobody speaks into (Teams on the built-in mic while the
/// AirPods are the default records nothing on the AirPods, and forces them into the low-quality headset mode).
/// The call app is found as in ``AutoMutePolicy``: another process with the mic and the speakers running.
public enum MeetingMicRoute {
    /// - Parameters:
    ///   - processes: the processes with the mic or the speakers running now (our own may be among them).
    ///   - defaultInput: the system default input device, if known.
    /// - Returns: the first call app's first input device, else the default input.
    public static func choose(processes: [AutoMuteProcess], ownPID: Int32, defaultInput: UInt32?, selectedInput: UInt32? = nil) -> MeetingMicChoice {
        if let selectedInput { return MeetingMicChoice(device: selectedInput, followsCall: true) }
        let callInput = processes.lazy
            .filter { $0.pid != ownPID && $0.isRunningInput && $0.isRunningOutput }
            .compactMap(\.inputDevices.first)
            .first
        if let callInput { return MeetingMicChoice(device: callInput, followsCall: true) }
        return MeetingMicChoice(device: defaultInput, followsCall: false)
    }
}
