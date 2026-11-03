import Foundation

/// Tells a stalled composer poll from a quiet one (#225). The host posts `Note.composer` after every
/// publication, so a note that no read has turned into a delivered value for `staleAfter` seconds, or a poll
/// loop that itself did not tick for that long, means the keyboard is not following the host. Pure
/// bookkeeping on a caller-supplied clock; it carries no draft content.
public struct ComposerPollWatch: Sendable, Equatable {
    public enum Finding: Sendable, Equatable {
        /// A host note arrived `age` seconds ago and no publication has been delivered since.
        case staleAfterNote(age: Double)
        /// The poll loop itself did not run for `gap` seconds (main actor starved or the task suspended).
        case loopGap(gap: Double)
    }
    public static let staleAfter: Double = 2
    private var pendingNoteAt: Double?
    private var lastTickAt: Double?
    private var lastDeliveredAt: Double?
    private var reported = false
    /// A note this soon after a delivery was most likely read by that very poll, which beat the note to it.
    static let raceWindow: Double = 0.25
    public init() {}

    /// The poll (re)started: forget earlier notes and ticks.
    public mutating func start(at now: Double) { pendingNoteAt = nil; lastDeliveredAt = nil; lastTickAt = now; reported = false }
    /// The host announced a publication.
    public mutating func noteArrived(at now: Double) {
        if let delivered = lastDeliveredAt, now - delivered < Self.raceWindow { return }
        if pendingNoteAt == nil { pendingNoteAt = now }
    }
    /// A read decoded a publication (whether or not it changed what the controller shows).
    public mutating func delivered(at now: Double) { pendingNoteAt = nil; lastDeliveredAt = now; reported = false }
    /// One loop iteration; returns a finding once per episode.
    public mutating func tick(at now: Double) -> Finding? {
        defer { lastTickAt = now }
        if let last = lastTickAt, now - last > Self.staleAfter, !reported { reported = true; return .loopGap(gap: now - last) }
        if let noteAt = pendingNoteAt, now - noteAt > Self.staleAfter, !reported { reported = true; return .staleAfterNote(age: now - noteAt) }
        return nil
    }
}
