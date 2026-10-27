import Foundation

/// What `AutoMutePolicy` needs to know about one process: whether it has the mic and the speakers open.
public struct AutoMuteProcess: Sendable, Equatable, Hashable {
    public var pid: Int32
    public var isRunningInput: Bool
    public var isRunningOutput: Bool

    public init(pid: Int32, isRunningInput: Bool, isRunningOutput: Bool) {
        self.pid = pid
        self.isRunningInput = isRunningInput
        self.isRunningOutput = isRunningOutput
    }
}

/// The pure rule behind auto-mute (meeting decision 7), which says only what the *automatic* mute wants;
/// ``MeetingMuteState`` combines it with the user's choice.
///
/// - A **call app** is another process (not our own) seen with the mic *and* the speakers running at the
///   same time while system audio is active. A browser tab that only checks the mic never arms it.
/// - Auto-mute wants "me" muted when system audio is active and no call app seen so far holds the mic.
///   Other processes holding or releasing the mic count neither way.
public struct AutoMutePolicy: Sendable {
    private let ownPID: Int32
    private var callApps: Set<Int32> = []

    /// - Parameter ownPID: our own process, never counted as a call app.
    public init(ownPID: Int32) {
        self.ownPID = ownPID
    }

    /// - Parameters:
    ///   - systemAudioActive: the meeting is capturing system audio.
    ///   - processes: the processes with the mic or the speakers running now (our own may be among them).
    /// - Returns: whether "me" should be auto-muted.
    public mutating func update(systemAudioActive: Bool, processes: [AutoMuteProcess]) -> Bool {
        guard systemAudioActive else { return false }
        let others = processes.filter { $0.pid != ownPID }
        for process in others where process.isRunningInput && process.isRunningOutput { callApps.insert(process.pid) }
        guard !callApps.isEmpty else { return false }
        let holding = Set(others.filter(\.isRunningInput).map(\.pid))
        return callApps.isDisjoint(with: holding)
    }
}

/// The effective mute of "me" in a Mac meeting: the automatic decision, unless the user overrode it.
///
/// Manual mute wins in both directions. The override lasts until the automatic decision next changes
/// (the call app mutes or unmutes), and then the automatic decision is followed again.
public struct MeetingMuteState: Sendable, Equatable {
    /// The user's choice; `nil` follows the automatic decision.
    public private(set) var manualOverride: Bool?
    public private(set) var autoWants = false

    public init() {}

    public var effective: Bool { manualOverride ?? autoWants }

    /// Records the automatic decision; a change of it clears the user's override.
    public mutating func setAuto(_ wants: Bool) {
        guard wants != autoWants else { return }
        autoWants = wants
        manualOverride = nil
    }

    /// The button or hotkey: flips what is in effect now.
    public mutating func toggle() {
        manualOverride = !effective
    }
}
