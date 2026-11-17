import Foundation
import LegatoCore
import LegatoMac

/// Writes the field queue's edit journal (`MacEditJournal`) to `~/Library/Caches/<bundle id>/edit-journal.jsonl`, full
/// text included, starting over past `MacEditJournal.rotateBytes` and keeping the previous file (`RotatingLineFile`: each
/// line whole under a lock). Debug and internal builds only: a release build writes nothing.
@MainActor
final class EditJournalFile {
    #if DEBUG || LEGATO_INTERNAL
    private let file = RotatingLineFile(directory: EditJournalFile.directory, fileName: MacEditJournal.fileName,
                                        previousFileName: MacEditJournal.previousFileName, rotateBytes: MacEditJournal.rotateBytes)
    #endif

    func write(_ entry: MacEditJournal.Entry) {
        #if DEBUG || LEGATO_INTERNAL
        file.append(MacEditJournal.line(entry))
        #endif
    }

    #if DEBUG || LEGATO_INTERNAL
    nonisolated static var directory: URL {
        URL.cachesDirectory.appending(path: Bundle.main.bundleIdentifier ?? "Legato", directoryHint: .isDirectory)
    }
    #endif
}
