import Foundation

/// Only a fresh successful delivery followed by clearing its draft can start a flight.
/// A pending/failed Insert, Clear, or replayed publication does not acknowledge delivery.
struct SendFlightPresentation: Equatable {
    private(set) var lastAcknowledgement: String?
    private(set) var activeAcknowledgement: String?

    func retainsViewport(acknowledgement: String?, hasDraft: Bool, hadDraft: Bool) -> Bool {
        guard !hasDraft, hadDraft else { return false }
        return activeAcknowledgement != nil || (acknowledgement != nil && acknowledgement != lastAcknowledgement)
    }
    mutating func observe(acknowledgement: String?, hasDraft: Bool, hadDraft: Bool) -> Bool {
        if hasDraft { activeAcknowledgement = nil; return false }
        guard retainsViewport(acknowledgement: acknowledgement, hasDraft: hasDraft, hadDraft: hadDraft),
              let acknowledgement, acknowledgement != lastAcknowledgement else { return false }
        lastAcknowledgement = acknowledgement
        activeAcknowledgement = acknowledgement
        return true
    }
    mutating func reset(acknowledgement: String?) {
        lastAcknowledgement = acknowledgement; activeAcknowledgement = nil
    }
    mutating func finish(_ acknowledgement: String) {
        if activeAcknowledgement == acknowledgement { activeAcknowledgement = nil }
    }
}
