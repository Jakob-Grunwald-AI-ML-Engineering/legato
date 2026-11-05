import Foundation
import LegatoMeetings

/// Why a command could not give an answer, in words for the person (or agent) who asked.
public struct CommandFailure: Error, Equatable {
    public var message: String
    public init(_ message: String) { self.message = message }
}

/// A meeting with everything `show` prints.
public struct MeetingDetail: Sendable {
    public var meeting: Meeting
    public var folder: URL
    /// The newest summary, whichever backend wrote it.
    public var summary: MeetingStore.Summary?
    public var notes: String?
    public var segments: [MeetingSegment]
}

/// Where a search found its words.
public struct Snippet: Sendable, Equatable {
    /// `summary`, `notes` or `transcript`.
    public var source: String
    public var text: String
    /// Seconds into the meeting; transcript only.
    public var atSeconds: Double?
}

public struct SearchHit: Sendable {
    public var meeting: Meeting
    public var snippets: [Snippet]
}

/// The meetings under a folder, for reading. It calls only the store's read paths (no folder or file is created or
/// changed, a missing root is an empty answer) and tolerates what a running app is half way through writing.
public struct MeetingReader: Sendable {
    public let root: URL
    private let store: MeetingStore

    public init(root: URL) {
        self.root = root
        store = MeetingStore(root: root)
    }

    /// Newest first.
    public func list(_ filters: MeetingFilters = MeetingFilters()) async throws -> [Meeting] {
        do {
            return try await store.meetings(matching: MeetingStore.Filter(tags: filters.tags)).filter {
                Self.contains($0.client, filters.client) && Self.contains($0.project, filters.project)
            }
        } catch {
            throw CommandFailure("cannot read the meetings folder \(root.path): \(error.localizedDescription)")
        }
    }

    /// The meetings that contain every word of `words`, newest first, each with where the words were found.
    public func search(_ words: String, _ filters: MeetingFilters = MeetingFilters()) async throws -> [SearchHit] {
        var hits: [SearchHit] = []
        for meeting in try await list(filters) where await store.matches(words, meeting: meeting) {
            let detail = await load(meeting)
            hits.append(SearchHit(meeting: meeting, snippets: Self.snippets(for: words, in: detail)))
        }
        return hits
    }

    /// The meeting whose id is `id` or starts with it (ignoring case and dashes).
    public func detail(id: String) async throws -> MeetingDetail {
        await load(try await resolve(id))
    }

    func resolve(_ id: String) async throws -> Meeting {
        let wanted = Self.bare(id)
        guard !wanted.isEmpty, wanted.allSatisfy(\.isHexDigit) else {
            throw CommandFailure("'\(id)' is not a meeting id; use the id from 'legato meetings list' or the start of one")
        }
        let all = try await list()
        let matching = all.filter { Self.bare($0.id.uuidString).hasPrefix(wanted) }
        switch matching.count {
        case 1: return matching[0]
        case 0: throw CommandFailure("no meeting with id '\(id)'; 'legato meetings list' shows the ids")
        default:
            let names = matching.prefix(5).map { "\($0.id.uuidString) (\($0.title))" }.joined(separator: ", ")
            throw CommandFailure("id '\(id)' fits \(matching.count) meetings: \(names); give more of the id")
        }
    }

    private func load(_ meeting: Meeting) async -> MeetingDetail {
        let summaries = (try? await store.summaries(for: meeting.id)) ?? []
        return MeetingDetail(
            meeting: meeting, folder: await store.folder(for: meeting.id), summary: MeetingListLogic.shownSummary(in: summaries),
            notes: (try? await store.notes(for: meeting.id)) ?? nil, segments: (try? await store.segments(for: meeting.id)) ?? [])
    }

    /// True when `wanted` is nil or part of `value`: "Nordlicht" finds "Nordlicht Verlag".
    private static func contains(_ value: String?, _ wanted: String?) -> Bool {
        guard let wanted else { return true }
        return value?.range(of: wanted, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }

    private static func bare(_ id: String) -> String { id.lowercased().replacingOccurrences(of: "-", with: "") }

    // MARK: Snippets

    /// At most three short excerpts: the summary's, the notes' and the first lines of the transcript that hold one of the words.
    static func snippets(for query: String, in detail: MeetingDetail) -> [Snippet] {
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        var found: [Snippet] = []
        if let text = detail.summary?.text, let excerpt = excerpt(of: text, words) {
            found.append(Snippet(source: "summary", text: excerpt, atSeconds: nil))
        }
        if let text = detail.notes, let excerpt = excerpt(of: text, words) {
            found.append(Snippet(source: "notes", text: excerpt, atSeconds: nil))
        }
        for segment in detail.segments where found.count < 3 {
            if let excerpt = excerpt(of: segment.text, words) {
                found.append(Snippet(source: "transcript", text: excerpt, atSeconds: segment.start))
            }
        }
        return found
    }

    private static func excerpt(of text: String, _ words: [String]) -> String? {
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        guard let hit = words.compactMap({ text.range(of: $0, options: options) }).min(by: { $0.lowerBound < $1.lowerBound }) else { return nil }
        let start = text.index(hit.lowerBound, offsetBy: -60, limitedBy: text.startIndex) ?? text.startIndex
        let end = text.index(hit.upperBound, offsetBy: 100, limitedBy: text.endIndex) ?? text.endIndex
        let flat = text[start..<end].split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return (start > text.startIndex ? "…" : "") + flat + (end < text.endIndex ? "…" : "")
    }
}
