import Foundation
import LegatoCore

/// One-time, bounded recovery of finished composer sessions into the existing History store.
///
/// Considers the newest ``maxSessions`` UUID-named directories of `sessions/`. A directory is imported only
/// when its first log lines record `input.source == microphone.soniox`, its log tail holds the `done` session
/// event (`final.md` alone also exists for a paused, still-resumable session) and `final.md` has text. IDs are the
/// directory UUIDs, so they match the live composition IDs; existing entries, excluded (current) sessions,
/// debug/UAT and unknown sources are skipped. Reads are bounded, nothing outside `sessions/` is touched, and a
/// marker file stops later runs so entries the user deleted do not return.
public enum ComposerHistoryBackfill {
    public static let maxSessions = 50
    static let headBytes = 64 * 1024
    static let tailBytes = 256 * 1024
    static let maxFinalBytes = 256 * 1024
    static let engineID = "composer.recovered"

    /// Returns the number of imported entries. Without a full, error-free pass no marker is written, so a
    /// later launch retries; skip rules keep a retry idempotent.
    @discardableResult
    public static func run(sessionsRoot: URL, history: any HistoryStore, excluding: Set<UUID>, markerURL: URL?) async -> Int {
        let fm = FileManager.default
        if let markerURL, fm.fileExists(atPath: markerURL.path) { return 0 }
        guard let existing = try? await history.recent(limit: Int.max) else { return 0 }
        let known = Set(existing.map(\.id))
        guard let listing = try? fm.contentsOfDirectory(at: sessionsRoot, includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey]) else {
            // No sessions directory is a finished pass, not a failure.
            if !fm.fileExists(atPath: sessionsRoot.path) { writeMarker(markerURL) }
            return 0
        }
        var candidates: [(id: UUID, directory: URL, date: Date)] = []
        for url in listing {
            guard let id = UUID(uuidString: url.lastPathComponent), !excluding.contains(id),
                  (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { continue }
            let final = url.appendingPathComponent("final.md")
            let date = (try? final.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                ?? (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            candidates.append((id, url, date))
        }
        candidates.sort { $0.date > $1.date }
        var imported = 0, clean = true
        for candidate in candidates.prefix(maxSessions).reversed() where !known.contains(candidate.id) {
            guard let text = completedMicrophoneText(in: candidate.directory) else { continue }
            let entry = DictationEntry(id: candidate.id, date: candidate.date, text: text,
                localeIdentifier: Locale.current.identifier, engineID: engineID, duration: 0)
            do { try await history.upsert(entry); imported += 1 } catch { clean = false }
        }
        if clean { writeMarker(markerURL) }
        return imported
    }

    private static func writeMarker(_ url: URL?) {
        guard let url else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data().write(to: url)
    }

    /// The final text when every inclusion rule holds, else nil.
    static func completedMicrophoneText(in directory: URL) -> String? {
        let log = directory.appendingPathComponent("room.jsonl")
        guard let handle = try? FileHandle(forReadingFrom: log) else { return nil }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: headBytes), hasMicrophoneSource(head) else { return nil }
        guard let size = try? handle.seekToEnd() else { return nil }
        let start = size > UInt64(tailBytes) ? size - UInt64(tailBytes) : 0
        guard (try? handle.seek(toOffset: start)) != nil, let tail = try? handle.read(upToCount: tailBytes),
              hasDone(tail, droppingFirstPartialLine: start > 0) else { return nil }
        guard let text = boundedText(directory.appendingPathComponent("final.md")),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return text
    }

    private static func sessionEvents(_ data: Data, droppingFirstPartialLine: Bool = false, droppingLastPartialLine: Bool = false) -> [[String: Any]] {
        var lines = data.split(separator: 0x0A, omittingEmptySubsequences: true)
        if droppingFirstPartialLine, !lines.isEmpty { lines.removeFirst() }
        if droppingLastPartialLine, data.last != 0x0A, !lines.isEmpty { lines.removeLast() }
        return lines.compactMap { line in
            guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  object["channel"] as? String == "session", let payload = object["payload"] as? [String: Any] else { return nil }
            return payload
        }
    }

    private static func hasMicrophoneSource(_ head: Data) -> Bool {
        sessionEvents(head, droppingLastPartialLine: head.count >= headBytes).contains {
            $0["event"] as? String == "input.source" && $0["inputSource"] as? String == "microphone.soniox"
        }
    }

    private static func hasDone(_ tail: Data, droppingFirstPartialLine: Bool) -> Bool {
        sessionEvents(tail, droppingFirstPartialLine: droppingFirstPartialLine).contains {
            $0["event"] as? String == "done" && $0["state"] as? String == "done"
        }
    }

    private static func boundedText(_ url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: maxFinalBytes + 1), data.count <= maxFinalBytes else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
