import Foundation
import Testing
import LegatoCore
@testable import LegatoMeetings

@Suite struct SpeakerCleanupTests {
    // MARK: Helpers

    /// A timeline where `voices[i]` speaks alone over `spans[i]` (seconds).
    private func timeline(duration: TimeInterval, _ spans: [(voice: Int, from: TimeInterval, to: TimeInterval)], voices: Int) -> SpeakerTimeline {
        var timeline = SpeakerTimeline(clusters: voices, duration: duration)
        for span in spans {
            for frame in SpeakerTimeline.frameIndex(span.from)..<SpeakerTimeline.frameIndex(span.to) {
                timeline.set(1, cluster: span.voice, frame: frame)
            }
        }
        return timeline
    }

    /// Words of 0.4 s each, back to back from `start`.
    private func words(_ texts: [String], from start: TimeInterval) -> [TranscriptWord] {
        texts.enumerated().map { TranscriptWord(text: $0.element, start: start + Double($0.offset) * 0.4, end: start + Double($0.offset + 1) * 0.4) }
    }

    private func segment(_ texts: [String], from start: TimeInterval, speaker: PersonID?, timed: Bool = true) -> MeetingSegment {
        let w = words(texts, from: start)
        return MeetingSegment(text: texts.joined(separator: " "), start: start, end: w.last!.end, speaker: speaker, words: timed ? w : nil)
    }

    private func people(_ count: Int) -> SpeakerDirectory {
        var directory = SpeakerDirectory()
        for _ in 0..<count { directory.add() }
        return directory
    }

    // MARK: Segments on disk

    @Test func segmentsSavedBeforeWordTimesStillLoad() throws {
        let id = UUID()
        let old = #"{"id":"\#(id.uuidString)","stream":"mixed","text":"Hello there","start":1.5,"end":2.5,"speaker":"P1"}"#
        let segment = try JSONDecoder().decode(MeetingSegment.self, from: Data(old.utf8))
        #expect(segment == MeetingSegment(id: id, text: "Hello there", start: 1.5, end: 2.5, speaker: "P1"))
        #expect(segment.words == nil)
        let written = String(decoding: try JSONEncoder().encode(segment), as: UTF8.self)
        #expect(!written.contains("words"), "a segment without word times is written as before")
    }

    @Test func wordTimesRoundTrip() throws {
        let segment = segment(["Hello", "there"], from: 3, speaker: "P2")
        let decoded = try JSONDecoder().decode(MeetingSegment.self, from: try JSONEncoder().encode(segment))
        #expect(decoded == segment)
        #expect(decoded.words?.map(\.start) == [3, 3.4])
    }

    @Test func wordsArePlacedFromTheirStreamTimes() {
        let placed = TranscriptWord.placed(["a", "b"], relative: [(10, 10.2), (10.3, 10.5)], origin: 100)
        #expect(placed == [TranscriptWord(text: "a", start: 100, end: 100.2), TranscriptWord(text: "b", start: 100.3, end: 100.5)])
        #expect(TranscriptWord.placed(["a", "b"], relative: [(10, 10.2), (nil, nil)], origin: 100) == nil, "timed all or none")
    }

    // MARK: Reassignment

    @Test func aBargeInIsSplitOffAndTheFirstPartKeepsTheID() {
        // P1 speaks 0–2 s, P2 barges in at 2–2.8 s; the live engine gave all of it to P1. P2 speaks again later.
        let first = segment(["one", "two", "three", "four", "five", "yes", "but"], from: 0, speaker: "P1")
        let later = segment(["I", "said", "so"], from: 5, speaker: "P2")
        let voices = timeline(duration: 7, [(0, 0, 2), (1, 2, 2.8), (1, 5, 6.2)], voices: 2)
        let result = SpeakerReassignment.apply(voices, user: nil, to: [first, later], directory: people(2))

        #expect(result.segments.count == 3)
        #expect(result.segments[0].id == first.id && result.segments[0].speaker == "P1")
        #expect(result.segments[0].text == "one two three four five")
        #expect(result.segments[0].start == 0 && result.segments[0].end == 2)
        #expect(result.segments[1].id != first.id && result.segments[1].speaker == "P2")
        #expect(result.segments[1].text == "yes but" && result.segments[1].start == 2 && result.segments[1].end == first.end)
        #expect(result.segments[2] == later)
        #expect(result.splitSegments == 1 && result.addedSegments == 1 && result.movedWords == 2)
    }

    @Test func aSegmentWithoutWordTimesMovesWhole() {
        let untimed = segment(["hello", "there"], from: 0, speaker: "P1", timed: false)
        let other = segment(["fine", "thanks"], from: 2, speaker: "P2")
        let p1Elsewhere = segment(["and", "you"], from: 4, speaker: "P1")
        // The untimed segment is voice 1's, like P2's words; P1's other words are voice 0's.
        let voices = timeline(duration: 6, [(1, 0, 0.8), (1, 2, 2.8), (0, 4, 4.8)], voices: 2)
        let result = SpeakerReassignment.apply(voices, user: nil, to: [untimed, other, p1Elsewhere], directory: people(2))
        #expect(result.segments.map(\.speaker) == ["P2", "P2", "P1"])
        #expect(result.segments[0].id == untimed.id && result.splitSegments == 0)
    }

    @Test func aRenumberedDuplicateIsMergedIntoTheNamedPerson() {
        // P3 is P1's voice under a new label after a reconnect; the user named P3.
        var directory = people(3)
        directory.rename("P3", to: "Anna")
        let segments = [
            segment(["a", "b"], from: 0, speaker: "P1"),
            segment(["c", "d"], from: 2, speaker: "P2"),
            segment(["e", "f"], from: 4, speaker: "P3"),
        ]
        let voices = timeline(duration: 6, [(0, 0, 0.8), (1, 2, 2.8), (0, 4, 4.8)], voices: 2)
        let result = SpeakerReassignment.apply(voices, user: nil, to: segments, directory: directory)
        #expect(result.merges == [SpeakerDirectory.Merge(from: "P1", into: "P3")])
        #expect(result.segments.map(\.speaker) == ["P3", "P2", "P3"])
        #expect(result.directory.speakers["P3"]?.name == "Anna")
        #expect(result.directory.speakers["P1"] == nil && result.directory.merged["P1"] == "P3")
    }

    @Test func twoPeopleNamedDifferentlyAreNeverMerged() {
        var directory = people(2)
        directory.rename("P1", to: "Anna")
        directory.rename("P2", to: "Ben")
        let segments = [segment(["a", "b"], from: 0, speaker: "P1"), segment(["c", "d"], from: 2, speaker: "P2")]
        let voices = timeline(duration: 4, [(0, 0, 0.8), (0, 2, 2.8)], voices: 1)
        let result = SpeakerReassignment.apply(voices, user: nil, to: segments, directory: directory)
        #expect(result.merges.isEmpty)
        #expect(result.segments.map(\.speaker) == ["P1", "P2"])
    }

    @Test func aVoiceNobodyHoldsBecomesANewPerson() {
        // The live engine heard two people as P1; the second voice speaks enough words to be someone.
        let count = SpeakerReassignment.minimumWordsForNewPerson
        let first = segment((0...count).map { "a\($0)" }, from: 0, speaker: "P1")
        let second = segment((0..<count).map { "b\($0)" }, from: first.end + 1, speaker: "P1")
        let end = second.end
        let voices = timeline(duration: end + 1, [(0, 0, first.end), (1, second.start, end)], voices: 2)
        let result = SpeakerReassignment.apply(voices, user: nil, to: [first, second], directory: people(1))
        #expect(result.newPeople == ["P2"])
        #expect(result.segments.map(\.speaker) == ["P1", "P2"])
        #expect(result.directory.speakers["P2"]?.name == "Speaker 2")
    }

    @Test func theUsersVoiceIsNamedMeUnlessTheUserNamedIt() {
        let segments = [segment(["a", "b"], from: 0, speaker: "P1"), segment(["c", "d"], from: 2, speaker: "P2")]
        let voices = timeline(duration: 4, [(0, 0, 0.8), (1, 2, 2.8)], voices: 2)
        let unnamed = SpeakerReassignment.apply(voices, user: 1, to: segments, directory: people(2))
        #expect(unnamed.user == "P2" && unnamed.directory.speakers["P2"]?.name == "Me")

        var named = people(2)
        named.rename("P2", to: "Jo")
        let kept = SpeakerReassignment.apply(voices, user: 1, to: segments, directory: named)
        #expect(kept.user == "P2" && kept.directory.speakers["P2"]?.name == "Jo")
    }

    @Test func inAnOverlapTheLiveLabelDecides() {
        // Both voices speak during "maybe": P2's word stays P2's though voice 0 is a little louder there.
        let segments = [
            segment(["a", "b"], from: 0, speaker: "P1"),
            segment(["c", "d"], from: 2, speaker: "P2"),
            segment(["maybe"], from: 4, speaker: "P2"),
        ]
        var voices = timeline(duration: 5, [(0, 0, 0.8), (1, 2, 2.8), (0, 4, 4.4)], voices: 2)
        for frame in SpeakerTimeline.frameIndex(4)..<SpeakerTimeline.frameIndex(4.4) { voices.set(0.8, cluster: 1, frame: frame) }
        let result = SpeakerReassignment.apply(voices, user: nil, to: segments, directory: people(2))
        #expect(result.segments.map(\.speaker) == ["P1", "P2", "P2"])
        #expect(result.movedWords == 0)
    }

    // MARK: People

    @Test func aSplitAddsSomeoneNewAndKeepsTheOthers() {
        var directory = people(2)
        directory.rename("P1", to: "Anna")
        directory.merge("P2", into: "P1")
        let added = directory.split(from: "P1")
        #expect(added == "P3", "an id merged away is never given again")
        #expect(directory.speakers["P1"] == SpeakerInfo(name: "Anna", colorIndex: 0))
        #expect(directory.speakers["P3"]?.name == "Speaker 3")
        #expect(directory.isRenamed("P1") && !directory.isRenamed("P3"))
    }

    // MARK: Me and them

    @Test func theLouderTrackDecidesAWord() {
        var mic = TrackEnergy(), system = TrackEnergy()
        let second = 16_000
        // 0–1 s: the user (loud mic, quiet echo); 1–2 s: a remote voice; 2–3 s: both about as loud; 3–4 s: near silence.
        mic.append([Float](repeating: 0.3, count: second) + [Float](repeating: 0.01, count: second)
                   + [Float](repeating: 0.2, count: second) + [Float](repeating: 0.0005, count: second))
        system.append([Float](repeating: 0.01, count: second) + [Float](repeating: 0.3, count: second)
                      + [Float](repeating: 0.2, count: second) + [Float](repeating: 0.0001, count: second))
        func side(_ from: TimeInterval, _ to: TimeInterval) -> MeetingSelf.Side? {
            MeetingSelf.side(micPower: mic.meanPower(from: from, to: to), systemPower: system.meanPower(from: from, to: to))
        }
        #expect(side(0.2, 0.6) == .mic)
        #expect(side(1.2, 1.6) == .system)
        #expect(side(2.2, 2.6) == nil, "neither is clearly louder")
        #expect(side(3.2, 3.6) == nil, "too quiet to tell")
    }

    @Test func theUserIsAMicrophoneVoiceThatMatchesTheProfile() {
        let sides: [MeetingSelf.Side] = Array(repeating: .mic, count: 9) + [.system]
        #expect(MeetingSelf.isMicDominant(sides))
        #expect(!MeetingSelf.isMicDominant(Array(repeating: .mic, count: 3)), "too few words")
        #expect(!MeetingSelf.isMicDominant(Array(repeating: .mic, count: 6) + Array(repeating: .system, count: 4)))

        // Mac with a profile: the microphone voice that matches; a remote voice never, however similar.
        #expect(MeetingSelf.user(micDominant: [0: true, 1: false, 2: true], similarity: [0: 0.2, 1: 0.9, 2: 0.6]) == 2)
        #expect(MeetingSelf.user(micDominant: [0: true, 1: false], similarity: [0: 0.2]) == nil)
        // Mac without a profile: only when one voice is the microphone's.
        #expect(MeetingSelf.user(micDominant: [0: true, 1: false], similarity: nil) == 0)
        #expect(MeetingSelf.user(micDominant: [0: true, 1: true], similarity: nil) == nil, "two people in the room")
        // iPhone: the profile alone; without it, nobody.
        #expect(MeetingSelf.user(micDominant: nil, similarity: [0: 0.3, 1: 0.7]) == 1)
        #expect(MeetingSelf.user(micDominant: nil, similarity: nil) == nil)
    }

    // MARK: Clustering

    @Test func clusteringGroupsSimilarEmbeddings() {
        func vector(_ angle: Float) -> [Float] { [cos(angle), sin(angle), 0] }
        let a = [vector(0), vector(0.1), vector(0.05)]
        let b = [vector(1.5), vector(1.55)]
        let labels = SpeakerClustering.agglomerate([a[0], b[0], a[1], b[1], a[2]], threshold: 0.8)
        #expect(labels == [0, 1, 0, 1, 0])
        #expect(Set(SpeakerClustering.agglomerate([a[0], b[0]], threshold: -1)) == [0], "a low enough threshold joins everyone")

        let centroids = SpeakerClustering.centroids([a[0], b[0], a[1], b[1], a[2]], labels: labels)
        #expect(SpeakerClustering.nearest(vector(0.02), centroids: centroids)?.label == 0)
        #expect(SpeakerClustering.nearest(vector(0.02), centroids: centroids, excluding: [0])?.label == 1)
    }
}
