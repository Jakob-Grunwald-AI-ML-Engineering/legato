import Foundation
import LegatoCore

/// A stretch of a stream's audio that was replaced by silence because the user was muted.
public struct MutedRange: Sendable, Equatable, Codable {
    public var stream: TranscriptEvent.Stream
    /// Seconds from the start of the meeting.
    public var start: TimeInterval
    public var end: TimeInterval

    public init(stream: TranscriptEvent.Stream, start: TimeInterval, end: TimeInterval) {
        self.stream = stream
        self.start = start
        self.end = end
    }
}

/// A recorded meeting: what `meeting.json` holds. Segments live next to it in `segments.jsonl`.
public struct Meeting: Sendable, Equatable, Codable, Identifiable {
    public enum State: String, Sendable, Equatable, Codable {
        /// Capturing now.
        case recording
        /// Stopped; the after-stop chain (post-pass, m4a, summary) has not finished.
        case processing
        case finished
        /// The app died while recording; found by ``MeetingRecovery``.
        case interrupted
    }

    /// A step of the after-stop chain, recorded once done so an interrupted chain resumes after it.
    public enum Step: String, Sendable, Equatable, Codable, CaseIterable {
        /// The accuracy pass over the recorded audio.
        case postPass
        /// The CAF recordings converted to m4a.
        case audio
        /// The automatic on-device summary.
        case summary
    }

    public var id: UUID
    public var title: String
    public var date: Date
    /// Seconds of audio.
    public var duration: TimeInterval
    /// The live engine's id.
    public var engineID: String
    /// The post-pass model's id, once it ran.
    public var postPassID: String?
    public var mutedRanges: [MutedRange]
    public var state: State
    /// The after-stop steps already done. Empty for a meeting that has not been processed.
    public var completedSteps: Set<Step>

    public init(
        id: UUID = UUID(), title: String, date: Date, duration: TimeInterval = 0, engineID: String,
        postPassID: String? = nil, mutedRanges: [MutedRange] = [], state: State = .recording,
        completedSteps: Set<Step> = []
    ) {
        self.id = id
        self.title = title
        self.date = date
        self.duration = duration
        self.engineID = engineID
        self.postPassID = postPassID
        self.mutedRanges = mutedRanges
        self.state = state
        self.completedSteps = completedSteps
    }

    // Meetings saved before `completedSteps` existed decode with none done.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        date = try c.decode(Date.self, forKey: .date)
        duration = try c.decode(TimeInterval.self, forKey: .duration)
        engineID = try c.decode(String.self, forKey: .engineID)
        postPassID = try c.decodeIfPresent(String.self, forKey: .postPassID)
        mutedRanges = try c.decode([MutedRange].self, forKey: .mutedRanges)
        state = try c.decode(State.self, forKey: .state)
        completedSteps = try c.decodeIfPresent(Set<Step>.self, forKey: .completedSteps) ?? []
    }
}
