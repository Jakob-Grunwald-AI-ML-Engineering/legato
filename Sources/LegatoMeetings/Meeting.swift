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
    /// What the app shows; "Speaker N" until the user renames the person.
    public var name: String
    /// Which colour of the app's palette marks the person.
    public var colorIndex: Int
    public init(name: String, colorIndex: Int) {
        self.name = name
        self.colorIndex = colorIndex
    }
}

/// A stretch of the meeting the transcript missed: the Soniox stream was down and the audio of the gap was
/// not transcribed. The audio itself is recorded.
public struct TranscriptGap: Sendable, Equatable, Codable {
    /// Seconds from the start of the meeting.
    public var start: TimeInterval
    public var end: TimeInterval

    public init(start: TimeInterval, end: TimeInterval) {
        self.start = start
        self.end = end
    }
}

/// A recorded meeting: what `meeting.json` holds. Segments live next to it in `segments.jsonl`.
public struct Meeting: Sendable, Equatable, Codable, Identifiable {
    public enum State: String, Sendable, Equatable, Codable {
        /// Capturing now.
        case recording
        /// Stopped; the after-stop chain (m4a, then the summary) has not finished.
        case processing
        case finished
        /// The app died while recording; found by ``MeetingRecovery``.
        case interrupted
    }

    /// A step of the after-stop chain, recorded once done so an interrupted chain resumes after it.
    public enum Step: String, Sendable, Equatable, Codable, CaseIterable {
        /// The CAF recordings converted to m4a.
        case audio
        /// A summary was written, automatically after the meeting or when the user asked.
        /// The meeting is finished without it.
        case summary
    }

    public var id: UUID
    public var title: String
    public var date: Date
    /// Seconds of audio.
    public var duration: TimeInterval
    public var mutedRanges: [MutedRange]
    /// When the whole meeting was paused.
    public var pausedRanges: [PausedRange]
    /// Where the live transcript is missing because the connection was down.
    public var gaps: [TranscriptGap]
    /// Everyone heard in the meeting, by stable person id.
    public var speakers: [PersonID: SpeakerInfo]
    /// Every id merged away, and the person it went into. Such an id is never given to anyone else.
    public var mergedSpeakers: [PersonID: PersonID]
    /// The language the live engine was asked for (a locale identifier); nil is Auto.
    public var locale: String?
    /// The summary sections ticked for this meeting (``SummarySection``); nil: the settings' default ticks.
    public var sections: [SectionID]?
    public var state: State
    /// The after-stop steps already done. Empty for a meeting that has not been processed.
    public var completedSteps: Set<Step>
    /// Why the last summary attempt failed (words for the user); nil when it has not, or once one succeeded.
    public var summaryFailure: String?

    public init(
        id: UUID = UUID(), title: String, date: Date, duration: TimeInterval = 0,
        mutedRanges: [MutedRange] = [], pausedRanges: [PausedRange] = [], gaps: [TranscriptGap] = [],
        speakers: [PersonID: SpeakerInfo] = [:], mergedSpeakers: [PersonID: PersonID] = [:], locale: String? = nil,
        sections: [SectionID]? = nil, state: State = .recording, completedSteps: Set<Step> = [], summaryFailure: String? = nil
    ) {
        self.id = id
        self.title = title
        self.date = date
        self.duration = duration
        self.mutedRanges = mutedRanges
        self.pausedRanges = pausedRanges
        self.gaps = gaps
        self.speakers = speakers
        self.mergedSpeakers = mergedSpeakers
        self.locale = locale
        self.sections = sections
        self.state = state
        self.completedSteps = completedSteps
        self.summaryFailure = summaryFailure
    }

    // Fields that came later decode with their default, so a `meeting.json` written before one still opens.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        date = try c.decode(Date.self, forKey: .date)
        duration = try c.decode(TimeInterval.self, forKey: .duration)
        mutedRanges = try c.decodeIfPresent([MutedRange].self, forKey: .mutedRanges) ?? []
        pausedRanges = try c.decodeIfPresent([PausedRange].self, forKey: .pausedRanges) ?? []
        gaps = try c.decodeIfPresent([TranscriptGap].self, forKey: .gaps) ?? []
        speakers = try c.decodeIfPresent([PersonID: SpeakerInfo].self, forKey: .speakers) ?? [:]
        mergedSpeakers = try c.decodeIfPresent([PersonID: PersonID].self, forKey: .mergedSpeakers) ?? [:]
        locale = try c.decodeIfPresent(String.self, forKey: .locale)
        sections = try c.decodeIfPresent([SectionID].self, forKey: .sections)
        state = try c.decode(State.self, forKey: .state)
        completedSteps = try c.decodeIfPresent(Set<Step>.self, forKey: .completedSteps) ?? []
        summaryFailure = try c.decodeIfPresent(String.self, forKey: .summaryFailure)
    }
}
