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

/// A recorded meeting: what `meeting.json` holds. Segments live next to it in `segments.jsonl`.
public struct Meeting: Sendable, Equatable, Codable, Identifiable {
    public enum State: String, Sendable, Equatable, Codable {
        /// Capturing now.
        case recording
        /// Stopped; the after-stop chain (m4a, post-pass, speakers, and the summary when it is automatic) has not finished.
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
        /// A summary was written: automatically after the meeting (when that setting is on) or when the user asked.
        /// The meeting is finished without it.
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
    /// Every id merged away, and the person it went into. Such an id is never given to anyone else.
    public var mergedSpeakers: [PersonID: PersonID]
    /// The language the live engine was asked for (a locale identifier); nil is Auto.
    public var locale: String?
    /// The summary sections ticked for this meeting (``SummarySection``); nil: the settings' default ticks. A meeting
    /// saved with a template (before sections) reads as that template's sections.
    public var sections: [SectionID]?
    public var state: State
    /// The after-stop steps already done. Empty for a meeting that has not been processed.
    public var completedSteps: Set<Step>
    /// Runs of the heavy steps in a row in which one of them failed; the pipeline stops retrying after a few.
    public var failedRuns: Int

    public init(
        id: UUID = UUID(), title: String, date: Date, duration: TimeInterval = 0, engineID: String,
        postPassID: String? = nil, mutedRanges: [MutedRange] = [], pausedRanges: [PausedRange] = [],
        speakers: [PersonID: SpeakerInfo] = [:], mergedSpeakers: [PersonID: PersonID] = [:], locale: String? = nil, sections: [SectionID]? = nil,
        state: State = .recording, completedSteps: Set<Step> = [], failedRuns: Int = 0
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
        self.mergedSpeakers = mergedSpeakers
        self.locale = locale
        self.sections = sections
        self.state = state
        self.completedSteps = completedSteps
        self.failedRuns = failedRuns
    }

    /// The single summary template a meeting had before sections.
    private enum LegacyKeys: String, CodingKey { case templateID }

    // Meetings saved before a field existed decode with its default: no steps done, nobody paused, no speakers,
    // nothing merged, no failed runs, the default sections (or the sections of the template it had).
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
        mergedSpeakers = try c.decodeIfPresent([PersonID: PersonID].self, forKey: .mergedSpeakers) ?? [:]
        locale = try c.decodeIfPresent(String.self, forKey: .locale)
        if let sections = try c.decodeIfPresent([SectionID].self, forKey: .sections) {
            self.sections = sections
        } else {
            let legacy = try decoder.container(keyedBy: LegacyKeys.self)
            sections = try legacy.decodeIfPresent(String.self, forKey: .templateID).map(SummarySection.sections(forTemplate:))
        }
        state = try c.decode(State.self, forKey: .state)
        completedSteps = try c.decodeIfPresent(Set<Step>.self, forKey: .completedSteps) ?? []
        failedRuns = try c.decodeIfPresent(Int.self, forKey: .failedRuns) ?? 0
    }
}
