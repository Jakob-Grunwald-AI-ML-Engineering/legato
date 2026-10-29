import Foundation
import LegatoCore

/// The history entry of a run the cleanup agent cleaned. The session saves such a run with the engine's text as
/// `text` and no `rawText` (the agent works in the field, after the session stopped), so the entry is corrected
/// once the run is delivered: `text` is the cleaned text the field shows, `rawText` what the engine heard, so
/// versions (revert to raw, refine) and the vocabulary's learning see the run as for any cleaned dictation.
public enum AgentRunHistory {
    /// `entry` with `cleaned` as its text and the engine's text as `rawText`; nil when cleaning changed nothing.
    public static func corrected(_ entry: DictationEntry, cleaned: String) -> DictationEntry? {
        let text = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        let raw = entry.rawText ?? entry.text
        guard !text.isEmpty, text != raw else { return nil }
        var corrected = entry
        corrected.text = text
        corrected.rawText = raw
        return corrected
    }

    /// `entry` as the field has it: `field` (the run's text now in the field) is its text, `cleaned` (the whole
    /// cleaned text, which the field did not get all of) its other version. Nil when that is the entry as it is.
    public static func shown(_ entry: DictationEntry, field: String, cleaned: String) -> DictationEntry? {
        let text = field.trimmingCharacters(in: .whitespacesAndNewlines)
        let other = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !other.isEmpty, text != other, entry.text != text || entry.rawText != other else { return nil }
        var shown = entry
        shown.text = text
        shown.rawText = other
        return shown
    }

    /// Replaces the saved `entry` in `history` by its corrected version. Returns the entry the history holds
    /// afterwards: `entry` itself when nothing changed or the replacement failed (the original is put back).
    public static func replace(_ entry: DictationEntry, cleaned: String, in history: any HistoryStore) async -> DictationEntry {
        await replace(entry, with: corrected(entry, cleaned: cleaned), in: history)
    }

    /// ``replace(_:cleaned:in:)`` for a field that did not get all of `cleaned`: see ``shown(_:field:cleaned:)``.
    public static func replace(_ entry: DictationEntry, field: String, cleaned: String, in history: any HistoryStore) async -> DictationEntry {
        await replace(entry, with: shown(entry, field: field, cleaned: cleaned), in: history)
    }

    private static func replace(_ entry: DictationEntry, with corrected: DictationEntry?, in history: any HistoryStore) async -> DictationEntry {
        guard let corrected else { return entry }
        do {
            try await history.delete(id: entry.id)
        } catch {
            return entry
        }
        do {
            try await history.append(corrected)
            return corrected
        } catch {
            try? await history.append(entry)
            return entry
        }
    }
}
