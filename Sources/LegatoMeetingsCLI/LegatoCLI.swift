import Foundation

/// Where a command reads and writes. Text is written as given (it carries its own newline).
public struct Console: Sendable {
    public var out: @Sendable (String) -> Void
    public var err: @Sendable (String) -> Void
    /// The next line of standard input, nil at its end.
    public var readLine: @Sendable () -> String?

    public init(
        out: @escaping @Sendable (String) -> Void, err: @escaping @Sendable (String) -> Void, readLine: @escaping @Sendable () -> String?
    ) {
        self.out = out
        self.err = err
        self.readLine = readLine
    }

    /// The process's standard streams. Writes go straight to the file, so nothing waits in a buffer.
    public static let standard = Console(
        out: { try? FileHandle.standardOutput.write(contentsOf: Data($0.utf8)) },
        err: { try? FileHandle.standardError.write(contentsOf: Data($0.utf8)) },
        readLine: { Swift.readLine(strippingNewline: true) })
}

/// `legato`: read-only access to the meetings the Mac app records. All logic lives here; the executable only calls ``run(_:console:)``.
public enum LegatoCLI {
    public static let version = "0.1"
    public static let defaultRootDescription = "~/Library/Application Support/Legato/Meetings"

    public static func defaultRoot() -> URL {
        URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent("Library/Application Support/Legato/Meetings", isDirectory: true)
    }

    /// Runs one command line (without the program name) and returns the exit status: 0 done, 1 could not answer, 2 bad usage.
    public static func run(_ arguments: [String], console: Console) async -> Int32 {
        do {
            switch try Arguments.parse(arguments) {
            case .help(let text):
                console.out(text + "\n")
            case .version:
                console.out("legato \(version)\n")
            case .list(let filters, let json, let root):
                let meetings = try await reader(root).list(filters)
                console.out(json ? Output.list(meetings).text(pretty: true) + "\n" : Output.listText(meetings))
            case .search(let words, let filters, let json, let root):
                let hits = try await reader(root).search(words, filters)
                console.out(json ? Output.search(hits).text(pretty: true) + "\n" : Output.searchText(hits))
            case .show(let id, let json, let root):
                let detail = try await reader(root).detail(id: id)
                console.out(json ? Output.detail(detail).text(pretty: true) + "\n" : Output.detailText(detail))
            case .mcp(let root):
                let reader = reader(root)
                console.err("legato mcp: serving \(reader.root.path)\n")
                await MCPServer(reader: reader).serve(console)
                console.err("legato mcp: stdin closed, exiting\n")
            }
            return 0
        } catch let error as UsageError {
            console.err("legato: \(error.message)\nRun 'legato --help' for usage.\n")
            return 2
        } catch let error as CommandFailure {
            console.err("legato: \(error.message)\n")
            return 1
        } catch {
            console.err("legato: \(error.localizedDescription)\n")
            return 1
        }
    }

    private static func reader(_ root: String?) -> MeetingReader {
        guard let root else { return MeetingReader(root: defaultRoot()) }
        return MeetingReader(root: URL(fileURLWithPath: NSString(string: root).expandingTildeInPath, isDirectory: true))
    }
}
