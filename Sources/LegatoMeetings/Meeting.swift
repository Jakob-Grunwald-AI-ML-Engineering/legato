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

/// A stretch of the whole meeting during which every source was silenced because the user paused it.
/// Separate from the per-stream ``MutedRange``s: one range covers all sources.
public struct PausedRange: Sendable, Equatable, Codable {
    /// Seconds from the start of the meeting.
    public var start: TimeInterval
    public var end: TimeInterval

    public init(start: TimeInterval, end: TimeInterval) {
        self.start = start
        self.end = end
    }
}

/// A person in a meeting. Ids (`P1`, `P2`, …) are stable: segments and turns refer to them, and a rename
/// or a merge never changes the id of a person who stays.
public typealias PersonID = String

public struct SpeakerInfo: Sendable, Equatable, Codable {
    /// What the app shows; "Speaker N" until the user renames the person, "You" for the user.
    public var name: String
    /// Which colour of the app's palette marks the person.
    public var colorIndex: Int
    /// The user. At most one person per meeting.
    public var isYou: Bool

    public init(name: String, colorIndex: Int, isYou: Bool) {
        self.name = name
        self.colorIndex = colorIndex
        self.isYou = isYou
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
        /// The after-meeting speaker pass over the mix.
        case diarize
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
    /// When the whole meeting was paused.
    public var pausedRanges: [PausedRange]
    /// Everyone heard in the meeting, by stable person id.
    public var speakers: [PersonID: SpeakerInfo]
    /// The language the live engine was asked for (a locale identifier); nil is Auto.
    public var locale: String?
    /// The summary template picked for this meeting.
    public var templateID: String
    public var state: State
    /// The after-stop steps already done. Empty for a meeting that has not been processed.
    public var completedSteps: Set<Step>

    public init(
        id: UUID = UUID(), title: String, date: Date, duration: TimeInterval = 0, engineID: String,
        postPassID: String? = nil, mutedRanges: [MutedRange] = [], pausedRanges: [PausedRange] = [],
        speakers: [PersonID: SpeakerInfo] = [:], locale: String? = nil, templateID: String = SummaryTemplate.summaryID,
        state: State = .recording, completedSteps: Set<Step> = []
    ) {
        self.id = id
        self.title = title
        self.date = date
        self.duration = duration
        self.engineID = engineID
        self.postPassID = postPassID
        self.mutedRanges = mutedRanges
        self.pausedRanges = pausedRanges
        self.speakers = speakers
        self.locale = locale
        self.templateID = templateID
        self.state = state
        self.completedSteps = completedSteps
    }

    // Meetings saved before a field existed decode with its default: no steps done, nobody paused, no speakers.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        date = try c.decode(Date.self, forKey: .date)
        duration = try c.decode(TimeInterval.self, forKey: .duration)
        engineID = try c.decode(String.self, forKey: .engineID)
        postPassID = try c.decodeIfPresent(String.self, forKey: .postPassID)
        mutedRanges = try c.decode([MutedRange].self, forKey: .mutedRanges)
        pausedRanges = try c.decodeIfPresent([PausedRange].self, forKey: .pausedRanges) ?? []
        speakers = try c.decodeIfPresent([PersonID: SpeakerInfo].self, forKey: .speakers) ?? [:]
        locale = try c.decodeIfPresent(String.self, forKey: .locale)
        templateID = try c.decodeIfPresent(String.self, forKey: .templateID) ?? SummaryTemplate.summaryID
        state = try c.decode(State.self, forKey: .state)
        completedSteps = try c.decodeIfPresent(Set<Step>.self, forKey: .completedSteps) ?? []
    }
}
