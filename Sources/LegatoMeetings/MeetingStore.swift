import Foundation
import LegatoCore

/// Meetings on disk: one folder per meeting under `root`, named by its id.
///
/// ```
/// <id>/meeting.json          the ``Meeting``
/// <id>/segments.jsonl        the live and post-pass ``MeetingSegment``s (append-only while recording)
/// <id>/segments.live.jsonl   the live text, saved once before the post-pass replaces it
/// <id>/mic.caf|m4a, system.caf|m4a, summary-<backendID>.md   written by other components
/// ```
///
/// The root is `Application Support/Legato/Meetings` on the Mac and the App Group container's `Meetings/`
/// on iOS. Share one instance per root: segment files are ``JSONLFile``s, which allow one writer each.
public actor MeetingStore {
    public let root: URL
    private var segmentFiles: [URL: JSONLFile<MeetingSegment>] = [:]
    private var rootIsPrivate = false

    public init(root: URL) { self.root = root }

    // MARK: Layout

    public func folder(for id: UUID) -> URL { root.appendingPathComponent(id.uuidString, isDirectory: true) }
    public func segmentsURL(for id: UUID) -> URL { folder(for: id).appendingPathComponent("segments.jsonl") }
    public func liveSegmentsURL(for id: UUID) -> URL { folder(for: id).appendingPathComponent("segments.live.jsonl") }
    private func meetingURL(for id: UUID) -> URL { folder(for: id).appendingPathComponent("meeting.json") }

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

    /// A summary some backend wrote for a meeting.
    public struct Summary: Sendable, Equatable {
        /// The backend that wrote it (as made safe for a file name).
        public var backendID: String
        public var text: String
        public var date: Date
    }

    public func summaryURL(for id: UUID, backendID: String) -> URL {
        folder(for: id).appendingPathComponent("summary-\(Self.fileSafe(backendID)).md")
    }

    /// Writes `text` as the backend's summary of the meeting, replacing that backend's earlier one.
    public func saveSummary(_ text: String, backendID: String, for id: UUID) throws {
        try createFolder(for: id)
        try PrivateFiles.write(Data(text.utf8), to: summaryURL(for: id, backendID: backendID))
    }

    /// Every summary of the meeting, newest first.
    public func summaries(for id: UUID) throws -> [Summary] {
        let dir = folder(for: id)
        guard FileManager.default.fileExists(atPath: dir.path) else { return [] }
        let urls = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])
        return urls.compactMap { url -> Summary? in
            let name = url.lastPathComponent
            guard name.hasPrefix("summary-"), name.hasSuffix(".md"),
                let data = try? Data(contentsOf: url)
            else { return nil }
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return Summary(backendID: String(name.dropFirst(8).dropLast(3)), text: String(decoding: data, as: UTF8.self), date: date)
        }
        .sorted { ($0.date, $1.backendID) > ($1.date, $0.backendID) }
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
