import Foundation

/// Platform-independent file inbox and JSONL event store. All access is serialized by the main actor.
@MainActor public final class InboxTransport {
    public let root: URL
    public var inbox: URL { root.appendingPathComponent("inbox", isDirectory: true) }
    public var logURL: URL { root.appendingPathComponent("log.jsonl") }
    private var badFiles: [String: Int] = [:]

    public init(root: URL) { self.root = root }

    /// A new process generation deliberately drops stale requests before advertising readiness.
    public func prepare(keepLines: Int = 1000) -> Int {
        let fm = FileManager.default
        try? fm.createDirectory(at: inbox, withIntermediateDirectories: true)
        let stale = (try? fm.contentsOfDirectory(at: inbox, includingPropertiesForKeys: nil)) ?? []
        for file in stale { try? fm.removeItem(at: file) }
        badFiles = [:]
        if let text = try? String(contentsOf: logURL, encoding: .utf8) {
            let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
            if lines.count > keepLines * 2 {
                try? (lines.suffix(keepLines).joined(separator: "\n") + "\n").write(to: logURL, atomically: true, encoding: .utf8)
            }
        }
        return stale.count
    }

    /// Copies may still be arriving: tolerate two undecodable polls before removing a bad request.
    public func takeCommands() -> [BridgeCommand] {
        let fm = FileManager.default
        let files = ((try? fm.contentsOfDirectory(at: inbox, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        let names = Set(files.map(\.lastPathComponent))
        badFiles = badFiles.filter { names.contains($0.key) }
        var commands: [BridgeCommand] = []
        for file in files {
            guard let data = try? Data(contentsOf: file), let command = BridgeCommand.decode(data) else {
                let attempts = (badFiles[file.lastPathComponent] ?? 0) + 1
                badFiles[file.lastPathComponent] = attempts
                if attempts >= 3 {
                    emit(id: file.deletingPathExtension().lastPathComponent, event: "error", ["message": "undecodable command file"])
                    try? fm.removeItem(at: file)
                    badFiles[file.lastPathComponent] = nil
                }
                continue
            }
            try? fm.removeItem(at: file)
            badFiles[file.lastPathComponent] = nil
            commands.append(command)
        }
        return commands
    }

    public func emit(id: String, event: String, _ fields: [String: Any] = [:]) {
        var line = fields
        line["ts"] = Date().formatted(.iso8601.year().month().day().dateSeparator(.dash).time(includingFractionalSeconds: true).timeZone(separator: .omitted))
        line["id"] = id
        line["event"] = event
        guard JSONSerialization.isValidJSONObject(line),
              var data = try? JSONSerialization.data(withJSONObject: line, options: [.sortedKeys]) else { return }
        data.append(0x0A)
        let fm = FileManager.default
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
        if !fm.fileExists(atPath: logURL.path) { _ = fm.createFile(atPath: logURL.path, contents: nil) }
        guard let handle = try? FileHandle(forWritingTo: logURL) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
    }
}
