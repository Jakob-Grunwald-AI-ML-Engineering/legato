import Foundation

/// A Model Context Protocol server over stdio: newline-delimited JSON-RPC 2.0 with the read-only tools `list_meetings`,
/// `show_meeting` and `search_meetings`. Only JSON-RPC goes to stdout; diagnostics go to stderr.
public struct MCPServer: Sendable {
    /// Newest first; a client's version is echoed when it is one of these.
    static let protocolVersions = ["2025-06-18", "2025-03-26", "2024-11-05"]

    let reader: MeetingReader

    public init(reader: MeetingReader) { self.reader = reader }

    /// Answers one request per line until standard input ends.
    public func serve(_ console: Console) async {
        while let line = console.readLine() {
            guard !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            if let response = await handle(line) { console.out(response + "\n") }
        }
    }

    // MARK: JSON-RPC

    /// The response line for one incoming line; nil for a notification (and for a response from the client), which gets none.
    public func handle(_ line: String) async -> String? {
        guard let message = JSONValue.parse(line) else { return failure(id: .null, code: -32700, "Parse error: not valid JSON") }
        guard case .object = message else { return failure(id: .null, code: -32600, "Invalid request: expected a JSON object") }
        if message["method"] == nil, message["result"] != nil || message["error"] != nil { return nil }
        let id = message["id"]
        guard let method = message["method"]?.stringValue, id.map(Self.isValidID) ?? true else {
            return failure(id: .null, code: -32600, "Invalid request: needs a string \"method\" and a string or number \"id\"")
        }
        guard let id else { return nil }  // notifications/initialized, notifications/cancelled, …: nothing to answer
        let params = message["params"] ?? .null
        switch method {
        case "initialize": return initialize(id: id, params: params)
        case "ping": return success(id: id, [:])
        case "tools/list": return success(id: id, ["tools": .array(Tools.all.map(\.definition))])
        case "tools/call": return await call(id: id, params: params)
        default: return failure(id: id, code: -32601, "Method not found: \(method)")
        }
    }

    private static func isValidID(_ id: JSONValue) -> Bool {
        switch id {
        case .string, .number: true
        default: false
        }
    }

    private func initialize(id: JSONValue, params: JSONValue) -> String {
        guard let asked = params["protocolVersion"]?.stringValue else {
            return failure(id: id, code: -32602, "Invalid params: initialize needs a \"protocolVersion\"")
        }
        let version = Self.protocolVersions.contains(asked) ? asked : Self.protocolVersions[0]
        return success(id: id, [
            "protocolVersion": .string(version),
            "capabilities": ["tools": ["listChanged": false]],
            "serverInfo": ["name": "legato", "version": .string(LegatoCLI.version)],
            "instructions": .string(Tools.instructions),
        ])
    }

    private func call(id: JSONValue, params: JSONValue) async -> String {
        guard let name = params["name"]?.stringValue else {
            return failure(id: id, code: -32602, "Invalid params: tools/call needs a tool \"name\"")
        }
        guard let tool = Tools.all.first(where: { $0.name == name }) else {
            return failure(id: id, code: -32602, "Unknown tool: \(name). Available: \(Tools.all.map(\.name).joined(separator: ", "))")
        }
        let arguments = params["arguments"] ?? [:]
        guard case .object = arguments else { return failure(id: id, code: -32602, "Invalid params: \"arguments\" must be an object") }
        do {
            return success(id: id, result(text: try await tool.run(arguments, reader), isError: false))
        } catch let error as CommandFailure {
            return success(id: id, result(text: error.message, isError: true))
        } catch {
            return success(id: id, result(text: error.localizedDescription, isError: true))
        }
    }

    private func result(text: String, isError: Bool) -> JSONValue {
        ["content": [["type": "text", "text": .string(text)]], "isError": .bool(isError)]
    }

    private func success(id: JSONValue, _ result: JSONValue) -> String {
        JSONValue.object(["jsonrpc": "2.0", "id": id, "result": result]).text()
    }

    private func failure(id: JSONValue, code: Int, _ message: String) -> String {
        JSONValue.object(["jsonrpc": "2.0", "id": id, "error": ["code": .number(Double(code)), "message": .string(message)]]).text()
    }
}

/// The tools, with the descriptions and schemas an agent finds them by.
struct Tool: Sendable {
    var name: String
    var title: String
    var description: String
    var properties: [String: JSONValue]
    var required: [String] = []
    var run: @Sendable (JSONValue, MeetingReader) async throws -> String

    var definition: JSONValue {
        [
            "name": .string(name),
            "title": .string(title),
            "description": .string(description),
            "inputSchema": [
                "type": "object", "properties": .object(properties), "required": .array(required.map(JSONValue.string)),
                "additionalProperties": false,
            ],
            "annotations": ["readOnlyHint": true, "destructiveHint": false, "idempotentHint": true, "openWorldHint": false],
        ]
    }
}

enum Tools {
    static let instructions = """
        Read-only access to the user's recorded Legato meetings (dictated meeting notes with summary, the user's notes and a speaker-labelled transcript), stored on this Mac. \
        To answer a question about a meeting: search_meetings with a few distinctive words (and client/project filters when you know them), then show_meeting for the id of the best hit. \
        list_meetings gives the newest meetings with their dates when the question is about a time ("last week") rather than a topic.
        """

    private static let filters: [String: JSONValue] = [
        "client": ["type": "string", "description": "Only meetings filed under this client (ignores case and accents)."],
        "project": ["type": "string", "description": "Only meetings filed under this project (ignores case and accents)."],
        "tags": [
            "type": "array", "items": ["type": "string"],
            "description": "Only meetings that have every one of these tags (ignores case and accents).",
        ],
    ]

    static let all: [Tool] = [
        Tool(
            name: "list_meetings", title: "List meetings",
            description: """
                List the user's recorded meetings, newest first, optionally narrowed by client, project or tags. \
                Returns JSON {"meetings": [{id, title, date (ISO 8601, UTC), duration_seconds, client, project, tags, state}]}; \
                pass an id to show_meeting to read one. Use it to browse, or to pick meetings by date.
                """,
            properties: filters,
            run: { arguments, reader in
                Output.list(try await reader.list(try parseFilters(arguments))).text()
            }),
        Tool(
            name: "search_meetings", title: "Search meetings",
            description: """
                Find meetings by content. A meeting matches when every word of the query appears (ignoring case and accents) \
                in its title, client, project, tags, speaker names, summary, the user's notes or the transcript. \
                Returns JSON {"meetings": [...as list_meetings, each with "snippets": [{source, text, at_seconds}] showing where the words were found]}, newest first. \
                Use a few distinctive words rather than a sentence; client/project/tags narrow it further.
                """,
            properties: filters.merging(
                ["query": ["type": "string", "description": "Words to look for; all of them must appear in the meeting."]]) { $1 },
            required: ["query"],
            run: { arguments, reader in
                guard let query = text(arguments, "query") else { throw CommandFailure("query is required: the words to look for") }
                return Output.search(try await reader.search(query, try parseFilters(arguments))).text()
            }),
        Tool(
            name: "show_meeting", title: "Show a meeting",
            description: """
                Read one meeting in full: title, date, duration, client, project, tags, the summary, the user's notes and the transcript \
                with speaker names and timestamps. Identify it by the id from list_meetings or search_meetings (the full id or any unambiguous start of it). \
                Returns Markdown by default; format "json" returns structured fields (summary, notes, speakers, transcript segments).
                """,
            properties: [
                "id": ["type": "string", "description": "The meeting id, or the start of it that fits only one meeting."],
                "format": [
                    "type": "string", "enum": ["markdown", "json"], "default": "markdown",
                    "description": "markdown (default) reads best; json gives structured fields.",
                ],
            ],
            required: ["id"],
            run: { arguments, reader in
                guard let id = text(arguments, "id") else { throw CommandFailure("id is required: a meeting id from list_meetings or search_meetings") }
                let format = text(arguments, "format") ?? "markdown"
                guard format == "markdown" || format == "json" else { throw CommandFailure("format must be \"markdown\" or \"json\"") }
                let detail = try await reader.detail(id: id)
                return format == "json" ? Output.detail(detail).text() : Output.detailText(detail)
            }),
    ]

    /// A string argument; blank is as good as absent.
    private static func text(_ arguments: JSONValue, _ key: String) -> String? {
        guard let value = arguments[key]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }

    private static func parseFilters(_ arguments: JSONValue) throws -> MeetingFilters {
        for key in ["client", "project"] {
            if let value = arguments[key], value != .null, value.stringValue == nil { throw CommandFailure("\(key) must be a string") }
        }
        var tags: [String] = []
        switch arguments["tags"] {
        case nil, .some(.null): break
        case .some(.array(let items)):
            for item in items {
                guard let tag = item.stringValue else { throw CommandFailure("tags must be an array of strings") }
                if !tag.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { tags.append(tag.trimmingCharacters(in: .whitespacesAndNewlines)) }
            }
        default: throw CommandFailure("tags must be an array of strings")
        }
        return MeetingFilters(client: text(arguments, "client"), project: text(arguments, "project"), tags: tags)
    }
}
