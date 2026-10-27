import Foundation
import Testing
import LegatoCore
@testable import LegatoMeetings

@Suite struct MeetingStoreTests {
    func meeting(_ title: String, at t: TimeInterval) -> Meeting {
        Meeting(title: title, date: Date(timeIntervalSince1970: t), engineID: "fake")
    }

    func seg(_ text: String, _ start: TimeInterval) -> MeetingSegment {
        MeetingSegment(stream: .mic, text: text, start: start, end: start + 1)
    }

    @Test func createThenReadBack() async throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(root: root)
        let m = meeting("Sync", at: 1)
        try await store.create(m)
        #expect(try await store.meeting(id: m.id) == m)
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent(m.id.uuidString).appendingPathComponent("meeting.json").path))
    }

    @Test func unknownMeetingIsNil() async throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(try await MeetingStore(root: root).meeting(id: UUID()) == nil)
    }

    @Test func meetingsListNewestFirst() async throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(root: root)
        let a = meeting("a", at: 1), b = meeting("b", at: 3), c = meeting("c", at: 2)
        for m in [a, b, c] { try await store.create(m) }
        #expect(try await store.meetings().map(\.title) == ["b", "c", "a"])
    }

    @Test func updateReplacesMeeting() async throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(root: root)
        var m = meeting("Sync", at: 1)
        try await store.create(m)
        m.state = .finished
        m.duration = 90
        try await store.update(m)
        #expect(try await store.meeting(id: m.id) == m)
    }

    @Test func segmentsSurviveAReopenInTheMiddleOfAMeeting() async throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let m = meeting("Sync", at: 1)
        let first = MeetingStore(root: root)
        try await first.create(m)
        let a = seg("one", 1), b = seg("two", 5)
        try await first.appendSegment(a, to: m.id)
        try await first.appendSegment(b, to: m.id)

        let reopened = MeetingStore(root: root)
        #expect(try await reopened.segments(for: m.id) == [a, b])
        let c = seg("three", 9)
        try await reopened.appendSegment(c, to: m.id)
        #expect(try await reopened.segments(for: m.id) == [a, b, c])
    }

    @Test func segmentsComeBackOrderedByStart() async throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(root: root)
        let m = meeting("Sync", at: 1)
        try await store.create(m)
        for s in [seg("late", 9), seg("early", 1), seg("mid", 5)] { try await store.appendSegment(s, to: m.id) }
        #expect(try await store.segments(for: m.id).map(\.text) == ["early", "mid", "late"])
    }

    @Test func replaceSegmentsRewritesThem() async throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(root: root)
        let m = meeting("Sync", at: 1)
        try await store.create(m)
        try await store.appendSegment(seg("old", 1), to: m.id)
        let fresh = [seg("new", 2)]
        try await store.replaceSegments(fresh, for: m.id)
        #expect(try await store.segments(for: m.id) == fresh)
    }

    @Test func segmentsOfAMeetingWithNoneAreEmpty() async throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(root: root)
        let m = meeting("Sync", at: 1)
        try await store.create(m)
        #expect(try await store.segments(for: m.id).isEmpty)
    }

    @Test func liveSegmentsAreSavedOnlyOnce() async throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(root: root)
        let id = UUID()
        #expect(try await store.liveSegments(for: id).isEmpty)
        let first = [seg("one", 1)], second = [seg("two", 2)]
        #expect(try await store.saveLiveSegmentsOnce(first, for: id))
        #expect(try await store.saveLiveSegmentsOnce(second, for: id) == false)
        #expect(try await store.liveSegments(for: id) == first)
    }

    private func permissions(_ url: URL) throws -> Int {
        try #require(try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int)
    }

    #if os(macOS)
    @Test func theMeetingsRootAndFoldersAreOwnerOnly() async throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        // A root an earlier version created with the default permissions is tightened too.
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        let store = MeetingStore(root: root)
        let m = meeting("Sync", at: 1)
        try await store.create(m)
        try await store.saveSummary("## Summary", backendID: "fm", for: m.id)

        #expect(try permissions(root) == 0o700)
        #expect(try permissions(await store.folder(for: m.id)) == 0o700)
        #expect(try permissions(await store.folder(for: m.id).appendingPathComponent("meeting.json")) == 0o600)
        #expect(try permissions(await store.summaryURL(for: m.id, backendID: "fm")) == 0o600)
    }

    @Test func theSegmentFilesAreOwnerOnlyWhetherAppendedOrRewritten() async throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(root: root)
        let id = UUID()
        try await store.appendSegment(seg("one", 1), to: id)
        #expect(try permissions(await store.segmentsURL(for: id)) == 0o600, "appended")
        try await store.replaceSegments([seg("two", 2)], for: id)
        #expect(try permissions(await store.segmentsURL(for: id)) == 0o600, "rewritten")
        _ = try await store.saveLiveSegmentsOnce([seg("live", 3)], for: id)
        #expect(try permissions(await store.liveSegmentsURL(for: id)) == 0o600, "live text")
    }

    @Test func aNewRootIsOwnerOnlyEvenWhenItsParentIsMissing() async throws {
        let parent = tempRoot()
        defer { try? FileManager.default.removeItem(at: parent) }
        let root = parent.appendingPathComponent("Legato/Meetings")
        let store = MeetingStore(root: root)
        let folder = try await store.createFolder(for: UUID())
        #expect(try permissions(root) == 0o700)
        #expect(try permissions(folder) == 0o700)
    }
    #endif

    @Test func updateMergesOntoWhatIsOnDisk() async throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(root: root)
        let m = meeting("Sync", at: 1)
        try await store.create(m)
        var renamed = m
        renamed.title = "Renamed"
        try await store.update(renamed)

        let merged = try await store.update(id: m.id) { $0.duration = 42 }
        #expect(merged?.title == "Renamed" && merged?.duration == 42)
        #expect(try await store.meeting(id: m.id) == merged)
        #expect(try await store.update(id: UUID()) { $0.duration = 1 } == nil)
    }

    // MARK: Old data

    @Test func meetingsSavedBeforeTheRedesignDecodeWithDefaults() async throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(root: root)
        let id = UUID()
        let folder = try await store.createFolder(for: id)
        let json = """
            {"id": "\(id.uuidString)", "title": "Old", "date": 1000, "duration": 60, "engineID": "e",
             "mutedRanges": [{"stream": "mic", "start": 1, "end": 2}], "state": "finished"}
            """
        try Data(json.utf8).write(to: folder.appendingPathComponent("meeting.json"))
        let m = try #require(try await store.meeting(id: id))
        #expect(m.speakers.isEmpty && m.pausedRanges.isEmpty && m.locale == nil)
        #expect(m.templateID == SummaryTemplate.summaryID && m.completedSteps.isEmpty)
        #expect(m.mutedRanges == [MutedRange(stream: .mic, start: 1, end: 2)])
    }

    @Test func theNewMeetingFieldsRoundTrip() async throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(root: root)
        var m = meeting("New", at: 1)
        m.speakers = ["P1": SpeakerInfo(name: "You", colorIndex: 0, isYou: true), "P2": SpeakerInfo(name: "Alice", colorIndex: 1, isYou: false)]
        m.pausedRanges = [PausedRange(start: 120, end: 150)]
        m.locale = "de-DE"
        m.templateID = "action-items"
        m.completedSteps = [.audio, .diarize]
        try await store.create(m)
        #expect(try await store.meeting(id: m.id) == m)
    }

    @Test func segmentsSavedBeforeSpeakersExistedDecodeWithoutOne() async throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(root: root)
        let id = UUID()
        let folder = try await store.createFolder(for: id)
        let line = """
            {"id": "\(UUID().uuidString)", "stream": "system", "text": "Hi", "start": 1, "end": 2, "origin": "live", "echo": false}
            """
        try Data((line + "\n").utf8).write(to: folder.appendingPathComponent("segments.jsonl"))
        let segments = try await store.segments(for: id)
        #expect(segments.count == 1 && segments[0].speaker == nil && segments[0].stream == .system)
    }

    @Test func aSegmentsSpeakerRoundTrips() async throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(root: root)
        let m = meeting("S", at: 1)
        try await store.create(m)
        let s = MeetingSegment(stream: .mixed, text: "x", start: 1, end: 2, speaker: "P3")
        try await store.appendSegment(s, to: m.id)
        #expect(try await store.segments(for: m.id) == [s])
    }

    // MARK: Notes

    @Test func notesAreSavedAndReadBack() async throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(root: root)
        let m = meeting("N", at: 1)
        try await store.create(m)
        #expect(try await store.notes(for: m.id) == nil)
        try await store.saveNotes("- ask about budget", for: m.id)
        #expect(try await store.notes(for: m.id) == "- ask about budget")
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent(m.id.uuidString).appendingPathComponent("notes.md").path))
    }

    @Test func emptyNotesAreNoNotes() async throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(root: root)
        let m = meeting("N", at: 1)
        try await store.create(m)
        try await store.saveNotes("x", for: m.id)
        try await store.saveNotes("  \n", for: m.id)
        #expect(try await store.notes(for: m.id) == nil)
    }

    #if os(macOS)
    @Test func notesAndTurnsAreOwnerOnly() async throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(root: root)
        let m = meeting("N", at: 1)
        try await store.create(m)
        try await store.saveNotes("private", for: m.id)
        try await store.saveLiveTurns([SpeakerTurn(speaker: "P1", start: 0, end: 1)], for: m.id)
        try await store.saveOfflineTurns([SpeakerTurn(speaker: "P1", start: 0, end: 1)], for: m.id)
        let folder = await store.folder(for: m.id)
        #expect(try permissions(folder.appendingPathComponent("notes.md")) == 0o600)
        #expect(try permissions(folder.appendingPathComponent("turns.live.jsonl")) == 0o600)
        #expect(try permissions(folder.appendingPathComponent("turns.offline.json")) == 0o600)
    }

    @Test func summariesLiveInPrivateTemplateFolders() async throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(root: root)
        let m = meeting("S", at: 1)
        try await store.create(m)
        try await store.saveSummary("## Summary", backendID: "fm", templateID: "action-items", for: m.id)
        let folder = await store.folder(for: m.id).appendingPathComponent("summaries")
        #expect(try permissions(folder) == 0o700)
        #expect(try permissions(folder.appendingPathComponent("action-items")) == 0o700)
        #expect(try permissions(folder.appendingPathComponent("action-items/fm.md")) == 0o600)
    }
    #endif

    // MARK: Turns

    @Test func liveTurnsAreRewrittenAndReadBack() async throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(root: root)
        let id = UUID()
        #expect(try await store.liveTurns(for: id).isEmpty)
        try await store.saveLiveTurns([SpeakerTurn(speaker: "P1", start: 0, end: 2)], for: id)
        let second = [SpeakerTurn(speaker: "P1", start: 0, end: 3), SpeakerTurn(speaker: "P2", start: 3, end: 4)]
        try await store.saveLiveTurns(second, for: id)
        #expect(try await MeetingStore(root: root).liveTurns(for: id) == second)
    }

    @Test func offlineTurnsAreNilUntilSavedAndKeepAnEmptyResult() async throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(root: root)
        let id = UUID()
        #expect(try await store.offlineTurns(for: id) == nil)
        try await store.saveOfflineTurns([], for: id)
        #expect(try await store.offlineTurns(for: id) == [], "an offline pass that found nobody is still a result")
        let turns = [SpeakerTurn(speaker: "P2", start: 1, end: 2)]
        try await store.saveOfflineTurns(turns, for: id)
        #expect(try await store.offlineTurns(for: id) == turns)
    }

    // MARK: Summaries by template

    @Test func summariesAreSavedPerTemplateAndBackend() async throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(root: root)
        let m = meeting("S", at: 1)
        try await store.create(m)
        try await store.saveSummary("A", backendID: "mlx/qwen 3", templateID: "action-items", for: m.id)
        try await store.saveSummary("B", backendID: "mlx/qwen 3", for: m.id)  // the default template
        let url = await store.summaryURL(for: m.id, templateID: "action-items", backendID: "mlx/qwen 3")
        #expect(url.path.hasSuffix("\(m.id.uuidString)/summaries/action-items/mlx-qwen-3.md"))
        #expect(await store.summaryURL(for: m.id, backendID: "mlx/qwen 3").path.hasSuffix("/summaries/summary/mlx-qwen-3.md"))

        let all = try await store.summaries(for: m.id)
        #expect(Set(all.map { "\($0.templateID)/\($0.backendID)=\($0.text)" }) == ["action-items/mlx-qwen-3=A", "summary/mlx-qwen-3=B"])
        #expect(try await store.summaries(for: m.id, templateID: "action-items").map(\.text) == ["A"])
    }

    @Test func aLegacySummaryFileReadsAsTheSummaryTemplate() async throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(root: root)
        let m = meeting("S", at: 1)
        try await store.create(m)
        let folder = await store.folder(for: m.id)
        try Data("old".utf8).write(to: folder.appendingPathComponent("summary-foundation-models.md"))
        try Data("claude old".utf8).write(to: folder.appendingPathComponent("summary-claude.md"))

        let all = try await store.summaries(for: m.id)
        #expect(Set(all.map { "\($0.templateID)/\($0.backendID)=\($0.text)" }) == ["summary/foundation-models=old", "summary/claude=claude old"])

        // A fresh summary of the same template and backend supersedes the legacy file.
        try await store.saveSummary("new", backendID: "foundation-models", for: m.id)
        let after = try await store.summaries(for: m.id, templateID: "summary")
        #expect(after.filter { $0.backendID == "foundation-models" }.map(\.text) == ["new"])
        #expect(after.count == 2)
    }

    // MARK: Stale summaries

    private func setModified(_ url: URL, secondsAgo: TimeInterval) throws {
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -secondsAgo)], ofItemAtPath: url.path)
    }

    @Test func aNotesEditAfterASummaryMarksItStale() async throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(root: root)
        let m = meeting("S", at: 1)
        try await store.create(m)
        try await store.saveNotes("first", for: m.id)
        try await store.saveSummary("S", backendID: "fm", for: m.id)
        try setModified(await store.notesURL(for: m.id), secondsAgo: 100)
        try setModified(await store.summaryURL(for: m.id, backendID: "fm"), secondsAgo: 50)
        #expect(try await store.summaries(for: m.id).first?.isStale == false)

        try await store.saveNotes("first, edited", for: m.id)  // now: after the summary
        #expect(try await store.summaries(for: m.id).first?.isStale == true)

        // Regenerating brings it up to date.
        try await store.saveSummary("S2", backendID: "fm", for: m.id)
        #expect(try await store.summaries(for: m.id).first?.isStale == false)
    }

    @Test func savingTheSameNotesAgainDoesNotMakeASummaryStale() async throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(root: root)
        let m = meeting("S", at: 1)
        try await store.create(m)
        try await store.saveNotes("same", for: m.id)
        try await store.saveSummary("S", backendID: "fm", for: m.id)
        try setModified(await store.notesURL(for: m.id), secondsAgo: 100)
        try setModified(await store.summaryURL(for: m.id, backendID: "fm"), secondsAgo: 50)
        try await store.saveNotes("same", for: m.id)
        #expect(try await store.summaries(for: m.id).first?.isStale == false)
    }

    @Test func aSummaryOfAMeetingWithoutNotesIsNeverStale() async throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(root: root)
        let m = meeting("S", at: 1)
        try await store.create(m)
        try await store.saveSummary("S", backendID: "fm", for: m.id)
        #expect(try await store.summaries(for: m.id).first?.isStale == false)
    }

    // MARK: Discard

    @Test func deletingAMeetingRemovesItsFolderAndWhatIsCachedForIt() async throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(root: root)
        let keep = meeting("Keep", at: 1), drop = meeting("Drop", at: 2)
        try await store.create(keep)
        try await store.create(drop)
        try await store.appendSegment(seg("x", 1), to: drop.id)
        try await store.saveNotes("n", for: drop.id)

        try await store.deleteMeeting(id: drop.id)
        #expect(try await store.meeting(id: drop.id) == nil)
        #expect(!FileManager.default.fileExists(atPath: await store.folder(for: drop.id).path))
        #expect(try await store.meetings().map(\.title) == ["Keep"])
        #expect(try await store.segments(for: drop.id).isEmpty)
        try await store.deleteMeeting(id: drop.id)  // already gone: not an error
    }
}
