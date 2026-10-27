import Foundation
import Testing
import LegatoCore
@testable import LegatoMeetings

@Suite struct SpeakerDirectoryTests {
    @Test func newPeopleGetStableIDsDefaultNamesAndDistinctColours() {
        var directory = SpeakerDirectory()
        let a = directory.add(), b = directory.add()
        #expect(a == "P1" && b == "P2")
        #expect(directory.speakers["P1"] == SpeakerInfo(name: "Speaker 1", colorIndex: 0, isYou: false))
        #expect(directory.speakers["P2"] == SpeakerInfo(name: "Speaker 2", colorIndex: 1, isYou: false))
    }

    @Test func aFreedColourIsReusedByTheNextPerson() {
        var directory = SpeakerDirectory()
        let a = directory.add(), b = directory.add()
        directory.merge(a, into: b)
        let c = directory.add()
        #expect(directory.speakers[c]?.colorIndex == 0)
    }

    @Test func renameChangesTheNameEverywhereItIsRead() {
        var directory = SpeakerDirectory()
        let a = directory.add()
        #expect(directory.rename(a, to: "  Alice ") == nil)
        #expect(directory.speakers[a]?.name == "Alice")
        #expect(directory.displayName(of: a) == "Alice")
    }

    @Test func aBlankNameGoesBackToTheDefault() {
        var directory = SpeakerDirectory()
        let a = directory.add(), _ = directory.add()
        directory.rename(a, to: "Alice")
        directory.rename(a, to: "   ")
        #expect(directory.speakers[a]?.name == "Speaker 1")
    }

    @Test func theSameNameMeansMerge() {
        var directory = SpeakerDirectory()
        let a = directory.add(), b = directory.add()
        directory.rename(a, to: "Alice")
        let merge = directory.rename(b, to: "alice ")
        #expect(merge == SpeakerDirectory.Merge(from: b, into: a))
        #expect(directory.speakers.keys.sorted() == [a])
        #expect(directory.speakers[a]?.name == "Alice")
    }

    @Test func aMergeRewritesSegmentsAndTurnsToTheSurvivor() {
        let merge = SpeakerDirectory.Merge(from: "P2", into: "P1")
        let segments = [
            MeetingSegment(stream: .mixed, text: "a", start: 0, end: 1, speaker: "P2"),
            MeetingSegment(stream: .mixed, text: "b", start: 1, end: 2, speaker: "P3"),
            MeetingSegment(stream: .mixed, text: "c", start: 2, end: 3),
        ]
        #expect(merge.apply(to: segments).map(\.speaker) == ["P1", "P3", nil])
        let turns = [SpeakerTurn(speaker: "P2", start: 0, end: 4), SpeakerTurn(speaker: "P3", start: 4, end: 5)]
        #expect(merge.apply(to: turns).map(\.speaker) == ["P1", "P3"])
    }

    @Test func mergingKeepsTheSurvivorsLookAndYouIfEitherWasYou() {
        var directory = SpeakerDirectory()
        let a = directory.add(), b = directory.add()
        directory.markAsYou(b)
        directory.merge(b, into: a)
        #expect(directory.speakers[a]?.isYou == true)
        #expect(directory.speakers[a]?.colorIndex == 0)
        #expect(directory.speakers[b] == nil)
    }

    @Test func onlyOnePersonIsYou() {
        var directory = SpeakerDirectory()
        let a = directory.add(), b = directory.add()
        directory.markAsYou(b)
        #expect(directory.speakers[b] == SpeakerInfo(name: "You", colorIndex: 1, isYou: true))
        directory.markAsYou(a)
        #expect(directory.speakers[a]?.isYou == true && directory.speakers[a]?.name == "You")
        #expect(directory.speakers[b] == SpeakerInfo(name: "Speaker 2", colorIndex: 1, isYou: false))
    }

    @Test func youKeepsTheFlagWhenRenamed() {
        var directory = SpeakerDirectory()
        let a = directory.add(isYou: true)
        directory.rename(a, to: "Jakob")
        #expect(directory.speakers[a] == SpeakerInfo(name: "Jakob", colorIndex: 0, isYou: true))
    }

    @Test func aPersonAddedAsYouIsNamedYou() {
        var directory = SpeakerDirectory()
        let a = directory.add(isYou: true)
        #expect(directory.speakers[a]?.name == "You" && directory.speakers[a]?.isYou == true)
    }

    @Test func idsContinueAfterTheHighestExistingOne() {
        var directory = SpeakerDirectory([
            "P4": SpeakerInfo(name: "Speaker 4", colorIndex: 0, isYou: false)
        ])
        #expect(directory.add() == "P5")
    }
}
