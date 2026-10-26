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

    public init(root: URL) { self.root = root }

    // MARK: Layout

    public func folder(for id: UUID) -> URL { root.appendingPathComponent(id.uuidString, isDirectory: true) }
    public func segmentsURL(for id: UUID) -> URL { folder(for: id).appendingPathComponent("segments.jsonl") }
    public func liveSegmentsURL(for id: UUID) -> URL { folder(for: id).appendingPathComponent("segments.live.jsonl") }
    private func meetingURL(for id: UUID) -> URL { folder(for: id).appendingPathComponent("meeting.json") }

    // MARK: Meetings

    public func create(_ meeting: Meeting) throws { try write(meeting) }
    public func update(_ meeting: Meeting) throws { try write(meeting) }

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

    // MARK: Internals

    private func file(_ url: URL) -> JSONLFile<MeetingSegment> {
        if let existing = segmentFiles[url] { return existing }
        let created = JSONLFile<MeetingSegment>(fileURL: url)
        segmentFiles[url] = created
        return created
    }

    private func write(_ meeting: Meeting) throws {
        try FileManager.default.createDirectory(at: folder(for: meeting.id), withIntermediateDirectories: true)
        try Self.makeEncoder().encode(meeting).write(to: meetingURL(for: meeting.id), options: .atomic)
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
