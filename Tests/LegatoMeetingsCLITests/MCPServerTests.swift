import Foundation
import Testing
@testable import LegatoMeetingsCLI

@Suite struct MCPServerTests {
    private func send(_ server: MCPServer, _ line: String) async throws -> JSONValue {
        let reply = try #require(await server.handle(line))
        return try #require(JSONValue.parse(reply))
    }

    @Test func initializeEchoesASupportedVersionAndDeclaresTools() async throws {
        let f = try await Fixture.make()
        defer { f.remove() }
        let server = MCPServer(reader: MeetingReader(root: f.root))
        let reply = try await send(server, #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"t","version":"1"}}}"#)
        #expect(reply["id"] == 1 && reply["jsonrpc"] == "2.0")
        #expect(reply["result"]?["protocolVersion"] == "2024-11-05")
        #expect(reply["result"]?["capabilities"]?["tools"] != nil)
        #expect(reply["result"]?["serverInfo"]?["name"] == "legato")
        let newer = try await send(server, #"{"jsonrpc":"2.0","id":"x","method":"initialize","params":{"protocolVersion":"2099-01-01"}}"#)
        #expect(newer["id"] == "x" && newer["result"]?["protocolVersion"] == "2025-06-18", "an unknown version gets the newest supported")
        let bad = try await send(server, #"{"jsonrpc":"2.0","id":2,"method":"initialize","params":{}}"#)
        #expect(bad["error"]?["code"] == -32602)
    }

    @Test func notificationsAndPingsAndUnknownMethods() async throws {
        let f = try await Fixture.make()
        defer { f.remove() }
        let server = MCPServer(reader: MeetingReader(root: f.root))
        #expect(await server.handle(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#) == nil)
        #expect(await server.handle(#"{"jsonrpc":"2.0","id":9,"result":{}}"#) == nil, "a response from the client gets none")
        #expect(try await send(server, #"{"jsonrpc":"2.0","id":3,"method":"ping"}"#)["result"] == [:])
        let unknown = try await send(server, #"{"jsonrpc":"2.0","id":4,"method":"resources/list"}"#)
        #expect(unknown["error"]?["code"] == -32601 && unknown["id"] == 4)
        let garbage = try await send(server, "not json")
        #expect(garbage["error"]?["code"] == -32700 && garbage["id"] == .null)
        let invalid = try await send(server, #"{"jsonrpc":"2.0","id":5}"#)
        #expect(invalid["error"]?["code"] == -32600)
    }

    @Test func toolsListNamesTheThreeReadOnlyTools() async throws {
        let f = try await Fixture.make()
        defer { f.remove() }
        let reply = try await send(MCPServer(reader: MeetingReader(root: f.root)), #"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#)
        guard case .array(let tools)? = reply["result"]?["tools"] else { Issue.record("no tools"); return }
        #expect(tools.compactMap { $0["name"]?.stringValue } == ["list_meetings", "search_meetings", "show_meeting"])
        for tool in tools {
            #expect(tool["description"]?.stringValue?.isEmpty == false)
            #expect(tool["inputSchema"]?["type"] == "object")
            #expect(tool["annotations"]?["readOnlyHint"] == true)
        }
        #expect(tools[1]["inputSchema"]?["required"] == ["query"])
        #expect(tools[2]["inputSchema"]?["required"] == ["id"])
    }

    @Test func toolCallsReturnTheCommandLinesResults() async throws {
        let f = try await Fixture.make()
        defer { f.remove() }
        let server = MCPServer(reader: MeetingReader(root: f.root))
        func call(_ name: String, _ arguments: String) async throws -> (text: String, isError: Bool) {
            let reply = try await send(server, #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"\#(name)","arguments":\#(arguments)}}"#)
            let result = try #require(reply["result"])
            guard case .array(let content)? = result["content"] else { throw CommandFailure("no content") }
            return (content.first?["text"]?.stringValue ?? "", result["isError"] == true)
        }
        let list = try await call("list_meetings", #"{"client":"acme","tags":["planning"]}"#)
        #expect(!list.isError)
        #expect(JSONValue.parse(list.text) == Output.list(try await MeetingReader(root: f.root).list(MeetingFilters(client: "acme", tags: ["planning"]))))
        let search = try await call("search_meetings", #"{"query":"invoice","client":""}"#)
        #expect(!search.isError)
        guard case .array(let hits)? = JSONValue.parse(search.text)?["meetings"] else { Issue.record("no hits"); return }
        #expect(hits.compactMap { $0["title"]?.stringValue } == ["Weekly"], "notes are searched; a blank filter is no filter")
        let markdown = try await call("show_meeting", #"{"id":"AAAA1"}"#)
        #expect(!markdown.isError && markdown.text.hasPrefix("# Kickoff"))
        let json = try await call("show_meeting", #"{"id":"AAAA1","format":"json"}"#)
        #expect(JSONValue.parse(json.text)?["title"] == "Kickoff")
    }

    @Test func toolFailuresAreResultsAndUnknownToolsAreProtocolErrors() async throws {
        let f = try await Fixture.make()
        defer { f.remove() }
        let server = MCPServer(reader: MeetingReader(root: f.root))
        func failure(_ params: String) async throws -> JSONValue {
            try await send(server, #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":\#(params)}"#)
        }
        for params in [
            #"{"name":"show_meeting","arguments":{"id":"ffff"}}"#, #"{"name":"show_meeting","arguments":{}}"#,
            #"{"name":"search_meetings","arguments":{}}"#, #"{"name":"list_meetings","arguments":{"tags":"x"}}"#,
            #"{"name":"show_meeting","arguments":{"id":"AAAA1","format":"xml"}}"#,
        ] {
            let reply = try await failure(params)
            #expect(reply["error"] == nil && reply["result"]?["isError"] == true, "\(params)")
            guard case .array(let content)? = reply["result"]?["content"] else { Issue.record("no content"); continue }
            #expect(content.first?["text"]?.stringValue?.isEmpty == false)
        }
        let unknown = try await failure(#"{"name":"delete_meeting","arguments":{}}"#)
        #expect(unknown["error"]?["code"] == -32602 && unknown["result"] == nil)
        #expect(try await failure(#"{"arguments":{}}"#)["error"]?["code"] == -32602)
        #expect(try await failure(#"{"name":"list_meetings","arguments":[]}"#)["error"]?["code"] == -32602)
    }

    @Test func serveAnswersEachLineUntilInputEnds() async throws {
        let f = try await Fixture.make()
        defer { f.remove() }
        let result = await run(["mcp", "--root", f.root.path], input: [
            #"{"jsonrpc":"2.0","id":1,"method":"ping"}"#, "", #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#,
            #"{"jsonrpc":"2.0","id":2,"method":"ping"}"#,
        ])
        #expect(result.status == 0)
        let lines = result.stdout.split(separator: "\n").map(String.init)
        #expect(lines.count == 2 && lines.allSatisfy { JSONValue.parse($0) != nil }, "stdout carries JSON-RPC only")
        #expect(result.stderr.contains("serving"), "diagnostics go to stderr")
    }
}
