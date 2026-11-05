import Foundation

extension MeetingStore {
    /// Whether the meeting matches a search, reading what it matches against: its filing, speakers, summaries, notes and
    /// transcript (``MeetingListLogic/matches(_:meeting:summaries:notes:segments:)``). The Meetings window and the
    /// `legato` command line share it. Reads only; what cannot be read counts as absent.
    public func matches(_ query: String, meeting: Meeting) async -> Bool {
        let spoken = (try? await segments(for: meeting.id)) ?? []
        let written = ((try? summaries(for: meeting.id)) ?? []).map(\.text)
        let typed = (try? notes(for: meeting.id)) ?? nil
        return MeetingListLogic.matches(query, meeting: meeting, summaries: written, notes: typed, segments: spoken)
    }
}
