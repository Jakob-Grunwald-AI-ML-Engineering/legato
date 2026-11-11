import Foundation
import LegatoMac

/// Writes the field queue's edit journal (`MacEditJournal`) to `~/Library/Caches/<bundle id>/edit-journal.jsonl`, full
/// text included, starting over past `MacEditJournal.rotateBytes` and keeping the previous file. Debug and internal
/// builds only: a release build writes nothing.
@MainActor
final class EditJournalFile {
    #if DEBUG || LEGATO_INTERNAL
    private var handle: FileHandle?
    private var url: URL?
    private var bytes = 0
    private var failed = false
    #endif

    func write(_ entry: MacEditJournal.Entry) {
        #if DEBUG || LEGATO_INTERNAL
        guard let handle = openIfNeeded() else { return }
        let data = MacEditJournal.line(entry)
        do { try handle.write(contentsOf: data) } catch { failed = true; return }
        bytes += data.count
        if bytes > MacEditJournal.rotateBytes { rotate() }
        #endif
    }

    #if DEBUG || LEGATO_INTERNAL
    static var directory: URL {
        URL.cachesDirectory.appending(path: Bundle.main.bundleIdentifier ?? "Legato", directoryHint: .isDirectory)
    }

    private func openIfNeeded() -> FileHandle? {
        if let handle { return handle }
        guard !failed else { return nil }
        let directory = Self.directory
        let url = directory.appending(path: MacEditJournal.fileName)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
            let handle = try FileHandle(forWritingTo: url)
            bytes = Int(try handle.seekToEnd())
            self.handle = handle; self.url = url
            if bytes > MacEditJournal.rotateBytes { rotate() }
            return self.handle
        } catch {
            failed = true
            return nil
        }
    }

    /// The current file becomes the previous one; a new one starts.
    private func rotate() {
        guard let url else { return }
        try? handle?.close()
        handle = nil
        let previous = url.deletingLastPathComponent().appending(path: MacEditJournal.previousFileName)
        try? FileManager.default.removeItem(at: previous)
        try? FileManager.default.moveItem(at: url, to: previous)
        bytes = 0
        _ = openIfNeeded()
    }
    #endif
}
