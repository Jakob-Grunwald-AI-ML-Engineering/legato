import Foundation

/// The keyboard's "Cleaning up…" (so the user knows not to send yet): on from a live take's stop, or from its complete
/// snapshot the field does not show yet, until the queue acknowledges the run's complete version (every cleanup edit
/// landed or dropped). A new take, a dropped run, a field switch or the keyboard closing clears it; so does `limit`,
/// in case no cleanup ever comes. Pure: the keyboard feeds it what happens.
public struct CleanupIndicator: Sendable, Equatable {
    public static let limit: TimeInterval = 30

    public private(set) var runID: String?
    public private(set) var since: Date?
    /// The newest complete version of the run seen, and the last version the field showed (by run).
    private var completeVersion: Int?
    private var shown: (runID: String, version: Int)?

    public init() {}

    public var isActive: Bool { runID != nil }

    /// The user stopped the take while its run was being typed.
    public mutating func stopped(runID: String, at now: Date) {
        guard self.runID != runID else { return }
        self.runID = runID; since = now; completeVersion = nil
    }

    /// A snapshot the keyboard took on: another run's ends the wait (a new take); a complete one not shown yet starts it.
    public mutating func received(_ snapshot: LiveDictationSnapshot, at now: Date) {
        if let runID, runID != snapshot.runID { clear() }
        guard snapshot.complete else { return }
        if let shown, shown.runID == snapshot.runID, shown.version >= snapshot.version { return }
        if runID == nil { runID = snapshot.runID; since = now }
        completeVersion = max(completeVersion ?? snapshot.version, snapshot.version)
    }

    /// The field shows this version of the run (the queue acknowledged it).
    public mutating func applied(runID: String, version: Int, complete: Bool) {
        if shown?.runID != runID || (shown?.version ?? .min) < version { shown = (runID, version) }
        guard runID == self.runID, complete, let completeVersion, version >= completeVersion else { return }
        clear()
    }

    /// The bound ran out.
    public mutating func expire(now: Date) {
        guard let since, now.timeIntervalSince(since) >= Self.limit else { return }
        clear()
    }

    public mutating func clear() { runID = nil; since = nil; completeVersion = nil }

    public static func == (a: Self, b: Self) -> Bool {
        a.runID == b.runID && a.since == b.since && a.completeVersion == b.completeVersion
            && a.shown?.runID == b.shown?.runID && a.shown?.version == b.shown?.version
    }
}
