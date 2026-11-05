import Testing
@testable import LegatoMeetingsCLI

@Suite struct ArgumentsTests {
    @Test func listTakesFiltersAndJSON() throws {
        let command = try Arguments.parse(["meetings", "list", "--client", "Acme", "--project=Website", "--tag", "a", "--tag", "b", "--json", "--root", "/x"])
        #expect(command == .list(filters: MeetingFilters(client: "Acme", project: "Website", tags: ["a", "b"]), json: true, root: "/x"))
    }

    @Test func showTakesOneID() throws {
        #expect(try Arguments.parse(["meetings", "show", "ab12", "--json"]) == .show(id: "ab12", json: true, root: nil))
        #expect(throws: UsageError.self) { try Arguments.parse(["meetings", "show"]) }
        #expect(throws: UsageError.self) { try Arguments.parse(["meetings", "show", "a", "b"]) }
        #expect(throws: UsageError.self) { try Arguments.parse(["meetings", "show", "a", "--client", "x"]) }
    }

    @Test func searchJoinsWords() throws {
        let command = try Arguments.parse(["meetings", "search", "launch", "date", "--tag", "x"])
        #expect(command == .search(words: "launch date", filters: MeetingFilters(tags: ["x"]), json: false, root: nil))
        #expect(throws: UsageError.self) { try Arguments.parse(["meetings", "search"]) }
        #expect(try Arguments.parse(["meetings", "search", "--", "--json"]) == .search(words: "--json", filters: MeetingFilters(), json: false, root: nil))
    }

    @Test func mcpTakesARoot() throws {
        #expect(try Arguments.parse(["mcp", "--root", "/r"]) == .mcp(root: "/r"))
        #expect(throws: UsageError.self) { try Arguments.parse(["mcp", "--json"]) }
    }

    @Test func helpAndVersion() throws {
        #expect(try Arguments.parse(["--help"]) == .help(Help.top))
        #expect(try Arguments.parse(["meetings", "show", "--help"]) == .help(Help.show))
        #expect(try Arguments.parse(["--version"]) == .version)
    }

    @Test func badInputSaysWhat() {
        func message(_ arguments: [String]) -> String? {
            do { _ = try Arguments.parse(arguments); return nil } catch let e as UsageError { return e.message } catch { return "other" }
        }
        #expect(message([]) == "missing command")
        #expect(message(["nope"]) == "unknown command 'nope'")
        #expect(message(["meetings"])?.contains("missing meetings command") == true)
        #expect(message(["meetings", "list", "--bogus"]) == "unknown option '--bogus'")
        #expect(message(["meetings", "list", "-x"]) == "unknown option '-x'")
        #expect(message(["meetings", "list", "--client"]) == "--client needs a value")
        #expect(message(["meetings", "list", "--client", "--json"]) == "--client needs a value")
        #expect(message(["meetings", "list", "--json=1"]) == "--json takes no value")
        #expect(message(["meetings", "list", "extra"])?.contains("takes no argument") == true)
    }
}
