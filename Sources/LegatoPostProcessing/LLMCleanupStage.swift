import Foundation
import LegatoCore

/// Cleans a transcript with a language model: punctuation, casing, spelling, written forms and likely
/// misrecognitions, without adding or dropping content.
///
/// Long input is cut at sentence boundaries and cleaned chunk by chunk. A chunk whose reply drifts past
/// the ``CleanupGuard``, comes back empty or trips the backend's guardrail keeps its own text, so one bad
/// chunk never costs the rest. An unavailable backend or any other error throws, which the pipeline turns
/// into "no change".
public struct LLMCleanupStage: TranscriptPostProcessor {
    public let id = "llm-cleanup"

    private let backend: any LLMBackend
    private let cleanupGuard: CleanupGuard
    private let maxChunkCharacters: Int
    private let vocabulary: [String]
    private let prompt: CleanupPrompt
    private let context: String

    /// How many characters of `context` the model sees at most (its end).
    public static let maxContextCharacters = 400

    /// - Parameters:
    ///   - maxChunkCharacters: upper bound for one chunk of input; the backend's own limit can lower it.
    ///   - vocabulary: the user's names and terms, offered as likely meanings of misheard words.
    ///   - prompt: how a chunk is put to the model.
    ///   - context: the already cleaned text that came just before this one (live cleanup cleans a dictation
    ///     segment by segment). Its end (``maxContextCharacters``) is shown to the model, marked as context
    ///     only, so the text continues it; it is never part of the reply. Empty: the prompt is unchanged.
    public init(
        backend: any LLMBackend,
        cleanupGuard: CleanupGuard = CleanupGuard(),
        maxChunkCharacters: Int = 1200,
        vocabulary: [String] = [],
        prompt: CleanupPrompt = .standard,
        context: String = ""
    ) {
        self.backend = backend
        self.cleanupGuard = cleanupGuard
        self.maxChunkCharacters = maxChunkCharacters
        self.vocabulary = vocabulary
        self.prompt = prompt
        self.context = Self.boundedContext(context)
    }

    /// The end of `context`, trimmed, at most ``maxContextCharacters`` long and starting at a word.
    static func boundedContext(_ context: String) -> String {
        let trimmed = context.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > maxContextCharacters else { return trimmed }
        let tail = trimmed.suffix(maxContextCharacters)
        guard let gap = tail.firstIndex(where: \.isWhitespace) else { return String(tail) }
        return String(tail[gap...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static let contextInstruction = """
        The text in <before> tags came just before and is already clean: use it only to continue its sentence and style. Never repeat or change it; reply with the <text> only.
        """

    // MARK: chunking

    /// Cuts `text` into pieces of at most `maxCharacters`, at sentence ends. A sentence longer than the
    /// limit is cut at word boundaries, or by character where there are none. Joining the pieces with
    /// `joiner` restores the sentence text: a space, or nothing for Chinese and Japanese, which are written
    /// without spaces.
    public static func chunks(of text: String, maxCharacters: Int, joiner: String = " ") -> [String] {
        let limit = max(1, maxCharacters)
        var sentences: [String] = []
        text.enumerateSubstrings(in: text.startIndex..., options: .bySentences) { substring, _, _, _ in
            if let sentence = substring?.trimmingCharacters(in: .whitespacesAndNewlines), !sentence.isEmpty {
                sentences.append(sentence)
            }
        }
        var pieces: [String] = []
        for sentence in sentences {
            if sentence.count <= limit {
                pieces.append(sentence)
                continue
            }
            // The system tokenizer misses breaks before lowercase words; split at terminators ourselves.
            for part in splitAtTerminators(sentence) {
                if part.count <= limit {
                    pieces.append(part)
                } else {
                    pieces.append(contentsOf: splitAtWords(part, limit: limit))
                }
            }
        }
        var chunks: [String] = []
        var current = ""
        for piece in pieces {
            if current.isEmpty {
                current = piece
            } else if current.count + joiner.count + piece.count <= limit {
                current += joiner + piece
            } else {
                chunks.append(current)
                current = piece
            }
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }

    /// Whether `locale` is written without spaces between words.
    static func isUnspaced(_ locale: Locale) -> Bool {
        guard let code = locale.language.languageCode?.identifier else { return false }
        return code == "zh" || code == "ja" || code == "yue"
    }

    /// Cuts after each `.`, `!` or `?` that is followed by whitespace, and after each CJK `。`, `！` or `？`.
    private static func splitAtTerminators(_ text: String) -> [String] {
        var parts: [String] = []
        var current = ""
        var previousWasTerminator = false
        for character in text {
            if character.isWhitespace, previousWasTerminator {
                parts.append(current)
                current = ""
                previousWasTerminator = false
                continue
            }
            current.append(character)
            previousWasTerminator = ".!?".contains(character)
            if "。！？".contains(character) {
                parts.append(current)
                current = ""
            }
        }
        if !current.isEmpty { parts.append(current) }
        return parts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    private static func splitAtWords(_ sentence: String, limit: Int) -> [String] {
        var parts: [String] = []
        var current = ""
        for word in sentence.split(whereSeparator: \.isWhitespace) {
            // A "word" over the limit has no spaces to cut at (Chinese, Japanese): cut it by character.
            let pieces = word.count <= limit ? [String(word)] : hardCut(String(word), limit: limit)
            for piece in pieces {
                if current.isEmpty {
                    current = piece
                } else if current.count + 1 + piece.count <= limit {
                    current += " " + piece
                } else {
                    parts.append(current)
                    current = piece
                }
            }
        }
        if !current.isEmpty { parts.append(current) }
        return parts
    }

    private static func hardCut(_ text: String, limit: Int) -> [String] {
        var parts: [String] = []
        var rest = Substring(text)
        while !rest.isEmpty {
            parts.append(String(rest.prefix(limit)))
            rest = rest.dropFirst(limit)
        }
        return parts
    }

    // MARK: process

    /// What became of one chunk.
    struct ChunkResult: Sendable, Equatable {
        /// The chunk sent to the model.
        var input: String
        /// The model's raw reply, or `nil` when the backend answered with nothing or refused.
        var reply: String?
        /// What the stage keeps: the cleaned reply, or `input` when the reply was missing or rejected.
        var output: String
        /// Whether the reply passed the ``CleanupGuard``.
        var accepted: Bool
    }

    public func process(_ text: String, locale: Locale) async throws -> String {
        let joiner = Self.isUnspaced(locale) ? "" : " "
        let results = try await processChunks(text, locale: locale)
        return results.isEmpty ? text : results.map(\.output).joined(separator: joiner)
    }

    /// ``process(_:locale:)`` with each chunk's outcome kept, for evaluation.
    func processChunks(_ text: String, locale: Locale) async throws -> [ChunkResult] {
        if case .unavailable(let reason) = await backend.availability {
            throw LLMError.unavailable(reason: reason)
        }
        let instructions = prompt.instructions(locale, vocabulary) + (context.isEmpty ? "" : "\n" + Self.contextInstruction)
        let examples = prompt.examples(locale)
        let joiner = Self.isUnspaced(locale) ? "" : " "
        let overhead = instructions.count + contextPrefix.count
            + examples.reduce(0) { $0 + $1.user.count + $1.assistant.count }
        let chunks = Self.chunks(of: text, maxCharacters: chunkLimit(overhead: overhead), joiner: joiner)

        var results: [ChunkResult] = []
        for chunk in chunks {
            try Task.checkCancellation()
            results.append(try await clean(chunk, instructions: instructions, examples: examples, locale: locale))
        }
        return results
    }

    private func clean(
        _ chunk: String, instructions: String, examples: [LLMExample], locale: Locale
    ) async throws -> ChunkResult {
        let reply: String
        do {
            reply = try await backend.respond(
                instructions: instructions, examples: examples,
                prompt: contextPrefix + prompt.userMessage(chunk, locale, vocabulary))
        } catch LLMError.guardrail {
            return ChunkResult(input: chunk, reply: nil, output: chunk, accepted: false)
        } catch LLMError.contextTooLong {
            return ChunkResult(input: chunk, reply: nil, output: chunk, accepted: false)
        } catch LLMError.emptyResponse {
            return ChunkResult(input: chunk, reply: nil, output: chunk, accepted: false)
        }
        let candidate = prompt.extractText(reply)
        let accepted = cleanupGuard.accepts(candidate, reference: chunk)
        return ChunkResult(input: chunk, reply: reply, output: accepted ? candidate : chunk, accepted: accepted)
    }

    /// What goes before the user message when there is context.
    private var contextPrefix: String { context.isEmpty ? "" : "<before>\n\(context)\n</before>\n" }

    /// The input budget for one chunk: the backend limit covers instructions, examples, prompt and a reply
    /// about as long as the prompt.
    private func chunkLimit(overhead: Int) -> Int {
        guard let backendLimit = backend.maxPromptCharacters else { return maxChunkCharacters }
        let wrapper = 120
        let budget = (backendLimit - overhead - wrapper) / 2
        return max(40, min(maxChunkCharacters, budget))
    }

    /// Removes what models wrap around an answer: a think block, transcript tags, surrounding quotes.
    public static func stripWrappers(_ reply: String) -> String {
        var text = reply
        if let close = text.range(of: "</think>") {
            text = String(text[close.upperBound...])
        }
        text = text.replacingOccurrences(of: "<transcript>", with: "")
            .replacingOccurrences(of: "</transcript>", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let quotePairs: [(Character, Character)] = [("\"", "\""), ("“", "”"), ("„", "“")]
        if text.count >= 2, let first = text.first, let last = text.last,
           quotePairs.contains(where: { $0.0 == first && $0.1 == last }) {
            text = String(text.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return text
    }
}
