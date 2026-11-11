import Foundation
import LegatoKeyboardCore

/// Writes the edit journal (`EditJournal`) to the App Group's `Library/Caches/edit-journal.jsonl`, full text included,
/// starting over past `EditJournal.rotateBytes` and keeping the previous file. Internal and debug builds only: a
/// release build writes nothing. Pull it from a device with `scripts/device/README.md`'s command.
@MainActor
final class EditJournalFile {
    #if DEBUG || LEGATO_INTERNAL
    private var handle: FileHandle?
    private var url: URL?
    private var bytes = 0
    private var failed = false
    #endif

    func write(_ entry: EditJournal.Entry) { write([entry]) }

    func write(_ entries: [EditJournal.Entry]) {
        #if DEBUG || LEGATO_INTERNAL
        guard !entries.isEmpty, let handle = openIfNeeded() else { return }
        var data = Data()
        for entry in entries { data.append(EditJournal.line(entry)) }
        do { try handle.write(contentsOf: data) } catch { failed = true; return }
        bytes += data.count
        if bytes > EditJournal.rotateBytes { rotate() }
        #endif
    }

    #if DEBUG || LEGATO_INTERNAL
    private func openIfNeeded() -> FileHandle? {
        if let handle { return handle }
        guard !failed, let root = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: LinkChannel.appGroupID) else {
            failed = true; return nil
        }
        let directory = root.appendingPathComponent("Library/Caches", isDirectory: true)
        let url = directory.appendingPathComponent(EditJournal.fileName)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
            let handle = try FileHandle(forWritingTo: url)
            bytes = Int(try handle.seekToEnd())
            self.handle = handle; self.url = url
            if bytes > EditJournal.rotateBytes { rotate() }
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
        let previous = url.deletingLastPathComponent().appendingPathComponent(EditJournal.previousFileName)
        try? FileManager.default.removeItem(at: previous)
        try? FileManager.default.moveItem(at: url, to: previous)
        bytes = 0
        _ = openIfNeeded()
    }
    #endif
}
