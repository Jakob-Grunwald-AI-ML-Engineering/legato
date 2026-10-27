import Foundation
import LegatoCore

/// Summarises a meeting transcript with an ``LLMBackend``, however long it is.
///
/// The transcript becomes lines `Alice [mm:ss]: …`, labelled with the speaker's name (echoes left out; a
/// segment with no speaker, old two-stream ones included, has no name). They are
/// cut at segment boundaries into chunks that fit the backend's ``LLMBackend/maxPromptCharacters`` together
/// with the instructions. Each chunk is summarised; the partial summaries are then merged, batch by batch,
/// until one request holds them all. A backend that refuses a chunk as too long gets it back in halves; one
/// that refuses it as unsafe has the chunk skipped, and the summary says so.
///
/// - The instructions are the template's prompt (or the custom `prompt`), plus the language to write in.
/// - The user's **notes** go in a "Notes from the user (treat as facts)" block at the start of every request,
///   the merge steps included. They are never split or shortened: the transcript chunks shrink to leave room,
///   and notes too long to leave any room fail the summary.
public struct MeetingSummarizer: Sendable {
    /// The prompt used when the user's custom prompt is empty: the built-in Summary template's.
    public static let defaultPrompt = SummaryTemplate.summary.prompt

    /// Heads the user's notes in a request.
    static let notesHeader = "Notes from the user (treat as facts):"

    /// Below this many characters of room for the transcript, summarising cannot work.
    private static let minimumBudget = 200
    private static let separator = "\n\n---\n\n"

    private let backend: any LLMBackend
    private let instructions: String
    private let notesBlock: String
    private let speakers: [PersonID: SpeakerInfo]

    /// - Parameters:
    ///   - prompt: custom instructions that replace the template's; blank means the template's.
    ///   - template: the instructions to follow; the default Summary template when nil.
    ///   - notes: what the user wrote during the meeting; blank means none.
    ///   - language: the locale identifier to write in (`de-DE`); nil is Auto, which leaves it to the
    ///     transcript's language.
    ///   - speakers: the meeting's people, to name the lines.
    public init(
        backend: any LLMBackend, prompt: String = "", template: SummaryTemplate? = nil, notes: String = "",
        language: String? = nil, speakers: [PersonID: SpeakerInfo] = [:]
    ) {
        self.backend = backend
        let custom = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = custom.isEmpty ? (template?.prompt ?? Self.defaultPrompt) : prompt
        self.instructions = base + Self.languageLine(language)
        let trimmedNotes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        self.notesBlock = trimmedNotes.isEmpty ? "" : "\(Self.notesHeader)\n\(trimmedNotes)\n\n"
        self.speakers = speakers
    }

    /// The summary, in Markdown.
    ///
    /// - Throws: ``LLMError/emptyResponse`` when nothing was spoken; ``LLMError/guardrail`` or
    ///   ``LLMError/contextTooLong`` when no part could be summarised; the backend's other errors as they are.
    ///
    /// - Parameter progress: told, after each transcript chunk, how much of the job is done: `i / (chunks + 1)`,
    ///   the merge being the last part. It never reaches 1; the caller knows when the whole summary is written.
    public func summarize(segments: [MeetingSegment], progress: (@Sendable (Double) async -> Void)? = nil) async throws -> String {
        let lines = Self.lines(of: segments, speakers: speakers)
        guard !lines.isEmpty else { throw LLMError.emptyResponse }

        let mergeInstructions = Self.mergeInstructions(for: instructions)
        let room = backend.maxPromptCharacters.map { $0 - max(instructions.count, mergeInstructions.count) }
        let budget = room.map { $0 - notesBlock.count }
        if let room, let budget, budget < Self.minimumBudget {
            throw LLMError.failed(
                room < Self.minimumBudget || notesBlock.isEmpty
                    ? "The summary prompt is too long for this model" : "The notes are too long for this model")
        }

        var skips = Skips()
        var partials: [String] = []
        let chunks = Self.chunks(of: lines, budget: budget)
        for (index, chunk) in chunks.enumerated() {
            try Task.checkCancellation()
            partials += try await summarizeChunk(chunk, skips: &skips)
            await progress?(Double(index + 1) / Double(chunks.count + 1))
        }
        guard !partials.isEmpty else { throw skips.guardrail > 0 ? LLMError.guardrail : LLMError.contextTooLong }

        let merged = try await merge(partials, instructions: mergeInstructions, budget: budget)
        return merged + skips.note
    }

    /// "Write the summary in German." for `de-DE`; nothing for Auto.
    private static func languageLine(_ identifier: String?) -> String {
        guard let identifier, !identifier.isEmpty else { return "" }
        let code = Locale(identifier: identifier).language.languageCode?.identifier ?? identifier
        let name = Locale(identifier: "en_US").localizedString(forLanguageCode: code) ?? identifier
        return "\n\nWrite the summary in \(name)."
    }

    // MARK: Transcript

    static func lines(of segments: [MeetingSegment], speakers: [PersonID: SpeakerInfo] = [:]) -> [String] {
        segments.filter { !$0.echo }.compactMap { segment in
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            let stamp = "[\(clock(segment.start))]: \(text)"
            guard let name = label(of: segment, speakers: speakers) else { return stamp }
            return "\(name) \(stamp)"
        }
    }

    private static func label(of segment: MeetingSegment, speakers: [PersonID: SpeakerInfo]) -> String? {
        segment.speaker.flatMap { speakers[$0]?.name }
    }

    private static func clock(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    /// Greedy chunks of whole lines, each at most `budget` characters (all of it when `budget` is nil).
    /// A line longer than `budget` is cut at word boundaries.
    static func chunks(of lines: [String], budget: Int?) -> [String] {
        guard let budget else { return [lines.joined(separator: "\n")] }
        var chunks: [String] = []
        var current = ""
        func flush() {
            if !current.isEmpty { chunks.append(current) }
            current = ""
        }
        for line in lines.flatMap({ pieces(of: $0, atMost: budget) }) {
            if current.isEmpty {
                current = line
            } else if current.count + 1 + line.count <= budget {
                current += "\n" + line
            } else {
                flush()
                current = line
            }
        }
        flush()
        return chunks
    }

    private static func pieces(of line: String, atMost limit: Int) -> [String] {
        guard line.count > limit else { return [line] }
        var result: [String] = []
        var current = ""
        for word in line.split(separator: " ", omittingEmptySubsequences: true) {
            var word = Substring(word)
            while word.count > limit {  // a single "word" longer than the limit
                if !current.isEmpty { result.append(current); current = "" }
                result.append(String(word.prefix(limit)))
                word = word.dropFirst(limit)
            }
            if current.isEmpty {
                current = String(word)
            } else if current.count + 1 + word.count <= limit {
                current += " " + word
            } else {
                result.append(current)
                current = String(word)
            }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    // MARK: Map

    private struct Skips {
        var guardrail = 0
        var tooLong = 0

        var note: String {
            var parts: [String] = []
            if guardrail > 0 {
                parts.append("\(guardrail) part\(guardrail == 1 ? "" : "s") of the transcript \(guardrail == 1 ? "was" : "were") skipped because the model declined to summarize \(guardrail == 1 ? "it" : "them")")
            }
            if tooLong > 0 {
                parts.append("\(tooLong) part\(tooLong == 1 ? "" : "s") of the transcript \(tooLong == 1 ? "was" : "were") skipped because \(tooLong == 1 ? "it was" : "they were") too long for the model")
            }
            return parts.isEmpty ? "" : "\n\n> Note: " + parts.joined(separator: "; ") + "."
        }
    }

    private func summarizeChunk(_ chunk: String, skips: inout Skips) async throws -> [String] {
        do {
            return [try await backend.respond(instructions: instructions, prompt: notesBlock + chunk)]
        } catch LLMError.contextTooLong {
            guard let (first, second) = Self.halves(of: chunk) else {
                skips.tooLong += 1
                return []
            }
            return try await summarizeChunk(first, skips: &skips) + summarizeChunk(second, skips: &skips)
        } catch LLMError.guardrail {
            skips.guardrail += 1
            return []
        }
    }

    /// `text` cut in two near its middle, at a line break if there is one, else at a space.
    static func halves(of text: String) -> (String, String)? {
        guard text.count >= 40 else { return nil }
        let characters = Array(text)
        let middle = characters.count / 2
        for separator: Character in ["\n", " "] {
            let candidates = characters.indices.filter { characters[$0] == separator && $0 > 0 && $0 < characters.count - 1 }
            if let cut = candidates.min(by: { abs($0 - middle) < abs($1 - middle) }) {
                return (String(characters[..<cut]), String(characters[(cut + 1)...]))
            }
        }
        return (String(characters[..<middle]), String(characters[middle...]))
    }

    // MARK: Reduce

    private static func mergeInstructions(for instructions: String) -> String {
        """
        The text you receive holds summaries of consecutive parts of one meeting transcript. Combine them into \
        one summary of the whole meeting. Remove repetition and keep every decision and action item. Follow \
        these instructions for the result:

        \(instructions)
        """
    }

    private static func mergePrompt(_ parts: [String]) -> String {
        parts.enumerated().map { "Part \($0.offset + 1) of \(parts.count):\n\($0.element)" }.joined(separator: separator)
    }

    /// Merges `partials` into one text: one request when they fit, otherwise batches that fit, repeated on
    /// the results. When a round cannot shrink the list (a batch fails, or each part fills a request alone)
    /// the parts are joined unmerged.
    private func merge(_ partials: [String], instructions: String, budget: Int?) async throws -> String {
        var parts = partials
        while parts.count > 1 {
            try Task.checkCancellation()
            if budget == nil || Self.mergePrompt(parts).count <= budget! {
                do {
                    return try await backend.respond(instructions: instructions, prompt: notesBlock + Self.mergePrompt(parts))
                } catch LLMError.contextTooLong, LLMError.guardrail, LLMError.emptyResponse {
                    return parts.joined(separator: "\n\n")
                }
            }
            let batches = Self.batches(of: parts, budget: budget!)
            var next: [String] = []
            for batch in batches {
                guard batch.count > 1 else { next += batch; continue }
                do {
                    next.append(try await backend.respond(instructions: instructions, prompt: notesBlock + Self.mergePrompt(batch)))
                } catch LLMError.contextTooLong, LLMError.guardrail, LLMError.emptyResponse {
                    next += batch
                }
            }
            if next.count >= parts.count { return next.joined(separator: "\n\n") }
            parts = next
        }
        return parts.first ?? ""
    }

    /// Consecutive parts grouped so each group's merge prompt fits `budget`.
    private static func batches(of parts: [String], budget: Int) -> [[String]] {
        // Header "Part n of n:\n" at its widest, plus the separator between parts.
        let header = "Part \(parts.count) of \(parts.count):\n".count
        var result: [[String]] = []
        var current: [String] = []
        var size = 0
        for part in parts {
            let cost = header + part.count + (current.isEmpty ? 0 : separator.count)
            if !current.isEmpty, size + cost > budget {
                result.append(current)
                current = []
                size = 0
            }
            size += header + part.count + (current.isEmpty ? 0 : separator.count)
            current.append(part)
        }
        if !current.isEmpty { result.append(current) }
        return result
    }
}
