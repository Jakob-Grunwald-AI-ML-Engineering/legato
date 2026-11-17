import Foundation
import LegatoCore
import LegatoKeyboardCore

/// Writes the edit journal (`EditJournal`) to the App Group's `Library/Caches/edit-journal.jsonl`, full text included,
/// starting over past `EditJournal.rotateBytes` and keeping the previous file. Every keyboard controller has one, and an
/// old controller can still write while a new one does: the shared file (`RotatingLineFile`) appends each batch of lines
/// whole under a lock. Internal and debug builds only: a release build writes nothing. Pull it from a device with
/// `scripts/device/README.md`'s command.
@MainActor
final class EditJournalFile {
    #if DEBUG || LEGATO_INTERNAL
    private lazy var file: RotatingLineFile? = {
        // Without an App Group (an unsigned Simulator build) the process's own Caches hold it.
        guard let root = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: LinkChannel.appGroupID)
                ?? FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first?.deletingLastPathComponent() else { return nil }
        return RotatingLineFile(directory: root.appendingPathComponent("Library/Caches", isDirectory: true), fileName: EditJournal.fileName,
                                previousFileName: EditJournal.previousFileName, rotateBytes: EditJournal.rotateBytes)
    }()
    #endif

    func write(_ entry: EditJournal.Entry) { write([entry]) }

    func write(_ entries: [EditJournal.Entry]) {
        #if DEBUG || LEGATO_INTERNAL
        guard !entries.isEmpty, let file else { return }
        var data = Data()
        for entry in entries { data.append(EditJournal.line(entry)) }
        file.append(data)
        #endif
    }
}
