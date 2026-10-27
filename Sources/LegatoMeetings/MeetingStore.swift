import Foundation
import LegatoCore

/// Meetings on disk: one folder per meeting under `root`, named by its id.
///
/// ```
/// <id>/meeting.json          the ``Meeting``
/// <id>/segments.jsonl        the live and post-pass ``MeetingSegment``s (append-only while recording)
/// <id>/segments.live.jsonl   the live text, saved once before the post-pass replaces it
/// <id>/notes.md              what the user wrote during and after the meeting (private, like every file here)
/// <id>/turns.live.jsonl      the live diarizer's turns as person ids, appended as they settle while recording
/// <id>/turns.offline.json    the after-meeting diarizer's turns as person ids (absent until that pass ran)
/// <id>/summaries/<backendID>.md              a backend's summary, as written (the ticked sections)
/// <id>/summaries/<backendID>.sections.json   the sections it was written with
/// <id>/summaries/<templateID>/<backendID>.md   older: one template's summary, read with that template's sections
/// <id>/summary-<backendID>.md                  older still: read as the Summary template's sections
/// <id>/mic.caf|m4a, system.caf|m4a, mix.caf|m4a   written by other components
/// ```
///
/// The root is `Application Support/Legato/Meetings` on the Mac and the App Group container's `Meetings/`
/// on iOS. Share one instance per root: segment files are ``JSONLFile``s, which allow one writer each.
public actor MeetingStore {
    public let root: URL
    private var segmentFiles: [URL: JSONLFile<MeetingSegment>] = [:]
    private var turnFiles: [URL: JSONLFile<SpeakerTurn>] = [:]
    private var rootIsPrivate = false

    public init(root: URL) { self.root = root }

    // MARK: Layout

    public func folder(for id: UUID) -> URL { root.appendingPathComponent(id.uuidString, isDirectory: true) }
    public func segmentsURL(for id: UUID) -> URL { folder(for: id).appendingPathComponent("segments.jsonl") }
    public func liveSegmentsURL(for id: UUID) -> URL { folder(for: id).appendingPathComponent("segments.live.jsonl") }
    private func meetingURL(for id: UUID) -> URL { folder(for: id).appendingPathComponent("meeting.json") }
    public func notesURL(for id: UUID) -> URL { folder(for: id).appendingPathComponent("notes.md") }
    public func liveTurnsURL(for id: UUID) -> URL { folder(for: id).appendingPathComponent("turns.live.jsonl") }
    public func offlineTurnsURL(for id: UUID) -> URL { folder(for: id).appendingPathComponent("turns.offline.json") }
    private func summariesFolder(for id: UUID) -> URL { folder(for: id).appendingPathComponent("summaries", isDirectory: true) }

    /// Creates (if needed) the folder of a meeting, private like the root, and returns it. A recording
    /// holds what people said, so the folders are `0700` on the Mac and protected until first unlock on iOS.
    @discardableResult
    public func createFolder(for id: UUID) throws -> URL {
        try ensurePrivateRoot()
        let folder = folder(for: id)
        try PrivateFiles.createDirectory(folder)
        return folder
    }

    // MARK: Meetings

    public func create(_ meeting: Meeting) throws { try write(meeting) }
    public func update(_ meeting: Meeting) throws { try write(meeting) }

    /// Re-reads the meeting, applies `transform` and writes it back, all without a suspension point, so
    /// writers that each own a few fields (the session, the post-pass, the pipeline, a rename) never
    /// overwrite one another with a stale copy. Returns the saved meeting, nil when it does not exist.
    @discardableResult
    public func update(id: UUID, _ transform: @Sendable (inout Meeting) -> Void) throws -> Meeting? {
        guard var current = try meeting(id: id) else { return nil }
        transform(&current)
        try write(current)
        return current
    }

    public func meeting(id: UUID) throws -> Meeting? {
        let url = meetingURL(for: id)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try Self.makeDecoder().decode(Meeting.self, from: Data(contentsOf: url))
    }

    /// Newest first. A folder whose `meeting.json` cannot be read is skipped.
    public func meetings() throws -> [Meeting] {
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        let folders = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        return folders.compactMap { UUID(uuidString: $0.lastPathComponent) }
            .compactMap { try? meeting(id: $0) }
            .sorted { $0.date > $1.date }
    }

    /// Removes the meeting's folder and everything in it (a discarded meeting). A meeting that is gone is fine.
    public func deleteMeeting(id: UUID) throws {
        let folder = folder(for: id)
        for url in segmentFiles.keys where url.path.hasPrefix(folder.path + "/") { segmentFiles[url] = nil }
        for url in turnFiles.keys where url.path.hasPrefix(folder.path + "/") { turnFiles[url] = nil }
        guard FileManager.default.fileExists(atPath: folder.path) else { return }
        try FileManager.default.removeItem(at: folder)
    }

    // MARK: Notes

    /// The user's notes; nil when there are none (a blank note is no note).
    public func notes(for id: UUID) throws -> String? {
        let url = notesURL(for: id)
        guard let data = try? Data(contentsOf: url) else { return nil }
        let text = String(decoding: data, as: UTF8.self)
        return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text
    }

    /// Saves the notes. Saving what is already there changes nothing, so it cannot make a summary stale. Blank
    /// notes empty the file rather than remove it: its modification time still says the notes changed, so a
    /// summary written with the old notes is stale.
    ///
    /// A meeting whose folder is gone (discarded, deleted) is not brought back: a late save, such as the window's
    /// notes debounce firing after Discard, does nothing.
    public func saveNotes(_ text: String, for id: UUID) throws {
        guard FileManager.default.fileExists(atPath: folder(for: id).path) else { return }
        let url = notesURL(for: id)
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard try notes(for: id) != nil else { return }  // nothing to clear
            try PrivateFiles.write(Data(), to: url)
            return
        }
        if let existing = try notes(for: id), existing == text { return }
        try PrivateFiles.write(Data(text.utf8), to: url)
    }

    // MARK: Speaker turns

    /// The live diarizer's turns (person ids), in time order; empty when none were saved.
    public func liveTurns(for id: UUID) async throws -> [SpeakerTurn] {
        try await turnFile(liveTurnsURL(for: id)).elements()
    }

    /// Replaces the live turns (a merge of two people rewrites them).
    public func saveLiveTurns(_ turns: [SpeakerTurn], for id: UUID) async throws {
        try createFolder(for: id)
        try await turnFile(liveTurnsURL(for: id)).replaceAll(turns)
    }

    /// Adds live turns that will not change any more; the recording session writes the file this way.
    public func appendLiveTurns(_ turns: [SpeakerTurn], for id: UUID) async throws {
        guard !turns.isEmpty else { return }
        try createFolder(for: id)
        let file = turnFile(liveTurnsURL(for: id))
        for turn in turns { try await file.append(turn) }
    }

    /// The after-meeting pass's turns (person ids); nil until that pass ran. An empty array is a result:
    /// the pass ran and found no one.
    public func offlineTurns(for id: UUID) throws -> [SpeakerTurn]? {
        guard let data = try? Data(contentsOf: offlineTurnsURL(for: id)) else { return nil }
        return try JSONDecoder().decode([SpeakerTurn].self, from: data)
    }

    public func saveOfflineTurns(_ turns: [SpeakerTurn], for id: UUID) throws {
        try createFolder(for: id)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try PrivateFiles.write(try encoder.encode(turns), to: offlineTurnsURL(for: id))
    }

    // MARK: Segments

    public func appendSegment(_ segment: MeetingSegment, to id: UUID) async throws {
        try await file(segmentsURL(for: id)).append(segment)
    }

    public func replaceSegments(_ segments: [MeetingSegment], for id: UUID) async throws {
        try await file(segmentsURL(for: id)).replaceAll(segments)
    }

    /// Saves `segments` as the meeting's live text unless that was already done; returns whether it wrote.
    /// The post-pass calls this before replacing segments, so a re-run never overwrites the live text.
    @discardableResult
    public func saveLiveSegmentsOnce(_ segments: [MeetingSegment], for id: UUID) async throws -> Bool {
        let url = liveSegmentsURL(for: id)
        guard !FileManager.default.fileExists(atPath: url.path) else { return false }
        try await file(url).replaceAll(segments)
        return true
    }

    /// The live text saved by ``saveLiveSegmentsOnce(_:for:)``; empty before the post-pass ran.
    public func liveSegments(for id: UUID) async throws -> [MeetingSegment] {
        try await file(liveSegmentsURL(for: id)).elements()
    }

    /// Ordered by start time (arrival order breaks ties).
    public func segments(for id: UUID) async throws -> [MeetingSegment] {
        Self.ordered(try await file(segmentsURL(for: id)).elements())
    }

    static func ordered(_ segments: [MeetingSegment]) -> [MeetingSegment] {
        segments.enumerated()
            .sorted { ($0.element.start, $0.offset) < ($1.element.start, $1.offset) }
            .map(\.element)
    }

    // MARK: Summaries

    /// A summary some backend wrote for a meeting. A backend has one: the newest file it wrote, whatever the layout.
    public struct Summary: Sendable, Equatable {
        /// The sections it was written with; nil when that is not known.
        public var sections: [SectionID]?
        /// The backend that wrote it (as made safe for a file name).
        public var backendID: String
        public var text: String
        public var date: Date
        /// The user's notes changed after it was written, so it does not reflect them: offer Regenerate.
        public var isStale: Bool

        public init(sections: [SectionID]?, backendID: String, text: String, date: Date, isStale: Bool) {
            self.sections = sections
            self.backendID = backendID
            self.text = text
            self.date = date
            self.isStale = isStale
        }
    }

    /// Where a backend's summary of the meeting lives.
    public func summaryURL(for id: UUID, backendID: String) -> URL {
        summariesFolder(for: id).appendingPathComponent("\(Self.fileSafe(backendID)).md")
    }

    private func sectionsURL(for id: UUID, backendID: String) -> URL {
        summariesFolder(for: id).appendingPathComponent("\(Self.fileSafe(backendID)).sections.json")
    }

    /// Writes `text` as the backend's summary of the meeting, replacing its earlier one, with the sections it
    /// was written with.
    public func saveSummary(_ text: String, backendID: String, sections: [SectionID]? = nil, for id: UUID) throws {
        try createFolder(for: id)
        try PrivateFiles.createDirectory(summariesFolder(for: id))
        let sidecar = sectionsURL(for: id, backendID: backendID)
        if let sections {
            try PrivateFiles.write(try JSONEncoder().encode(sections), to: sidecar)
        } else if FileManager.default.fileExists(atPath: sidecar.path) {
            try FileManager.default.removeItem(at: sidecar)
        }
        // Written last: its date is the summary's.
        try PrivateFiles.write(Data(text.utf8), to: summaryURL(for: id, backendID: backendID))
    }

    /// Every backend's summary of the meeting, newest first. A backend's newest file wins, whichever layout it is
    /// in: `summaries/<backend>.md`, an older `summaries/<template>/<backend>.md` (read with that template's
    /// sections) or `summary-<backend>.md` (the Summary template's).
    public func summaries(for id: UUID) throws -> [Summary] {
        let dir = folder(for: id)
        guard FileManager.default.fileExists(atPath: dir.path) else { return [] }
        let fm = FileManager.default
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .isDirectoryKey]
        let notesDate = (try? notesURL(for: id).resourceValues(forKeys: keys).contentModificationDate)
        var found: [String: Summary] = [:]  // by backend
        func consider(_ url: URL, backend: String, sections: [SectionID]?) {
            guard let data = try? Data(contentsOf: url) else { return }
            let date = (try? url.resourceValues(forKeys: keys).contentModificationDate) ?? .distantPast
            if let existing = found[backend], existing.date > date { return }  // an equal date: the later layout wins
            found[backend] = Summary(
                sections: sections, backendID: backend, text: String(decoding: data, as: UTF8.self), date: date,
                isStale: notesDate.map { $0 > date } ?? false)
        }

        for url in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [] {
            let name = url.lastPathComponent
            guard name.hasPrefix("summary-"), name.hasSuffix(".md") else { continue }
            consider(url, backend: String(name.dropFirst(8).dropLast(3)), sections: SummarySection.sections(forTemplate: "summary"))
        }
        let entries = (try? fm.contentsOfDirectory(at: summariesFolder(for: id), includingPropertiesForKeys: Array(keys))) ?? []
        for entry in entries where (try? entry.resourceValues(forKeys: keys).isDirectory) == true {
            let template = entry.lastPathComponent
            for url in (try? fm.contentsOfDirectory(at: entry, includingPropertiesForKeys: nil)) ?? [] where url.pathExtension == "md" {
                consider(url, backend: url.deletingPathExtension().lastPathComponent, sections: SummarySection.sections(forTemplate: template))
            }
        }
        for url in entries where url.pathExtension == "md" && (try? url.resourceValues(forKeys: keys).isDirectory) != true {
            let backend = url.deletingPathExtension().lastPathComponent
            let sections = (try? Data(contentsOf: sectionsURL(for: id, backendID: backend)))
                .flatMap { try? JSONDecoder().decode([SectionID].self, from: $0) }
            consider(url, backend: backend, sections: sections)
        }
        return found.values.sorted { ($0.date, $1.backendID) > ($1.date, $0.backendID) }
    }

    private static func fileSafe(_ id: String) -> String {
        String(id.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "." ? $0 : "-" })
    }

    // MARK: Internals

    private func ensurePrivateRoot() throws {
        guard !rootIsPrivate else { return }
        try PrivateFiles.createDirectory(root)
        rootIsPrivate = true
    }

    private func file(_ url: URL) -> JSONLFile<MeetingSegment> {
        if let existing = segmentFiles[url] { return existing }
        let created = JSONLFile<MeetingSegment>(fileURL: url, ownerOnly: true)
        segmentFiles[url] = created
        return created
    }

    private func turnFile(_ url: URL) -> JSONLFile<SpeakerTurn> {
        if let existing = turnFiles[url] { return existing }
        let created = JSONLFile<SpeakerTurn>(fileURL: url, ownerOnly: true)
        turnFiles[url] = created
        return created
    }

    private func write(_ meeting: Meeting) throws {
        try createFolder(for: meeting.id)
        try PrivateFiles.write(try Self.makeEncoder().encode(meeting), to: meetingURL(for: meeting.id))
    }

    private static func makeEncoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .millisecondsSince1970
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }

    private static func makeDecoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .millisecondsSince1970
        return d
    }
}
