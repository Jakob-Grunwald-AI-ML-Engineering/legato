import Foundation

/// An append-only file of one JSON object per line, the format behind dictation history and meeting segments.
///
/// Conventions: dates are written as milliseconds since 1970; a partial last line left by a crashed
/// writer is closed off before the next append; lines that do not decode are skipped on read and kept
/// on ``remove(where:)``; rewrites are atomic. Single writer (the app); extensions only read.
///
/// Share exactly one instance per file: the actor serializes access only within an instance, so a
/// second instance (or process) writing the same file can interleave appends with a rewrite and lose
/// entries. There is no file locking.
public actor JSONLFile<Element: Codable & Sendable> {
    public let fileURL: URL
    private let ownerOnly: Bool

    /// - Parameter ownerOnly: make the file private (``PrivateFiles``) whenever this instance creates or
    ///   rewrites it. Off by default, which leaves dictation history's files as they were.
    public init(fileURL: URL, ownerOnly: Bool = false) {
        self.fileURL = fileURL
        self.ownerOnly = ownerOnly
    }

    private static var newline: UInt8 { UInt8(ascii: "\n") }

    private static func makeEncoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .millisecondsSince1970
        return e
    }

    private static func makeDecoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .millisecondsSince1970
        return d
    }

    public func append(_ element: Element) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fm.fileExists(atPath: fileURL.path) {
            guard fm.createFile(atPath: fileURL.path, contents: nil) else {
                throw CocoaError(.fileWriteUnknown)
            }
            if ownerOnly { PrivateFiles.protect(fileAt: fileURL) }
        }
        var line = try Self.makeEncoder().encode(element)
        line.append(Self.newline)

        let handle = try FileHandle(forUpdating: fileURL)
        defer { try? handle.close() }
        let end = try handle.seekToEnd()
        if end > 0 {
            // A crashed writer may have left a partial line; start ours on a fresh line.
            try handle.seek(toOffset: end - 1)
            if try handle.read(upToCount: 1)?.first != Self.newline {
                try handle.seekToEnd()
                try handle.write(contentsOf: Data([Self.newline]))
            }
        }
        try handle.seekToEnd()
        try handle.write(contentsOf: line)
    }

    /// Every line that decodes, in file order; corrupt lines are skipped.
    public func elements() throws -> [Element] {
        let decoder = Self.makeDecoder()
        return try rawLines().compactMap { try? decoder.decode(Element.self, from: $0) }
    }

    /// Drops the elements matching `shouldRemove`. Corrupt lines are preserved: this never destroys
    /// data it cannot read. The file is untouched when nothing matches.
    public func remove(where shouldRemove: (Element) -> Bool) throws {
        let decoder = Self.makeDecoder()
        let lines = try rawLines()
        let kept = lines.filter { line in
            guard let element = try? decoder.decode(Element.self, from: line) else { return true }
            return !shouldRemove(element)
        }
        guard kept.count != lines.count else { return }
        try write(lines: kept)
    }

    /// Replace matching records in one atomic rewrite, preserving unrelated and corrupt lines.
    public func upsert(_ element: Element, matching matches: (Element) -> Bool) throws {
        let decoder = Self.makeDecoder()
        var lines = try rawLines().filter { line in
            guard let decoded = try? decoder.decode(Element.self, from: line) else { return true }
            return !matches(decoded)
        }
        lines.append(try Self.makeEncoder().encode(element))
        try write(lines: lines)
    }

    /// Atomically replaces the file's contents with `elements` (corrupt lines are dropped).
    public func replaceAll(_ elements: [Element]) throws {
        let encoder = Self.makeEncoder()
        try write(lines: try elements.map { try encoder.encode($0) })
    }

    private func write(lines: [Data]) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        var out = Data()
        for line in lines {
            out.append(line)
            out.append(Self.newline)
        }
        try out.write(to: fileURL, options: .atomic)
        if ownerOnly { PrivateFiles.protect(fileAt: fileURL) }
    }

    private func rawLines() throws -> [Data] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        let data = try Data(contentsOf: fileURL)
        return data.split(separator: Self.newline, omittingEmptySubsequences: true).map { Data($0) }
    }
}
