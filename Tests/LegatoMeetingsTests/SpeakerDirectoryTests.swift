import Foundation
import Testing
import LegatoCore
@testable import LegatoMeetings

@Suite struct SpeakerDirectoryTests {
    @Test func newPeopleGetStableIDsDefaultNamesAndDistinctColours() {
        var directory = SpeakerDirectory()
        let a = directory.add(), b = directory.add()
        #expect(a == "P1" && b == "P2")
        #expect(directory.speakers["P1"] == SpeakerInfo(name: "Speaker 1", colorIndex: 0))
        #expect(directory.speakers["P2"] == SpeakerInfo(name: "Speaker 2", colorIndex: 1))
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

    @Test func mergingKeepsTheSurvivorsLook() {
        var directory = SpeakerDirectory()
        let a = directory.add(), b = directory.add()
        directory.merge(b, into: a)
        #expect(directory.speakers[a]?.colorIndex == 0)
        #expect(directory.speakers[b] == nil)
    }

    @Test func idsContinueAfterTheHighestExistingOne() {
        var directory = SpeakerDirectory([
            "P4": SpeakerInfo(name: "Speaker 4", colorIndex: 0)
        ])
        #expect(directory.add() == "P5")
    }

    @Test func aStoredIsYouKeyStillDecodesAndIsIgnored() throws {
        let old = Data(#"{"name":"You","colorIndex":2,"isYou":true}"#.utf8)
        let info = try JSONDecoder().decode(SpeakerInfo.self, from: old)
        #expect(info == SpeakerInfo(name: "You", colorIndex: 2))
        #expect(!String(decoding: try JSONEncoder().encode(info), as: UTF8.self).contains("isYou"))
    }
}
