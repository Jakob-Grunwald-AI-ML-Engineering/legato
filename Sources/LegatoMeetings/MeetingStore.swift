import Foundation
import LegatoCore

/// Meetings on disk: one folder per meeting under `root`, named by its id.
///
/// ```
/// <id>/meeting.json          the ``Meeting``
/// <id>/segments.jsonl        the ``MeetingSegment``s (append-only while recording)
/// <id>/notes.md              what the user wrote during and after the meeting (private, like every file here)
/// <id>/summaries/<backendID>.md              a backend's summary, as written (the ticked sections)
/// <id>/summaries/<backendID>.sections.json   the sections it was written with
/// <id>/log/room.jsonl        the session log of the live transcription (see ``SessionLog``)
/// <id>/mic.caf|m4a, system.caf|m4a, mix.caf|m4a   written by other components
/// ```
///
/// The root is `Application Support/Legato/Meetings`. Share one instance per root: segment files are ``JSONLFile``s, which allow one writer each.
public actor MeetingStore {
    public let root: URL
    private var segmentFiles: [URL: JSONLFile<MeetingSegment>] = [:]
    private var rootIsPrivate = false

    public init(root: URL) { self.root = root }

    // MARK: Layout

    public func folder(for id: UUID) -> URL { root.appendingPathComponent(id.uuidString, isDirectory: true) }
    public func segmentsURL(for id: UUID) -> URL { folder(for: id).appendingPathComponent("segments.jsonl") }
    private func meetingURL(for id: UUID) -> URL { folder(for: id).appendingPathComponent("meeting.json") }
    public func notesURL(for id: UUID) -> URL { folder(for: id).appendingPathComponent("notes.md") }
    /// Where the meeting's live transcription logs its Room (`room.jsonl` inside).
    public func logRoot(for id: UUID) -> URL { folder(for: id) }
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
    /// writers that each own a few fields (the session, the pipeline, a rename) never
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
        guard FileManager.default.fileExists(atPath: folder.path) else { return }
        try FileManager.default.removeItem(at: folder)
    }

    // MARK: Metadata

    /// Files the meeting: its title (blank keeps the old one), client, project and tags, normalized
    /// (``MeetingMetadata/normalized(fallbackTitle:)``). Returns the saved meeting, nil when it does not exist.
    @discardableResult
    public func updateMetadata(id: UUID, _ metadata: MeetingMetadata) throws -> Meeting? {
        try update(id: id) { meeting in
            let old = meeting.title
            meeting.metadata = metadata.normalized(fallbackTitle: old)
            if meeting.title != old { meeting.titleIsAutomatic = false }
        }
    }

    /// What a list narrows to. Client, project and tags match ignoring case and accents; every tag must be on the
    /// meeting. `query` words must each appear in the title, client, project or a tag.
    public struct Filter: Sendable, Equatable {
        public var client: String?
        public var project: String?
        public var tags: [String]
        public var query: String

        public init(client: String? = nil, project: String? = nil, tags: [String] = [], query: String = "") {
            self.client = client
            self.project = project
            self.tags = tags
            self.query = query
        }

        public func matches(_ meeting: Meeting) -> Bool {
            if let client, !Self.same(client, meeting.client) { return false }
            if let project, !Self.same(project, meeting.project) { return false }
            for tag in tags where !meeting.tags.contains(where: { Self.same(tag, $0) }) { return false }
            let haystack = ([meeting.title, meeting.client, meeting.project].compactMap { $0 } + meeting.tags).joined(separator: "\n")
            return query.split(whereSeparator: \.isWhitespace).allSatisfy {
                haystack.range(of: String($0), options: [.caseInsensitive, .diacriticInsensitive]) != nil
            }
        }

        private static func same(_ a: String, _ b: String?) -> Bool {
            guard let b else { return false }
            return a.compare(b, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        }
    }

    /// Newest first, narrowed by `filter`.
    public func meetings(matching filter: Filter) throws -> [Meeting] {
        try meetings().filter(filter.matches)
    }

    /// The clients in use, sorted, one spelling for each (the first meeting's, newest first).
    public func knownClients() throws -> [String] { Self.distinct(try meetings().compactMap(\.client)) }

    /// The projects in use, sorted; of one `client` when given.
    public func knownProjects(client: String? = nil) throws -> [String] {
        let all = try meetings().filter { client == nil || Filter(client: client).matches($0) }
        return Self.distinct(all.compactMap(\.project))
    }

    public func knownTags() throws -> [String] { Self.distinct(try meetings().flatMap(\.tags)) }

    private static func distinct(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)).inserted }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
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

    // MARK: Segments

    public func appendSegment(_ segment: MeetingSegment, to id: UUID) async throws {
        try await file(segmentsURL(for: id)).append(segment)
    }

    public func replaceSegments(_ segments: [MeetingSegment], for id: UUID) async throws {
        try await file(segmentsURL(for: id)).replaceAll(segments)
    }

    /// Whether the meeting has any transcript segment, from the size of the file alone (cheap enough for a list).
    public func hasSegments(for id: UUID) -> Bool {
        let size = (try? FileManager.default.attributesOfItem(atPath: segmentsURL(for: id).path)[.size] as? Int) ?? 0
        return size > 0
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

    /// A summary some backend wrote for a meeting. A backend has one: the file it wrote last.
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

    /// Every backend's summary of the meeting, newest first.
    public func summaries(for id: UUID) throws -> [Summary] {
        let fm = FileManager.default
        let keys: Set<URLResourceKey> = [.contentModificationDateKey]
        let notesDate = (try? notesURL(for: id).resourceValues(forKeys: keys).contentModificationDate)
        let entries = (try? fm.contentsOfDirectory(at: summariesFolder(for: id), includingPropertiesForKeys: Array(keys))) ?? []
        var found: [Summary] = []
        for url in entries where url.pathExtension == "md" {
            guard let data = try? Data(contentsOf: url) else { continue }
            let backend = url.deletingPathExtension().lastPathComponent
            let date = (try? url.resourceValues(forKeys: keys).contentModificationDate) ?? .distantPast
            let sections = (try? Data(contentsOf: sectionsURL(for: id, backendID: backend)))
                .flatMap { try? JSONDecoder().decode([SectionID].self, from: $0) }
            found.append(Summary(
                sections: sections, backendID: backend, text: String(decoding: data, as: UTF8.self), date: date,
                isStale: notesDate.map { $0 > date } ?? false))
        }
        return found.sorted { ($0.date, $1.backendID) > ($1.date, $0.backendID) }
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
