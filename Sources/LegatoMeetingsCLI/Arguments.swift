import Foundation

/// What `--client`, `--project` and `--tag` narrow a list or search to. Client and project match on part of the name, ignoring case and accents; every tag must be on the meeting.
public struct MeetingFilters: Sendable, Equatable {
    public var client: String?
    public var project: String?
    public var tags: [String]

    public init(client: String? = nil, project: String? = nil, tags: [String] = []) {
        self.client = client
        self.project = project
        self.tags = tags
    }
}

/// What the command line asks for.
public enum Command: Sendable, Equatable {
    case help(String)
    case version
    case list(filters: MeetingFilters, json: Bool, root: String?)
    case show(id: String, json: Bool, root: String?)
    case search(words: String, filters: MeetingFilters, json: Bool, root: String?)
    case mcp(root: String?)
}

/// A command line that cannot be run: what is wrong, in words for the person who typed it.
public struct UsageError: Error, Equatable {
    public var message: String
    public init(_ message: String) { self.message = message }
}

/// Reads `legato`'s arguments (without the program name). Hand-rolled: `--name value` or `--name=value`, `--` ends the options.
public enum Arguments {
    private enum Flag: String { case json, client, project, tag, root }

    private struct Parsed {
        var positionals: [String] = []
        var json = false
        var client: String?
        var project: String?
        var tags: [String] = []
        var root: String?
        var wantsHelp = false

        var filters: MeetingFilters { MeetingFilters(client: client, project: project, tags: tags) }
    }

    public static func parse(_ arguments: [String]) throws -> Command {
        guard let first = arguments.first else { throw UsageError("missing command") }
        let rest = Array(arguments.dropFirst())
        switch first {
        case "-h", "--help", "help": return .help(Help.top)
        case "--version", "-V": return .version
        case "mcp":
            let p = try scan(rest, allowing: [.root])
            if p.wantsHelp { return .help(Help.mcp) }
            try noPositionals(p, "mcp")
            return .mcp(root: p.root)
        case "meetings": return try meetings(rest)
        default: throw UsageError("unknown command '\(first)'")
        }
    }

    private static func meetings(_ arguments: [String]) throws -> Command {
        guard let sub = arguments.first else { throw UsageError("missing meetings command (list, show or search)") }
        let rest = Array(arguments.dropFirst())
        switch sub {
        case "-h", "--help", "help": return .help(Help.meetings)
        case "list":
            let p = try scan(rest, allowing: [.json, .client, .project, .tag, .root])
            if p.wantsHelp { return .help(Help.list) }
            try noPositionals(p, "meetings list")
            return .list(filters: p.filters, json: p.json, root: p.root)
        case "show":
            let p = try scan(rest, allowing: [.json, .root])
            if p.wantsHelp { return .help(Help.show) }
            guard p.positionals.count == 1 else {
                throw UsageError(p.positionals.isEmpty ? "meetings show needs a meeting id" : "meetings show takes one meeting id, got \(p.positionals.count)")
            }
            return .show(id: p.positionals[0], json: p.json, root: p.root)
        case "search":
            let p = try scan(rest, allowing: [.json, .client, .project, .tag, .root])
            if p.wantsHelp { return .help(Help.search) }
            let words = p.positionals.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !words.isEmpty else { throw UsageError("meetings search needs at least one word to look for") }
            return .search(words: words, filters: p.filters, json: p.json, root: p.root)
        default: throw UsageError("unknown meetings command '\(sub)' (list, show or search)")
        }
    }

    private static func noPositionals(_ p: Parsed, _ command: String) throws {
        if let extra = p.positionals.first { throw UsageError("\(command) takes no argument, got '\(extra)'") }
    }

    private static func scan(_ arguments: [String], allowing allowed: Set<Flag>) throws -> Parsed {
        var p = Parsed()
        var i = 0
        var optionsEnded = false
        while i < arguments.count {
            let argument = arguments[i]
            i += 1
            if optionsEnded || !argument.hasPrefix("-") || argument == "-" {
                p.positionals.append(argument)
                continue
            }
            if argument == "--" { optionsEnded = true; continue }
            if argument == "-h" || argument == "--help" { p.wantsHelp = true; continue }
            guard argument.hasPrefix("--") else { throw UsageError("unknown option '\(argument)'") }
            let body = argument.dropFirst(2)
            let name = String(body.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)[0])
            guard let flag = Flag(rawValue: name), allowed.contains(flag) else { throw UsageError("unknown option '--\(name)'") }
            if flag == .json {
                guard !body.contains("=") else { throw UsageError("--json takes no value") }
                p.json = true
                continue
            }
            var value: String
            if let eq = body.firstIndex(of: "=") {
                value = String(body[body.index(after: eq)...])
            } else {
                guard i < arguments.count, !arguments[i].hasPrefix("--") else { throw UsageError("--\(name) needs a value") }
                value = arguments[i]
                i += 1
            }
            value = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { throw UsageError("--\(name) needs a value") }
            switch flag {
            case .client: p.client = value
            case .project: p.project = value
            case .tag: p.tags.append(value)
            case .root: p.root = value
            case .json: break
            }
        }
        return p
    }
}

/// The usage text.
public enum Help {
    public static let top = """
        legato \(LegatoCLI.version): read your Legato meetings from the command line.

        Usage:
          legato meetings list    [filters] [--json]   List meetings, newest first.
          legato meetings show <id> [--json]           Show one meeting: summary, notes, transcript.
          legato meetings search <words> [filters] [--json]
                                                       Find meetings whose title, filing, summary, notes or transcript contain every word.
          legato mcp                                   Serve the same as an MCP server on stdin/stdout.

        Everything is read-only; nothing in the meetings folder is ever written.
        Run 'legato meetings --help' or 'legato mcp --help' for details.
        """

    public static let meetings = """
        Usage: legato meetings <list|show|search> [options]

          list                 List meetings, newest first.
          show <id>            One meeting in full. <id> is the id from 'list', or any unambiguous start of it.
          search <words>       Meetings that contain every word (ignoring case and accents) in the title, client,
                               project, tags, speaker names, summaries, notes or transcript.

        Filters (list and search; repeatable --tag; every tag must be on the meeting):
          --client <name>      Only meetings whose client contains this.
          --project <name>     Only meetings whose project contains this.
          --tag <tag>          Only meetings with this tag.

        Options:
          --json               Print JSON instead of Markdown/plain text.
          --root <dir>         The meetings folder. Default: \(LegatoCLI.defaultRootDescription)
          -h, --help           Show this help.
        """

    public static let list = """
        Usage: legato meetings list [--client <name>] [--project <name>] [--tag <tag>]... [--json] [--root <dir>]

        Lists meetings, newest first: id, date, duration, title and filing. A missing meetings folder lists nothing.
        With --json: {"meetings": [{"id", "title", "date" (ISO 8601, UTC), "duration_seconds", "client", "project", "tags", "state"}]}.
        """

    public static let show = """
        Usage: legato meetings show <id> [--json] [--root <dir>]

        Prints the meeting as Markdown: title, date, duration, filing, summary, your notes, then the transcript.
        <id> is the full id or any start of it that fits only one meeting.
        With --json: the metadata plus "summary", "notes", "speakers" and "transcript" (one entry per spoken segment).
        """

    public static let search = """
        Usage: legato meetings search <words>... [--client <name>] [--project <name>] [--tag <tag>]... [--json] [--root <dir>]

        Lists the meetings that contain every word, with a short excerpt of where it was found.
        With --json: {"meetings": [...as in list, plus "snippets": [{"source", "text", "at_seconds"}]]}.
        """

    public static let mcp = """
        Usage: legato mcp [--root <dir>]

        Runs a Model Context Protocol server on stdin/stdout (newline-delimited JSON-RPC 2.0) with the read-only tools
        list_meetings, show_meeting and search_meetings. Diagnostics go to stderr. It exits when stdin closes.

        Add it to an MCP client, for example:
          {"mcpServers": {"legato": {"command": "legato", "args": ["mcp"]}}}
        """
}
