import Foundation
import Testing
@testable import LegatoMeetings

@Suite struct MeetingMetadataTests {
    private func meeting(_ title: String, at t: Double, client: String? = nil, project: String? = nil, tags: [String] = []) -> Meeting {
        Meeting(title: title, client: client, project: project, tags: tags, date: Date(timeIntervalSince1970: t), state: .finished)
    }

    private func filled() async throws -> (MeetingStore, [Meeting], URL) {
        let root = tempRoot()
        let store = MeetingStore(root: root)
        let all = [
            meeting("Kickoff", at: 1, client: "Acme", project: "Website", tags: ["Planning", "design"]),
            meeting("Weekly", at: 2, client: "acme", project: "App", tags: ["planning"]),
            meeting("Budget", at: 3, client: "Globex", tags: ["finance"]),
            meeting("Lunch chat", at: 4),
        ]
        for m in all { try await store.create(m) }
        return (store, all, root)
    }

    @Test func metadataIsNormalizedAndSavedInMeetingJSON() async throws {
        let (store, all, root) = try await filled()
        defer { try? FileManager.default.removeItem(at: root) }
        let saved = try await store.updateMetadata(
            id: all[3].id, MeetingMetadata(title: "  Team lunch ", client: " Acme ", project: "  ", tags: ["a", " A ", "", "b"]))
        #expect(saved?.title == "Team lunch" && saved?.client == "Acme" && saved?.project == nil && saved?.tags == ["a", "b"])
        #expect(try await store.meeting(id: all[3].id) == saved)
        let raw = try JSONSerialization.jsonObject(with: Data(contentsOf: await store.folder(for: all[3].id).appendingPathComponent("meeting.json"))) as? [String: Any]
        #expect(raw?["title"] as? String == "Team lunch" && raw?["client"] as? String == "Acme" && raw?["tags"] as? [String] == ["a", "b"])
        #expect(raw?["project"] == nil, "no project: no key")
        _ = try await store.updateMetadata(id: all[3].id, MeetingMetadata(title: "   "))
        #expect(try await store.meeting(id: all[3].id)?.title == "Team lunch", "a blank title keeps the old one")
        #expect(try await store.updateMetadata(id: UUID(), MeetingMetadata(title: "x")) == nil)
    }

    @Test func filesWithoutMetadataStillDecode() async throws {
        let store = MeetingStore(root: tempRoot())
        let id = UUID()
        let folder = try await store.createFolder(for: id)
        let json = #"{"id": "\#(id.uuidString)", "title": "Old", "date": 1000, "duration": 60, "mutedRanges": [], "state": "finished"}"#
        try Data(json.utf8).write(to: folder.appendingPathComponent("meeting.json"))
        let m = try #require(try await store.meeting(id: id))
        #expect(m.client == nil && m.project == nil && m.tags.isEmpty && m.title == "Old")
    }

    @Test func knownClientsProjectsAndTagsAreDistinctAndSorted() async throws {
        let (store, _, root) = try await filled()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(try await store.knownClients() == ["acme", "Globex"], "one spelling per client: the newest meeting's")
        #expect(try await store.knownProjects() == ["App", "Website"])
        #expect(try await store.knownProjects(client: "ACME") == ["App", "Website"])
        #expect(try await store.knownProjects(client: "Globex").isEmpty)
        #expect(try await store.knownTags() == ["design", "finance", "planning"])
    }

    @Test func meetingsAreFilteredByClientProjectAndTagsIgnoringCase() async throws {
        let (store, _, root) = try await filled()
        defer { try? FileManager.default.removeItem(at: root) }
        func titles(_ f: MeetingStore.Filter) async throws -> [String] { try await store.meetings(matching: f).map(\.title) }
        #expect(try await titles(.init(client: "ACME")) == ["Weekly", "Kickoff"])
        #expect(try await titles(.init(client: "acme", project: "website")) == ["Kickoff"])
        #expect(try await titles(.init(tags: ["PLANNING"])) == ["Weekly", "Kickoff"])
        #expect(try await titles(.init(tags: ["planning", "design"])) == ["Kickoff"], "every tag must match")
        #expect(try await titles(.init()).count == 4)
        #expect(try await titles(.init(client: "Nobody")).isEmpty)
    }

    @Test func searchFindsTitlesAndEveryMetadataValue() async throws {
        let (store, _, root) = try await filled()
        defer { try? FileManager.default.removeItem(at: root) }
        func found(_ q: String) async throws -> [String] { try await store.meetings(matching: .init(query: q)).map(\.title) }
        #expect(try await found("kick") == ["Kickoff"])
        #expect(try await found("globex") == ["Budget"])
        #expect(try await found("website") == ["Kickoff"])
        #expect(try await found("FINANCE") == ["Budget"])
        #expect(try await found("acme planning") == ["Weekly", "Kickoff"], "every word, anywhere in title or metadata")
        #expect(try await found("acme finance").isEmpty)
        let m = meeting("Plain", at: 9, client: "Zed", project: "P", tags: ["t1"])
        #expect(MeetingListLogic.matches("zed t1", meeting: m, summaries: [], notes: nil, segments: []))
    }

    @Test func theSidebarGroupsClientThenProject() {
        let ms = [
            meeting("a", at: 1, client: "Acme", project: "Website"),
            meeting("b", at: 5, client: "acme", project: "website"),
            meeting("c", at: 3, client: "Acme"),
            meeting("d", at: 2, client: "Acme", project: "App"),
            meeting("e", at: 4, client: "Beta"),
            meeting("f", at: 6),
        ]
        let groups = MeetingListLogic.groupByClient(ms)
        #expect(groups.map(\.client) == ["Acme", "Beta", nil], "unfiled last")
        #expect(groups[0].projects.map(\.project) == [nil, "App", "Website"])
        #expect(groups[0].projects[2].meetings.map(\.title) == ["b", "a"], "newest first; case does not split a folder")
        #expect(groups[2].projects[0].meetings.map(\.title) == ["f"])
    }
}
