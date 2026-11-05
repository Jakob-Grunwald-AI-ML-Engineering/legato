import Foundation
import Testing
@testable import LegatoMeetingsCLI

@Suite struct CommandTests {
    @Test func listJSONShape() async throws {
        let f = try await Fixture.make()
        defer { f.remove() }
        let result = await run(["meetings", "list", "--json", "--root", f.root.path])
        #expect(result.status == 0 && result.stderr.isEmpty)
        let json = try #require(JSONValue.parse(result.stdout))
        guard case .array(let meetings)? = json["meetings"] else { Issue.record("no meetings array"); return }
        #expect(meetings.compactMap { $0["title"]?.stringValue } == ["Lunch chat", "Weekly", "Kickoff"], "newest first")
        let kickoff = try #require(meetings.last)
        guard case .object(let fields) = kickoff else { Issue.record("not an object"); return }
        #expect(Set(fields.keys) == ["id", "title", "date", "duration_seconds", "client", "project", "tags", "state"])
        #expect(kickoff["id"] == "AAAA1111-0000-0000-0000-000000000001")
        #expect(kickoff["date"] == "2023-11-14T22:13:20Z")
        #expect(kickoff["duration_seconds"] == 125)
        #expect(kickoff["tags"] == ["Planning", "design"])
        #expect(meetings[0]["client"] == .null, "no client is null, not a missing key")
    }

    @Test func listFilters() async throws {
        let f = try await Fixture.make()
        defer { f.remove() }
        func titles(_ extra: [String]) async -> String {
            let result = await run(["meetings", "list", "--json", "--root", f.root.path] + extra)
            guard case .array(let meetings)? = JSONValue.parse(result.stdout)?["meetings"] else { return "?" }
            return meetings.compactMap { $0["title"]?.stringValue }.joined(separator: ",")
        }
        #expect(await titles(["--client", "ACME"]) == "Weekly,Kickoff", "ignores case")
        #expect(await titles(["--client", "acme", "--project", "website"]) == "Kickoff")
        #expect(await titles(["--client", "acm", "--project", "web"]) == "Kickoff", "part of the name")
        #expect(await titles(["--tag", "planning", "--tag", "DESIGN"]) == "Kickoff", "every tag")
        #expect(await titles(["--client", "nobody"]) == "")
    }

    @Test func listText() async throws {
        let f = try await Fixture.make()
        defer { f.remove() }
        let result = await run(["meetings", "list", "--root", f.root.path])
        #expect(result.stdout.contains("AAAA1111  ") && result.stdout.contains("Kickoff  [Acme / Website]  #Planning #design"))
        #expect(result.stdout.contains("  2:05  "))
    }

    @Test func missingRootIsEmptyAndNotCreated() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("legato-cli-missing-\(UUID().uuidString)")
        for arguments in [["meetings", "list"], ["meetings", "search", "x"], ["meetings", "list", "--json"]] {
            let result = await run(arguments + ["--root", root.path])
            #expect(result.status == 0 && result.stderr.isEmpty)
        }
        #expect((await run(["meetings", "list", "--json", "--root", root.path])).stdout.contains("\"meetings\" : [\n\n  ]"))
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }

    @Test func searchFindsEverySourceIncludingNotes() async throws {
        let f = try await Fixture.make()
        defer { f.remove() }
        func titles(_ words: String, _ extra: [String] = []) async -> [String] {
            let result = await run(["meetings", "search", "--json", "--root", f.root.path] + extra + words.split(separator: " ").map(String.init))
            guard case .array(let meetings)? = JSONValue.parse(result.stdout)?["meetings"] else { return ["?"] }
            return meetings.compactMap { $0["title"]?.stringValue }
        }
        #expect(await titles("zurich") == ["Kickoff"], "transcript, ignoring accents")
        #expect(await titles("march launch") == ["Kickoff"], "summary, every word")
        #expect(await titles("INVOICE") == ["Weekly"], "notes")
        #expect(await titles("alice") == ["Kickoff"], "speaker name")
        #expect(await titles("pasta") == ["Lunch chat"])
        #expect(await titles("lunch") == ["Lunch chat"], "title")
        #expect(await titles("invoice march") == [], "all words in one meeting")
        #expect(await titles("planning", ["--client", "acme", "--project", "app"]) == ["Weekly"], "filters narrow the search")
    }

    @Test func searchSaysWhereItFound() async throws {
        let f = try await Fixture.make()
        defer { f.remove() }
        let json = try #require(JSONValue.parse((await run(["meetings", "search", "invoice", "--json", "--root", f.root.path])).stdout))
        guard case .array(let meetings)? = json["meetings"], case .array(let snippets)? = meetings.first?["snippets"] else {
            Issue.record("no snippets"); return
        }
        #expect(snippets.first?["source"] == "notes")
        #expect(snippets.first?["text"]?.stringValue?.contains("invoice deadline") == true)
        let text = (await run(["meetings", "search", "zurich", "--root", f.root.path])).stdout
        #expect(text.contains("transcript 0:03: We agreed on the Zürich launch date."))
    }

    @Test func showByPrefixInMarkdown() async throws {
        let f = try await Fixture.make()
        defer { f.remove() }
        let result = await run(["meetings", "show", "aaaa1111", "--root", f.root.path])
        #expect(result.status == 0)
        #expect(result.stdout.hasPrefix("# Kickoff\n"))
        for part in ["- ID: AAAA1111-0000-0000-0000-000000000001", "- Client: Acme", "- Project: Website", "- Tags: Planning, design", "Launch is set for March.", "## Transcript", "**Alice** [00:03] We agreed on the Zürich launch date."] {
            #expect(result.stdout.components(separatedBy: part).count == 2, "\(part) should appear once")
        }
        let withDashes = await run(["meetings", "show", "aaaa1111-0000", "--root", f.root.path])
        #expect(withDashes.stdout == result.stdout)
        let notes = await run(["meetings", "show", "AAAA2", "--root", f.root.path])
        #expect(notes.stdout.contains("## Notes\n\nRemember the invoice deadline."))
    }

    @Test func showJSONShape() async throws {
        let f = try await Fixture.make()
        defer { f.remove() }
        let json = try #require(JSONValue.parse((await run(["meetings", "show", "AAAA1", "--json", "--root", f.root.path])).stdout))
        guard case .object(let fields) = json else { Issue.record("not an object"); return }
        #expect(Set(fields.keys) == ["id", "title", "date", "duration_seconds", "client", "project", "tags", "state", "locale", "folder", "summary_failure", "speakers", "summary", "notes", "transcript"])
        #expect(json["locale"] == "en-US")
        #expect(json["notes"] == .null)
        #expect(json["summary"]?["text"] == "## Summary\n\nLaunch is set for March.")
        #expect(json["summary"]?["backend"] == "claude")
        #expect(json["speakers"] == [["id": "P1", "name": "Alice"]])
        guard case .array(let transcript)? = json["transcript"] else { Issue.record("no transcript"); return }
        #expect(transcript.count == 2)
        #expect(transcript[0] == ["start_seconds": 3, "end_seconds": 9, "speaker_id": "P1", "speaker": "Alice", "text": "We agreed on the Zürich launch date."])
    }

    @Test func badInputFailsOnStderr() async throws {
        let f = try await Fixture.make()
        defer { f.remove() }
        let unknown = await run(["meetings", "show", "ffff", "--root", f.root.path])
        #expect(unknown.status == 1 && unknown.stdout.isEmpty && unknown.stderr.contains("no meeting with id 'ffff'"))
        let ambiguous = await run(["meetings", "show", "AAAA", "--root", f.root.path])
        #expect(ambiguous.status == 1 && ambiguous.stderr.contains("fits 2 meetings"))
        let notAnID = await run(["meetings", "show", "kickoff", "--root", f.root.path])
        #expect(notAnID.status == 1 && notAnID.stderr.contains("is not a meeting id"))
        let usage = await run(["meetings", "list", "--bogus"])
        #expect(usage.status == 2 && usage.stdout.isEmpty && usage.stderr.contains("unknown option '--bogus'") && usage.stderr.contains("--help"))
        let help = await run(["--help"])
        #expect(help.status == 0 && help.stdout.contains("legato meetings search"))
    }

    @Test func rootThatIsAFileFailsClearly() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("legato-cli-file-\(UUID().uuidString)")
        try Data("x".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let result = await run(["meetings", "list", "--root", file.path])
        #expect(result.status == 1 && result.stderr.contains("cannot read the meetings folder"))
    }

    @Test func everyCommandLeavesTheFolderByteIdentical() async throws {
        let f = try await Fixture.make()
        defer { f.remove() }
        // A recording in progress: the last line of the transcript is half written.
        let segments = f.root.appendingPathComponent(f.kickoff.id.uuidString).appendingPathComponent("segments.jsonl")
        let handle = try FileHandle(forWritingTo: segments)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{\"id\":\"half".utf8))
        try handle.close()
        let before = try f.snapshot()
        let mcp = [
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}"#,
            #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"list_meetings","arguments":{}}}"#,
            #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"search_meetings","arguments":{"query":"zurich"}}}"#,
            #"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"show_meeting","arguments":{"id":"AAAA1"}}}"#,
        ]
        let commands: [([String], [String])] = [
            (["meetings", "list"], []), (["meetings", "list", "--json", "--client", "acme"], []),
            (["meetings", "search", "zurich"], []), (["meetings", "search", "invoice", "--json"], []),
            (["meetings", "show", "AAAA1"], []), (["meetings", "show", "AAAA2", "--json"], []), (["meetings", "show", "BBBB"], []),
            (["mcp"], mcp),
        ]
        for (arguments, input) in commands {
            let result = await run(arguments + ["--root", f.root.path], input: input)
            #expect(result.status == 0, "\(arguments): \(result.stderr)")
        }
        #expect(try f.snapshot() == before)
        let shown = await run(["meetings", "show", "AAAA1", "--root", f.root.path])
        #expect(shown.stdout.contains("Budget is fixed."), "the half written line is skipped, the rest is read")
    }
}
