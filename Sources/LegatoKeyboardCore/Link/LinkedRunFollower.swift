import Foundation
import LegatoFieldEdit

/// The keyboard's side of a linked run (the app's cleanup agent on the link): which run it publishes
/// its field feed for (`link.feed`) and takes the app's edits from (`link.edits`), from each `link.host` state.
///
/// - Followed: a keyboard run with cleanup, whose cleaned text the app writes over the link: Live (the cleanup
///   agent, or the stop's rewrite) and Replace. Runs without cleanup have no reader: no feed is published for them.
/// - The run stays followed through its final state (the app's stop still sends edits and reads their outcomes)
///   until another run starts (its last batch still goes out) or the app scrubs the link (no run any more:
///   nothing more is written, not even a last batch, so the field's text does not come back).
/// - The link delivers edits at least once: ``fresh(_:)`` passes each transaction once per run.
public struct LinkedRunFollower: Sendable, Equatable {
    public enum Action: Sendable, Equatable {
        case none
        /// Start following this run: publish the feed (a resync first) and take its edits.
        case follow(String)
        /// Stop following; `flush`: publish what is waiting first.
        case stop(flush: Bool)
    }

    /// The run followed; nil: none.
    public private(set) var runID: String?
    private var seen: Set<UUID> = []

    public init() {}

    /// Whether a run's field events have a reader on the app's side.
    public static func isLinked(_ host: HostState) -> Bool {
        host.runID != nil && host.target == .keyboard && host.insertAt == nil
            && (host.delivery == .live || host.delivery == .replace)
    }

    public mutating func hostChanged(_ host: HostState) -> Action {
        if let id = host.runID, id == runID { return .none }
        if Self.isLinked(host), let id = host.runID {
            runID = id
            seen = []
            return .follow(id)
        }
        guard runID != nil else { return .none }
        runID = nil
        seen = []
        return .stop(flush: host.runID != nil)
    }

    /// The transactions not taken before in this run, in order.
    public mutating func fresh(_ transactions: [EditTransaction]) -> [EditTransaction] {
        transactions.filter { seen.insert($0.id).inserted }
    }

    /// The keyboard went away (its queue closed): nothing is followed.
    public mutating func reset() {
        runID = nil
        seen = []
    }
}
