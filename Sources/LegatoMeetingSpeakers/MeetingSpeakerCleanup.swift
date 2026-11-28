import Foundation
import LegatoAudio
import LegatoCore
import LegatoMeetings
import LegatoVoiceIdentity

/// The after-meeting speaker cleanup, as the after-stop chain and the replay command call it.
public protocol MeetingSpeakerCleaning: Sendable {
    /// Finds the meeting's voices and the user among them from its recordings in `folder`. Saves nothing.
    func analyze(meeting: Meeting, segments: [MeetingSegment], folder: URL) async throws -> SpeakerAnalysis
}

public enum MeetingSpeakerCleanupError: LocalizedError, Sendable, Equatable {
    case noRecording
    public var errorDescription: String? {
        switch self {
        case .noRecording: "The meeting has no recording to check its speakers against."
        }
    }
}

/// What the cleanup found in a meeting's recordings. Only in memory: no embedding is kept in it, only who speaks when,
/// the tracks' loudness and how much each voice resembles the user's profile.
public struct SpeakerAnalysis: Sendable {
    public var timeline: SpeakerTimeline
    /// The voice that is the user, if one was found.
    public var user: Int?
    /// Per voice, whether it is the microphone's; nil without a system-audio track (the iPhone).
    public var micDominant: [Int: Bool]?
    /// Per checked voice, its similarity to the user's profile; nil without a usable profile.
    public var similarity: [Int: Float]?
    public var audioSeconds: TimeInterval
    /// How long the analysis took, seconds, and the parts of it in the segmentation model and the voice embeddings.
    public var runSeconds: TimeInterval
    public var segmentationSeconds: TimeInterval
    public var embeddingSeconds: TimeInterval
    public var windows: Int
    /// Local speakers embedded reliably, from little speech, placed by their surroundings, left out.
    public var embedded: (reliable: Int, weak: Int, guessed: Int, unplaced: Int)
    /// Loudness of the microphone and the system audio, when the meeting recorded both.
    public var micEnergy: TrackEnergy?
    public var systemEnergy: TrackEnergy?

    public init(
        timeline: SpeakerTimeline, user: Int? = nil, micDominant: [Int: Bool]? = nil, similarity: [Int: Float]? = nil,
        audioSeconds: TimeInterval = 0, runSeconds: TimeInterval = 0, segmentationSeconds: TimeInterval = 0,
        embeddingSeconds: TimeInterval = 0, windows: Int = 0,
        embedded: (reliable: Int, weak: Int, guessed: Int, unplaced: Int) = (0, 0, 0, 0),
        micEnergy: TrackEnergy? = nil, systemEnergy: TrackEnergy? = nil
    ) {
        self.timeline = timeline
        self.user = user
        self.micDominant = micDominant
        self.similarity = similarity
        self.audioSeconds = audioSeconds
        self.runSeconds = runSeconds
        self.segmentationSeconds = segmentationSeconds
        self.embeddingSeconds = embeddingSeconds
        self.windows = windows
        self.embedded = embedded
        self.micEnergy = micEnergy
        self.systemEnergy = systemEnergy
    }

    /// The segments and people after the cleanup (``SpeakerReassignment``).
    public func apply(to segments: [MeetingSegment], directory: SpeakerDirectory) -> SpeakerReassignment.Result {
        SpeakerReassignment.apply(timeline, user: user, to: segments, directory: directory)
    }

    /// Which track a span is clearly louder on; nil without both tracks or when neither is.
    public func side(from start: TimeInterval, to end: TimeInterval) -> MeetingSelf.Side? {
        guard let micEnergy, let systemEnergy else { return nil }
        return MeetingSelf.side(micPower: micEnergy.meanPower(from: start, to: end), systemPower: systemEnergy.meanPower(from: start, to: end))
    }
}

/// Diarizes the meeting's mix on the device (``MeetingDiarizer``) and finds the user: on the Mac a voice that is loud on
/// the microphone and not on the system audio (the profile decides between several such voices); on the iPhone the voice
/// that matches the profile. Downloads the segmentation and CAM++ models when they are missing.
public struct MeetingSpeakerCleanup: MeetingSpeakerCleaning {
    /// Solo speech compared with the profile per voice: up to this many stretches…
    static let profileStretches = 3
    /// …of at least this long, seconds, each cut to ``profileStretchCap``.
    static let profileStretchMinimum: TimeInterval = 1
    static let profileStretchCap: TimeInterval = 10
    /// On the iPhone every voice with this much solo speech is compared, seconds.
    static let profileVoiceMinimum: TimeInterval = 3

    let voice: VoiceIdentityService
    let segmentation: SpeakerSegmentationModel
    let threshold: Float
    let usesProfile: Bool

    /// - Parameters:
    ///   - threshold: the cosine similarity at which two stretches are one voice (``SpeakerClustering``).
    ///   - usesProfile: false ignores the voice profile, as if there were none (the replay command, to measure).
    public init(
        voice: VoiceIdentityService = .shared, segmentation: SpeakerSegmentationModel = SpeakerSegmentationModel(),
        threshold: Float = SpeakerClustering.defaultThreshold, usesProfile: Bool = true
    ) {
        self.voice = voice
        self.segmentation = segmentation
        self.threshold = threshold
        self.usesProfile = usesProfile
    }

    public func analyze(meeting: Meeting, segments: [MeetingSegment], folder: URL) async throws -> SpeakerAnalysis {
        let tracks = MeetingAudioWriter(folder: folder)
        guard let mixURL = tracks.recordingURL(of: .mixed) else { throw MeetingSpeakerCleanupError.noRecording }
        try await segmentation.prepare()
        try await voice.prepareModels()
        // The run time leaves out the one-time download.
        let began = ContinuousClock.now

        var options = MeetingDiarizer.Options()
        options.threshold = threshold
        let diarization = try await MeetingDiarizer(segmentation: segmentation, voice: voice, options: options).run(mix: mixURL)
        let timeline = diarization.timeline

        // Mac: which track each word is loud on.
        var micEnergy: TrackEnergy?, systemEnergy: TrackEnergy?
        var micDominant: [Int: Bool]?
        if let systemURL = tracks.recordingURL(of: .system), let micURL = tracks.recordingURL(of: .mic) {
            micEnergy = try Self.energy(of: micURL)
            systemEnergy = try Self.energy(of: systemURL)
            var sides: [Int: [MeetingSelf.Side]] = [:]
            for unit in Self.units(of: segments) {
                let scores = timeline.scores(from: unit.start, to: unit.end)
                guard let best = scores.indices.max(by: { scores[$0] < scores[$1] }), scores[best] > 0,
                    let side = MeetingSelf.side(
                        micPower: micEnergy!.meanPower(from: unit.start, to: unit.end),
                        systemPower: systemEnergy!.meanPower(from: unit.start, to: unit.end))
                else { continue }
                sides[best, default: []].append(side)
            }
            micDominant = Dictionary(uniqueKeysWithValues: (0..<timeline.clusterCount).map { ($0, MeetingSelf.isMicDominant(sides[$0] ?? [])) })
        }

        // The profile, for the voices that could be the user.
        var similarity: [Int: Float]?
        if usesProfile, await voice.hasProfile, (try? await voice.requireReady()) != nil {
            let candidates: [Int]
            if let micDominant {
                candidates = micDominant.filter(\.value).map(\.key).sorted()
            } else {
                let seconds = diarization.soloSpeech.map { $0.reduce(0) { $0 + $1.upperBound - $1.lowerBound } }
                candidates = seconds.indices.filter { seconds[$0] >= Self.profileVoiceMinimum }
            }
            var found: [Int: Float] = [:]
            let reader = try MeetingTrackReader(url: mixURL)
            for voiceIndex in candidates {
                var scores: [Float] = []
                for stretch in diarization.soloSpeech[voiceIndex].prefix(Self.profileStretches)
                where stretch.upperBound - stretch.lowerBound >= Self.profileStretchMinimum {
                    let end = min(stretch.upperBound, stretch.lowerBound + Self.profileStretchCap)
                    let samples = try reader.samples(in: stretch.lowerBound..<end)
                    if let score = try? await voice.similarity(samples: samples) { scores.append(score) }
                }
                if !scores.isEmpty { found[voiceIndex] = scores.reduce(0, +) / Float(scores.count) }
            }
            similarity = found
        }

        let user = MeetingSelf.user(micDominant: micDominant, similarity: similarity)
        return SpeakerAnalysis(
            timeline: timeline, user: user, micDominant: micDominant, similarity: similarity, audioSeconds: diarization.audioSeconds,
            runSeconds: Self.seconds(ContinuousClock.now - began), segmentationSeconds: Self.seconds(diarization.segmentationTime),
            embeddingSeconds: Self.seconds(diarization.embeddingTime), windows: diarization.windows,
            embedded: (diarization.reliable, diarization.weak, diarization.guessed, diarization.unplaced),
            micEnergy: micEnergy, systemEnergy: systemEnergy)
    }

    /// The spans a transcript's speech is judged by: each timed word, else the whole segment.
    public static func units(of segments: [MeetingSegment]) -> [(start: TimeInterval, end: TimeInterval, segment: Int)] {
        segments.enumerated().flatMap { index, segment -> [(start: TimeInterval, end: TimeInterval, segment: Int)] in
            if let words = segment.words, !words.isEmpty { return words.map { ($0.start, $0.end, index) } }
            return [(segment.start, segment.end, index)]
        }
    }

    private static func energy(of url: URL) throws -> TrackEnergy {
        let reader = try MeetingTrackReader(url: url)
        var energy = TrackEnergy(sampleRate: MeetingTrackReader.sampleRate)
        while true {
            let block = try reader.next()
            if block.isEmpty { break }
            energy.append(block)
        }
        return energy
    }

    private static func seconds(_ duration: Duration) -> TimeInterval {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }
}
