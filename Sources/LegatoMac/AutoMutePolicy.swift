import Foundation

/// The pure rule behind auto-mute (meeting decision 7). The meeting controller combines the result
/// with the manual mute.
public struct AutoMutePolicy: Sendable {
    private let ownPID: Int32
    private var callAppSeen = false

    /// - Parameter ownPID: our own process, never counted as a call app.
    public init(ownPID: Int32) {
        self.ownPID = ownPID
    }

    /// - Parameters:
    ///   - systemAudioActive: the meeting is capturing system audio.
    ///   - inputPIDs: processes that currently have a mic input running (our own may be among them).
    ///   - manuallyMuted: the user muted by hand; that always wins, so no auto-mute is wanted then.
    /// - Returns: whether "me" should be auto-muted: system audio is active, some other process has
    ///   held the mic during this meeting, and none holds it now.
    public mutating func update(systemAudioActive: Bool, inputPIDs: Set<Int32>, manuallyMuted: Bool) -> Bool {
        let others = inputPIDs.subtracting([ownPID])
        if systemAudioActive, !others.isEmpty { callAppSeen = true }
        guard systemAudioActive, !manuallyMuted else { return false }
        return callAppSeen && others.isEmpty
    }
}
