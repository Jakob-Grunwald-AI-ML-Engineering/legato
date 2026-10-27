import Foundation
import Testing
import LegatoCore
@testable import LegatoMeetings

@Suite struct SpeakerAssignerTests {
    func turn(_ speaker: String, _ start: TimeInterval, _ end: TimeInterval) -> SpeakerTurn {
        SpeakerTurn(speaker: speaker, start: start, end: end)
    }

    func seg(_ text: String, _ start: TimeInterval, _ end: TimeInterval, speaker: String? = nil) -> MeetingSegment {
        MeetingSegment(stream: .mixed, text: text, start: start, end: end, speaker: speaker)
    }

    // MARK: Overlap

    @Test func aSegmentGoesToTheSpeakerWithTheMostOverlap() {
        let turns = [turn("P1", 0, 5), turn("P2", 5, 10)]
        #expect(SpeakerAssigner.speaker(start: 4, end: 7, turns: turns) == "P2")  // 1 s vs 2 s
        #expect(SpeakerAssigner.speaker(start: 1, end: 3, turns: turns) == "P1")
    }

    @Test func overlapAddsUpAcrossSeveralTurnsOfOneSpeaker() {
        let turns = [turn("P1", 0, 2), turn("P2", 2, 4), turn("P1", 4, 6)]
        #expect(SpeakerAssigner.speaker(start: 0, end: 6, turns: turns) == "P1")
    }

    @Test func noOverlapMeansNobody() {
        #expect(SpeakerAssigner.speaker(start: 20, end: 21, turns: [turn("P1", 0, 5)]) == nil)
        #expect(SpeakerAssigner.speaker(start: 0, end: 1, turns: []) == nil)
    }

    @Test func aTieGoesToTheEarlierSpeaker() {
        let turns = [turn("P2", 0, 5), turn("P1", 5, 10)]
        #expect(SpeakerAssigner.speaker(start: 4, end: 6, turns: turns) == "P2")
    }

    @Test func aSegmentWithoutLengthTakesTheTurnItFallsIn() {
        let turns = [turn("P1", 0, 5), turn("P2", 5, 10)]
        #expect(SpeakerAssigner.speaker(start: 7, end: 7, turns: turns) == "P2")
    }

    @Test func offlineTurnsBeatLiveOnesWhenThereAreAny() {
        let live = [turn("P1", 0, 5)], offline = [turn("P2", 0, 5)]
        #expect(SpeakerAssigner.bestTurns(live: live, offline: offline) == offline)
        #expect(SpeakerAssigner.bestTurns(live: live, offline: []) == live)
        #expect(SpeakerAssigner.bestTurns(live: live, offline: nil) == live)
    }

    @Test func assignLabelsEverySegment() {
        let out = SpeakerAssigner.assign([seg("a", 0, 2), seg("b", 6, 8), seg("c", 30, 31)], turns: [turn("P1", 0, 5), turn("P2", 5, 10)])
        #expect(out.map(\.speaker) == ["P1", "P2", nil])
    }

    // MARK: Deferred relabel

    @Test func onlySegmentsThatEndedInTheLastThreeSecondsAreRelabelled() {
        let segments = [seg("old", 10, 12, speaker: "P1"), seg("recent", 36, 38, speaker: "P1"), seg("fresh", 38, 39.5)]
        // The diarizer now says P2 spoke all along.
        let out = SpeakerAssigner.relabelRecent(segments, turns: [turn("P2", 0, 40)], now: 40)
        #expect(out.map(\.speaker) == ["P1", "P2", "P2"])
    }

    @Test func withoutAnyTurnsARecentSegmentKeepsItsLabel() {
        let out = SpeakerAssigner.relabelRecent([seg("x", 38, 39, speaker: "P1")], turns: [], now: 40)
        #expect(out[0].speaker == "P1")  // no turns at all: nothing to say, keep what was there
    }

    @Test func theRelabelWindowEdgeIsInclusiveOfSegmentsEndingExactlyThreeSecondsAgo() {
        let out = SpeakerAssigner.relabelRecent([seg("x", 35, 37)], turns: [turn("P1", 0, 40)], now: 40)
        #expect(out[0].speaker == "P1")
        let older = SpeakerAssigner.relabelRecent([seg("y", 34, 36.9)], turns: [turn("P1", 0, 40)], now: 40)
        #expect(older[0].speaker == nil)
    }

    // MARK: Offline clusters onto persons

    @Test func offlineClustersMapOntoPersonsByMaximumOverlapKeepingNames() {
        var directory = SpeakerDirectory()
        let p1 = directory.add(), p2 = directory.add()
        directory.rename(p2, to: "Alice")
        let live = [turn(p1, 0, 10), turn(p2, 10, 20)]
        let offline = [turn("a", 0, 9.5), turn("b", 10.5, 19), turn("a", 20, 22)]

        let result = SpeakerAssigner.mapOffline(offline, onto: live, directory: &directory)
        #expect(result.map(\.speaker) == [p1, p2, p1])
        #expect(directory.speakers.count == 2)
        #expect(directory.speakers[p1]?.name == "Speaker 1" && directory.speakers[p2]?.name == "Alice")
    }

    @Test func aClusterNothingOverlapsBecomesANewPerson() {
        var directory = SpeakerDirectory()
        let p1 = directory.add()
        let result = SpeakerAssigner.mapOffline(
            [turn("a", 0, 10), turn("c", 20, 30)], onto: [turn(p1, 0, 10)], directory: &directory)
        #expect(result[0].speaker == p1)
        #expect(result[1].speaker == "P2")
        #expect(directory.speakers["P2"]?.name == "Speaker 2")
    }

    @Test func clustersAreNewPeopleWhenThereWasNoLiveDiarization() {
        var directory = SpeakerDirectory()
        let result = SpeakerAssigner.mapOffline([turn("x", 0, 5), turn("y", 5, 9), turn("x", 9, 12)], onto: [], directory: &directory)
        #expect(result.map(\.speaker) == ["P1", "P2", "P1"])
        #expect(directory.speakers.count == 2)
    }

    @Test func aMergeTheUserMadeSurvivesBecauseBothClustersLandOnTheSurvivor() {
        var directory = SpeakerDirectory()
        let p1 = directory.add()
        // The user merged P2 into P1: the live turns only know P1.
        let live = [turn(p1, 0, 20)]
        let result = SpeakerAssigner.mapOffline([turn("a", 0, 10), turn("b", 10, 20)], onto: live, directory: &directory)
        #expect(result.map(\.speaker) == [p1, p1])
        #expect(directory.speakers.count == 1)
    }

    @Test func aClusterOverlappingTwoPersonsPicksTheLargerOverlap() {
        var directory = SpeakerDirectory()
        let p1 = directory.add(), p2 = directory.add()
        let result = SpeakerAssigner.mapOffline(
            [turn("a", 0, 10)], onto: [turn(p1, 0, 3), turn(p2, 3, 10)], directory: &directory)
        #expect(result[0].speaker == p2)
    }
}
