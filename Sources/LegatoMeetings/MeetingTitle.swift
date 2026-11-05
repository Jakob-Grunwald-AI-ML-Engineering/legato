import Foundation
import LegatoCore

/// Asks Claude for a short title for a meeting from its finished summary: one small request, apart from the
/// summary itself, so a title that fails never touches the summary.
public struct MeetingTitle: Sendable {
    /// The longest title kept; a longer reply is not a title.
    static let maxLength = 80
    /// How much of the summary is sent; a title needs the gist, not the whole document.
    private static let maxSummaryCharacters = 6_000

    static let instructions = """
        Give a short title for the meeting this summary describes: at most eight words, in the language of the \
        summary, naming what the meeting was about. Reply with the title only, on one line, with no quotes, no \
        Markdown and no full stop.
        """

    private let backend: any LLMBackend

    public init(backend: any LLMBackend) { self.backend = backend }

    /// The title for `summary`; nil when the request fails or the reply is not usable as a title.
    public func title(forSummary summary: String) async -> String? {
        let text = String(summary.prefix(Self.maxSummaryCharacters))
        guard let reply = try? await backend.respond(instructions: Self.instructions, prompt: text) else { return nil }
        return Self.sanitized(reply)
    }

    /// The first non-blank line of `reply` without Markdown marks, quotes and a trailing full stop; nil when nothing
    /// is left or it is longer than ``maxLength``.
    static func sanitized(_ reply: String) -> String? {
        let line = reply.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty } ?? ""
        var title = line
        // "# Title", "**Title**", "- Title": leading marks, then wrapping emphasis and quotes.
        title = String(title.drop { "#-*> ".contains($0) })
        let wrappers = CharacterSet(charactersIn: "*_`\"'“”„‚‘’«»")
        title = title.trimmingCharacters(in: wrappers.union(.whitespaces))
        if title.hasSuffix(".") { title.removeLast() }
        title = title.trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty, title.count <= maxLength else { return nil }
        return title
    }
}
