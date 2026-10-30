import CoreFoundation
import Foundation

// MARK: - Session contract

/// One piece of context added to an ``LLMSession``: instructions and examples once, first; then streamed
/// text, which the next turn sends together with its request.
public enum LLMSessionChunk: Sendable, Hashable {
    /// The system instructions. At most once, before anything else.
    case instructions(String)
    /// An example exchange shown before the real conversation. Only before any text or turn.
    case example(LLMExample)
    /// Streamed context (for example ASR text or field changes), joined verbatim into the next user turn.
    case text(String)
}

/// Why a session refused a chunk or a reply.
public enum LLMSessionError: Error, Sendable, Hashable {
    /// The model's reply is not exactly the requested schema. Nothing is guessed from it.
    case invalidStructuredOutput(String)
    /// A chunk came in an order the contract does not allow (instructions twice, an example after text).
    case chunkOutOfOrder(String)
    /// The session was closed, or its model resources were released (memory pressure, model change).
    case closed
}

/// What a session's transcript costs, in tokens. `head` is the instructions and examples, which trimming
/// never drops; `history` is the turns and the pending text.
public struct LLMTokenUsage: Sendable, Hashable {
    public var head: Int
    public var history: Int
    public var total: Int { head + history }
    public init(head: Int, history: Int) { self.head = head; self.history = history }
}

/// A conversation with a language model that keeps its state across turns: a backend reuses what it
/// already processed (Foundation Models' session, ANEMLL's `MLState`, MLX's KV cache), so a turn only
/// processes what is new. Created by ``LLMBackend/makeSession()``; one caller at a time.
///
/// Context is scrolled, not grown without end: compare ``usage()`` with ``tokenBudget`` and
/// ``trim(keepingSuffix:)`` the history. After a trim the next turn processes the kept transcript again,
/// reusing at most what the backend's state still shares with it (at least the head where it can).
public protocol LLMSession: AnyObject, Sendable {
    /// Tokens the whole transcript may hold (instructions, examples, turns, pending text), with the room for
    /// a reply already taken off the model's context window.
    var tokenBudget: Int { get }

    /// The transcript's current size, counted with the backend's tokenizer (or its best estimate).
    func usage() async throws -> LLMTokenUsage

    /// Adds context. Text is held until the next ``respond(to:)``.
    func append(_ chunk: LLMSessionChunk) async throws

    /// Sends the pending text and `request` as the next user turn and returns the model's reply, which the
    /// transcript keeps.
    func respond(to request: String) async throws -> String

    /// Like ``respond(to:)``, with the reply constrained to (or, where the backend cannot constrain it,
    /// strictly checked against) `Output.llmSchema`. A reply that is not exactly the schema throws
    /// ``LLMSessionError/invalidStructuredOutput(_:)``.
    func respondStructured<Output: LLMStructuredOutput>(_ type: Output.Type, to request: String) async throws -> Output

    /// Drops the oldest history until it is at most `tokens` tokens, keeping the instructions and examples:
    /// whole turns first, then the front of the pending text.
    func trim(keepingSuffix tokens: Int) async throws

    /// Processes the transcript so far (normally the head: instructions and examples) into the backend's
    /// state without a reply, so the next turn only processes what follows. A warm session stays warm until
    /// a trim, an error or a release resets it. Best effort where the backend cannot prefill on its own.
    func warm() async throws

    /// Ends the session and releases its state and any lease it holds. Later calls throw
    /// ``LLMSessionError/closed``.
    func close() async
}

// MARK: - Transcript bookkeeping shared by the backends

/// A session's transcript as plain values: what every backend renders, counts and trims.
public struct LLMTranscript: Sendable, Hashable {
    /// One finished exchange.
    public struct Turn: Sendable, Hashable {
        public var user: String
        public var assistant: String
        /// Text the model saw with this turn beyond `user` (a schema the backend put in the prompt): counted,
        /// never rendered.
        public var counted: String
        public init(user: String, assistant: String, counted: String = "") {
            self.user = user; self.assistant = assistant; self.counted = counted
        }
    }

    /// Template tokens a turn costs beyond its text (role markers, separators), for counting.
    public static let turnOverhead = 8

    public private(set) var instructions = ""
    public private(set) var examples: [LLMExample] = []
    public private(set) var turns: [Turn] = []
    /// Text appended since the last turn.
    public private(set) var pending = ""
    private var hasInstructions = false
    private var lastConsumed = ""

    public init() {}

    public mutating func append(_ chunk: LLMSessionChunk) throws {
        switch chunk {
        case .instructions(let text):
            guard !hasInstructions, examples.isEmpty, turns.isEmpty, pending.isEmpty else {
                throw LLMSessionError.chunkOutOfOrder("Instructions come once, before anything else.")
            }
            instructions = text; hasInstructions = true
        case .example(let example):
            guard turns.isEmpty, pending.isEmpty else {
                throw LLMSessionError.chunkOutOfOrder("Examples come before any text or turn.")
            }
            examples.append(example)
        case .text(let text):
            pending += text
        }
    }

    /// The user message the next turn sends: the pending text, then the request.
    public func message(for request: String) -> String {
        if pending.isEmpty { return request }
        if request.isEmpty { return pending }
        return pending + "\n\n" + request
    }

    /// Records a finished turn and clears the pending text it carried.
    public mutating func record(user: String, assistant: String) {
        record(user: user, assistant: assistant, consumed: pending)
    }

    /// Records a finished turn that sent `consumed` (the pending text when the turn began). Only that prefix
    /// leaves the pending text: text appended while the turn ran stays for the next one.
    public mutating func record(user: String, assistant: String, consumed: String, counted: String = "") {
        turns.append(Turn(user: user, assistant: assistant, counted: counted))
        let scalars = pending.unicodeScalars
        if scalars.starts(with: consumed.unicodeScalars) {
            pending = String(String.UnicodeScalarView(scalars.dropFirst(consumed.unicodeScalars.count)))
        } else {
            pending = ""  // Not this turn's text any more (cannot happen with one caller at a time).
        }
        lastConsumed = consumed
    }

    /// After a trim of a copy taken before an `await`: adds the text appended to `live` since `original` was
    /// copied (appends do not wait for a count), so the trimmed transcript loses nothing streamed in meanwhile.
    public mutating func carryAppends(from live: LLMTranscript, since original: LLMTranscript) throws {
        let now = live.pending.unicodeScalars, before = original.pending.unicodeScalars
        guard now.count > before.count, now.starts(with: before) else { return }
        try append(.text(String(String.UnicodeScalarView(now.dropFirst(before.count)))))
    }

    /// Takes back the last recorded turn (a reply that failed its schema): its pending text is pending again,
    /// before anything appended since.
    public mutating func revertLastTurn() {
        guard !turns.isEmpty else { return }
        turns.removeLast()
        pending = lastConsumed + pending
        lastConsumed = ""
    }

    public func usage(count: (String) async throws -> Int) async rethrows -> LLMTokenUsage {
        var head = try await count(instructions)
        for example in examples { head += try await Self.cost(Turn(user: example.user, assistant: example.assistant), count) }
        var history = try await count(pending)
        for turn in turns { history += try await Self.cost(turn, count) }
        return LLMTokenUsage(head: head, history: history)
    }

    /// Drops whole turns from the front, then cuts the pending text from the front (at a Character
    /// boundary), until the history is at most `tokens`. Returns whether anything changed.
    public mutating func trim(keepingSuffix tokens: Int, count: (String) async throws -> Int) async rethrows -> Bool {
        let limit = max(0, tokens)
        var costs: [Int] = []
        for turn in turns { costs.append(try await Self.cost(turn, count)) }
        let pendingCost = try await count(pending)
        var total = costs.reduce(pendingCost, +)
        guard total > limit else { return false }
        var dropped = 0
        while total > limit, dropped < costs.count { total -= costs[dropped]; dropped += 1 }
        turns.removeFirst(dropped)
        if total > limit { pending = try await Self.tail(of: pending, within: limit, count: count) }
        return true
    }

    private static func cost(_ turn: Turn, _ count: (String) async throws -> Int) async rethrows -> Int {
        let counted = turn.counted.isEmpty ? 0 : try await count(turn.counted)
        return try await count(turn.user) + count(turn.assistant) + counted + turnOverhead
    }

    /// The longest suffix of `text` that counts at most `limit` tokens.
    private static func tail(of text: String, within limit: Int, count: (String) async throws -> Int) async rethrows -> String {
        let characters = Array(text)
        var low = 0, high = characters.count  // the cut position; `high` (empty suffix) always fits
        while low < high {
            let mid = (low + high) / 2
            if try await count(String(characters[mid...])) <= limit { high = mid } else { low = mid + 1 }
        }
        return String(characters[low...])
    }
}

// MARK: - Structured output

/// The shape a structured reply must have. Deliberately small: small objects, arrays and scalar fields.
public indirect enum LLMSchema: Sendable, Hashable {
    case string(description: String? = nil)
    case integer(description: String? = nil)
    case array(of: LLMSchema, description: String? = nil)
    /// An object with exactly these properties, all required.
    case object(name: String, description: String? = nil, properties: [LLMSchemaProperty])
}

public struct LLMSchemaProperty: Sendable, Hashable {
    public var name: String
    public var schema: LLMSchema
    public init(_ name: String, _ schema: LLMSchema) { self.name = name; self.schema = schema }
}

/// A type a session can answer with: decodable from JSON that matches ``llmSchema`` exactly.
public protocol LLMStructuredOutput: Decodable, Sendable {
    static var llmSchema: LLMSchema { get }
}

extension Array: LLMStructuredOutput where Element: LLMStructuredOutput {
    public static var llmSchema: LLMSchema { .array(of: Element.llmSchema) }
}

/// The strict decoder every backend uses for structured replies. Whitespace around the JSON and one
/// enclosing Markdown code fence are allowed; anything else that is not exactly the schema (prose, extra or
/// missing keys, a fraction for an integer, `null`) is rejected, never repaired.
public enum LLMStructuredDecoding {
    public static func decode<Output: LLMStructuredOutput>(_ type: Output.Type, from reply: String) throws -> Output {
        let json = unfenced(reply)
        guard let data = json.data(using: .utf8), !json.isEmpty,
              let value = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
            throw LLMSessionError.invalidStructuredOutput("The reply is not JSON.")
        }
        try validate(value, against: Output.llmSchema, at: "$")
        do { return try JSONDecoder().decode(Output.self, from: data) }
        catch { throw LLMSessionError.invalidStructuredOutput("The reply does not decode: \(error)") }
    }

    /// A JSON Schema rendering of `schema`, for backends that cannot constrain generation.
    public static func jsonSchema(_ schema: LLMSchema) -> String {
        let object = schemaObject(schema)
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }

    /// The request suffix that asks a free-text model for exactly `schema`.
    public static func instruction(for schema: LLMSchema) -> String {
        "Answer with JSON only, no other text, matching this JSON Schema: " + jsonSchema(schema)
    }

    private static func unfenced(_ reply: String) -> String {
        var text = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.hasPrefix("```"), text.hasSuffix("```"), text.count >= 6 else { return text }
        text = String(text.dropFirst(3).dropLast(3))
        if let newline = text.firstIndex(of: "\n") {
            let tag = text[..<newline].trimmingCharacters(in: .whitespaces)
            if tag.isEmpty || tag.allSatisfy({ $0.isLetter }) { text = String(text[text.index(after: newline)...]) }
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func validate(_ value: Any, against schema: LLMSchema, at path: String) throws {
        func fail(_ what: String) -> LLMSessionError { .invalidStructuredOutput("\(path): \(what)") }
        switch schema {
        case .string:
            guard value is String else { throw fail("expected a string") }
        case .integer:
            guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                  !CFNumberIsFloatType(number) else { throw fail("expected an integer") }
        case .array(let element, _):
            guard let array = value as? [Any] else { throw fail("expected an array") }
            for (index, item) in array.enumerated() { try validate(item, against: element, at: "\(path)[\(index)]") }
        case .object(_, _, let properties):
            guard let object = value as? [String: Any] else { throw fail("expected an object") }
            let expected = Set(properties.map(\.name))
            guard Set(object.keys) == expected else { throw fail("expected exactly the keys \(expected.sorted())") }
            for property in properties {
                try validate(object[property.name] as Any, against: property.schema, at: "\(path).\(property.name)")
            }
        }
    }

    private static func schemaObject(_ schema: LLMSchema) -> [String: Any] {
        func described(_ base: [String: Any], _ description: String?) -> [String: Any] {
            guard let description else { return base }
            return base.merging(["description": description]) { first, _ in first }
        }
        switch schema {
        case .string(let description): return described(["type": "string"], description)
        case .integer(let description): return described(["type": "integer"], description)
        case .array(let element, let description):
            return described(["type": "array", "items": schemaObject(element)], description)
        case .object(_, let description, let properties):
            var fields: [String: Any] = [:]
            for property in properties { fields[property.name] = schemaObject(property.schema) }
            return described([
                "type": "object", "properties": fields, "required": properties.map(\.name),
                "additionalProperties": false,
            ], description)
        }
    }
}

// MARK: - Session ownership

/// The sessions a resource owner handed out, so releasing the resources (memory pressure, a model change,
/// the end of a run) ends every session still open on them. Holds sessions weakly.
public actor LLMSessionSet {
    private struct Entry { weak var session: (any LLMSession)? }
    private var entries: [ObjectIdentifier: Entry] = [:]

    public init() {}

    public func insert(_ session: any LLMSession) {
        entries = entries.filter { $0.value.session != nil }
        entries[ObjectIdentifier(session)] = Entry(session: session)
    }

    public func remove(_ session: any LLMSession) { entries[ObjectIdentifier(session)] = nil }

    public var count: Int { entries.values.filter { $0.session != nil }.count }

    /// Closes every open session and forgets them.
    public func closeAll() async {
        let open = entries.values.compactMap(\.session)
        entries = [:]
        for session in open { await session.close() }
    }
}

/// Serializes a session actor's turns, counts and trims (an actor alone interleaves them at every `await`),
/// while ``LLMSession/append(_:)`` stays open: text streamed in during a turn waits for the next one.
public struct LLMTurnGate: Sendable {
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    public init() {}
    /// Takes the gate if it is free.
    public mutating func enter() -> Bool {
        if busy { return false }
        busy = true
        return true
    }
    /// Queues `waiter`; it resumes holding the gate.
    public mutating func wait(_ waiter: CheckedContinuation<Void, Never>) { waiters.append(waiter) }
    /// Hands the gate to the next waiter, or frees it.
    public mutating func leave() {
        if waiters.isEmpty { busy = false } else { waiters.removeFirst().resume() }
    }
}

/// What a backend measured for a session's last turn or warm-up, where it can tell (probes and logs).
public struct LLMTurnMetrics: Sendable, Hashable {
    /// The turn's full prompt, in tokens.
    public var promptTokens: Int?
    /// Prompt tokens actually prefilled (the rest came from the kept state).
    public var prefilledTokens: Int?
    public var prefillSeconds: Double?
    public init(promptTokens: Int? = nil, prefilledTokens: Int? = nil, prefillSeconds: Double? = nil) {
        self.promptTokens = promptTokens; self.prefilledTokens = prefilledTokens; self.prefillSeconds = prefillSeconds
    }
}

/// A session that reports ``LLMTurnMetrics``.
public protocol LLMSessionMetrics: LLMSession {
    func lastTurnMetrics() async -> LLMTurnMetrics?
    func lastWarmMetrics() async -> LLMTurnMetrics?
}
