import Foundation
import LegatoClaude
import LegatoComposerDoc
import LegatoRoom

/// What the model is shown of the field: verified text around the cursor, as the keyboard read it. Only text in here
/// can ever be edited; whatever was not read stays as it is by construction.
public struct InstructionContext: Sendable, Equatable {
    /// From where the read stopped down to the cursor.
    public var above: String
    /// From the cursor down, as far as the field showed it or a read down verified it.
    public var below: String
    /// The selected text, if any: then only the selection can be edited.
    public var selection: String?
    /// Characters at the end of `above` that were dictated in this keyboard session (0: none).
    public var sessionLength: Int
    /// The field has text above / below the shown part (or may have: below the host's window nothing is known).
    public var moreAbove: Bool
    public var moreBelow: Bool
    /// Reading further up / down is not wanted or not possible (the field's start or end, a structural stop, the cap).
    public var aboveFinal: Bool
    public var belowFinal: Bool
    /// The shown text reaches the start / end of the user's text: the field's own, or a structural stop (a quote, a
    /// signature). Not after the cap. A scope that runs to that end (`above`, `all`) is complete only then.
    public var aboveComplete: Bool
    public var belowComplete: Bool
    public init(above: String = "", below: String = "", selection: String? = nil, sessionLength: Int = 0,
                moreAbove: Bool = false, moreBelow: Bool = false, aboveFinal: Bool = true, belowFinal: Bool? = nil,
                aboveComplete: Bool? = nil, belowComplete: Bool? = nil) {
        self.above = above; self.below = below; self.selection = selection?.isEmpty == false ? selection : nil
        self.sessionLength = min(max(0, sessionLength), above.count)
        self.moreAbove = moreAbove; self.moreBelow = moreBelow; self.aboveFinal = aboveFinal
        self.belowFinal = belowFinal ?? !moreBelow
        self.aboveComplete = aboveComplete ?? !moreAbove
        self.belowComplete = belowComplete ?? !moreBelow
    }
    /// More can be read above (`read_more`, or a read up to the cap).
    public var canReadAbove: Bool { selection == nil && moreAbove && !aboveFinal }
    /// More can be read below (a read to the cap reads down after reading up).
    public var canReadBelow: Bool { selection == nil && moreBelow && !belowFinal }
    public var session: String { String(above.suffix(sessionLength)) }
    /// No text to work on: nothing selected, and nothing around the cursor.
    public var isEmpty: Bool { selection == nil && (above + below).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !moreAbove && !moreBelow }
    /// The scopes this context offers, smallest first.
    public var scopes: [InstructionScope] {
        if selection != nil { return [.selection] }
        var scopes: [InstructionScope] = []
        if sessionLength > 0 { scopes.append(.session) }
        // `above` only with text before the cursor: an empty one would land its rewrite as an insert at the cursor.
        if !(above + below).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            scopes.append(.paragraph)
            if !above.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { scopes.append(.above) }
            scopes.append(.all)
        }
        return scopes
    }
}

/// The part of the field a reply replaces (the reply's `SCOPE:` header).
public enum InstructionScope: String, CaseIterable, Sendable, Equatable {
    case selection, session, paragraph, above, all

    /// The scope's text around the cursor, or nil when this context has no such scope. `before` ends at the cursor,
    /// `after` starts there; a selection is the selected text.
    public func range(in context: InstructionContext) -> InstructionScopeRange? {
        if self == .selection { return context.selection.map { InstructionScopeRange(before: "", after: "", selected: $0) } }
        guard context.selection == nil, context.scopes.contains(self) else { return nil }
        switch self {
        case .selection: return nil
        case .session: return InstructionScopeRange(before: context.session, after: "")
        case .paragraph:
            let start = context.above.lastIndex(where: \.isNewline).map { context.above.index(after: $0) } ?? context.above.startIndex
            let end = context.below.firstIndex(where: \.isNewline) ?? context.below.endIndex
            return InstructionScopeRange(before: String(context.above[start...]), after: String(context.below[..<end]))
        case .above: return InstructionScopeRange(before: context.above, after: "")
        case .all: return InstructionScopeRange(before: context.above, after: context.below)
        }
    }

    /// A reply for this scope needs more than the model was shown: the read to make before asking again.
    public func read(for context: InstructionContext) -> InstructionRead? {
        switch self {
        case .selection, .session: return nil
        case .paragraph:
            // The paragraph runs on past the shown text: below only a read to the cap reads down.
            if context.canReadBelow, !context.below.contains(where: \.isNewline) { return .toCap }
            return context.canReadAbove && !context.above.contains(where: \.isNewline) ? .block : nil
        case .above: return context.canReadAbove ? .toCap : nil
        case .all: return context.canReadAbove || context.canReadBelow ? .toCap : nil
        }
    }

    /// The scope reaches past what was read (`above` or `all` cut by the cap or not read to its end): landing it would
    /// claim the whole text while editing a part of it.
    public func isPartial(in context: InstructionContext) -> Bool {
        switch self {
        case .selection, .session, .paragraph: false
        case .above: !context.aboveComplete
        case .all: !context.aboveComplete || !context.belowComplete
        }
    }
}

public struct InstructionScopeRange: Sendable, Equatable {
    public var before: String
    public var after: String
    public var selected: String?
    public init(before: String, after: String, selected: String? = nil) { self.before = before; self.after = after; self.selected = selected }
    public var text: String { selected ?? (before + after) }

    /// The reply's text as the scope's replacement: the scope's own leading and trailing whitespace stays. An empty
    /// reply deletes the scope, whitespace and all.
    public func target(for reply: String) -> String {
        let text = self.text
        let body = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return "" }
        let lead = text.prefix(while: \.isWhitespace), trail = String(text.reversed().prefix(while: \.isWhitespace).reversed())
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return lead + body }
        return lead + body + trail
    }
}

/// What a reply asks the field to read before it can be answered.
public enum InstructionRead: String, Sendable, Equatable {
    /// One more block above (`read_more`).
    case block
    /// Everything above up to the cap.
    case toCap
}

/// Cheap checks on a reply before it lands: a remark instead of text, and a rewrite of more (or of another part) than
/// the instruction is about. Both err on the side of landing: a whole-text rewrite ("make this more formal") passes.
enum InstructionGuard {
    /// One parenthesised, bracketed or starred remark on one line: "(The field is emptied.)", "[deleted]".
    static func isRemark(_ text: String) -> Bool {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count >= 3, !text.contains(where: \.isNewline) else { return false }
        for (open, close) in [("(", ")"), ("[", "]"), ("*", "*")] as [(Character, Character)] where text.first == open && text.last == close {
            let inner = text.dropFirst().dropLast()
            if !inner.contains(open), !inner.contains(close) { return true }
        }
        return false
    }

    /// The target is no edit of the scope it replaces: it resembles another shown paragraph much more than the scope
    /// (the cursor's paragraph replaced by a rewrite of the one above), or an instruction about one part (a paragraph,
    /// a sentence) rewrote nearly every paragraph of a long `above`/`all`.
    static func overreaches(instruction: String, scope: InstructionScope, range: InstructionScopeRange, target: String,
                            context: InstructionContext) -> Bool {
        guard range.selected == nil, !target.isEmpty else { return false }
        if scope != .all {
            let words = Self.words(target)
            let outside = String(context.above.dropLast(range.before.count)) + "\n" + String(context.below.dropFirst(range.after.count))
            // Against each other paragraph and all of them together (a rewrite of several put in this one's place).
            if words.count >= 6, let best = (paragraphs(outside) + [outside]).map({ containment(words, in: Self.words($0)) }).max() {
                let own = containment(words, in: Self.words(range.text))
                if best >= 0.6, best > own + 0.25 { return true }
            }
        }
        if scope == .above || scope == .all, range.text.count >= 400, isLocal(instruction) {
            let source = paragraphs(range.text)
            let kept = Set(paragraphs(target))
            if source.count >= 3, source.filter(kept.contains).count * 3 < source.count { return true }
        }
        return false
    }

    /// Names one part of the text ("the second paragraph", "the last sentence"), not all of it or each part.
    static func isLocal(_ instruction: String) -> Bool {
        let tokens = Set(instruction.lowercased().split(whereSeparator: { !$0.isLetter && $0 != "-" }).map(String.init))
        let parts: Set<String> = ["paragraph", "sentence", "line", "word", "greeting", "salutation", "closing", "sign-off", "signoff",
                                  "subject", "bullet", "intro", "introduction", "ending", "opening", "absatz", "satz", "zeile", "wort",
                                  "anrede", "grußformel", "einleitung", "schluss", "schlusssatz"]
        let whole: Set<String> = ["each", "every", "all", "whole", "entire", "everything", "paragraphs", "sentences", "lines",
                                  "jeden", "jede", "jeder", "alle", "ganze", "ganzen", "gesamte", "gesamten", "absätze", "sätze", "zeilen"]
        return !tokens.isDisjoint(with: parts) && tokens.isDisjoint(with: whole)
    }

    static func paragraphs(_ text: String) -> [String] {
        text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// Content words (four letters and up: short function words say little about which paragraph this is).
    static func words(_ text: String) -> Set<String> {
        Set(text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init).filter { $0.count >= 4 })
    }

    static func containment(_ words: Set<String>, in other: Set<String>) -> Double {
        words.isEmpty ? 0 : Double(words.intersection(other).count) / Double(words.count)
    }
}

/// The model's plain-text reply: `SCOPE: <name>` on the first line, then the new text for that scope.
public enum InstructionReply {
    public enum Header: Sendable, Equatable {
        case scope(InstructionScope)
        /// A `SCOPE:` header naming no known scope.
        case unknown(String)
        /// No `SCOPE:` header at all.
        case malformed
    }

    /// The header of a first line (Markdown emphasis or code marks around it are tolerated).
    public static func header(_ line: String) -> Header {
        let trimmed = line.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "*`_#")))
        guard trimmed.lowercased().hasPrefix("scope:") || trimmed.lowercased().hasPrefix("scope :") else { return .malformed }
        let value = trimmed.drop(while: { $0 != ":" }).dropFirst()
            .trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "*`_.\"'<>[]")))
            .lowercased()
        return InstructionScope(rawValue: value).map(Header.scope) ?? .unknown(value)
    }

    /// The header and the text after it. A model that writes a sentence before the header (small models do, before
    /// a tool call) is read from its first `SCOPE:` line. The body loses a wrapping code fence and any copied marker.
    public static func parse(_ reply: String) -> (header: Header, body: String) {
        guard let (header, end) = firstHeader(in: reply) else { return (.malformed, "") }
        var body = end < reply.endIndex ? String(reply[reply.index(after: end)...]) : ""
        let lines = body.split(separator: "\n", omittingEmptySubsequences: false)
        if let first = lines.first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }), first.hasPrefix("```"),
           let last = lines.last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }), last.hasPrefix("```"), lines.count > 2 {
            let inner = lines.drop(while: { !$0.hasPrefix("```") }).dropFirst()
            body = inner.reversed().drop(while: { !$0.hasPrefix("```") }).dropFirst().reversed().joined(separator: "\n")
        }
        for marker in ["‸", "«", "»"] { body = body.replacingOccurrences(of: marker, with: "") }
        return (header, DocPresenter.strip(body))
    }

    /// The first complete line that is a `SCOPE:` header, and where that line ends; nil while none is complete.
    public static func firstHeader(in text: String) -> (Header, String.Index)? {
        var start = text.startIndex
        while true {
            let end = text[start...].firstIndex(where: \.isNewline) ?? text.endIndex
            let header = header(String(text[start..<end]))
            if header != .malformed { return (header, end) }
            guard end < text.endIndex else { return nil }
            start = text.index(after: end)
        }
    }
}

/// An instruction's result: the scope and its new text, against the context it was answered from.
public struct InstructionOutcome: Sendable, Equatable {
    public var scope: InstructionScope
    public var range: InstructionScopeRange
    /// The scope's replacement (its own surrounding whitespace kept).
    public var target: String
    public var context: InstructionContext
    /// Field reads the run made after the first context (`read_more` calls and reads up to the cap).
    public var reads: Int
}

public enum InstructionFailure: Error, Sendable, Equatable {
    case missingKey
    case provider(String)
    /// The reply had no `SCOPE:` header.
    case malformedReply
    case unknownScope(String)
    /// The reply named a scope this context does not offer (`selection` without one, or another scope with one).
    case unavailableScope(InstructionScope)
    /// An empty reply for a scope that is empty already.
    case emptyText
    /// The new text is the scope's text: nothing to edit.
    case unchanged
    /// The field has no text, and nothing is selected.
    case noText
    /// The reply is a remark about the text ("(The field is emptied.)"), not text.
    case commentary
    /// `above` or `all` reaches past what could be read (the cap): only part of it was shown.
    case partialScope(InstructionScope)
    /// The reply rewrote much more than the instruction is about, or put another part of the text in this scope's place.
    case overreach
    /// The keyboard could not read the field (`message` says why).
    case read(String)

    /// For the strip: what happened, in the user's terms. Nothing was edited in every case.
    public var message: String {
        switch self {
        case .missingKey: "Add your Claude API key in the Legato app to use instructions."
        case .provider: "The instruction didn't go through. Try again."
        case .malformedReply, .unknownScope, .emptyText, .commentary: "The instruction gave no usable result. Nothing was changed."
        case .unavailableScope(let scope): scope == .selection ? "Select the text first, then say the instruction."
            : "With text selected, an instruction edits only the selection."
        case .unchanged: "Nothing to change for that instruction."
        case .noText: "There's no text to work on."
        case .partialScope: "The text is too long to edit here. Select the part to change, then say the instruction."
        case .overreach: "The result changed more than the instruction asked for, so nothing was changed."
        case .read(let message): message
        }
    }

    /// Running the same instruction on the same text again could give another result.
    public var canRetry: Bool {
        switch self {
        case .unchanged, .noText, .partialScope, .unavailableScope, .missingKey: false
        case .provider, .malformedReply, .unknownScope, .emptyText, .commentary, .overreach, .read: true
        }
    }
}

/// Runs one spoken instruction against the field: the structural prefetch is the context, the reply is plain text
/// (`SCOPE:` header, then the new text), and one argument-free tool, `read_more()`, extends the context upward a block
/// at a time. A header naming a scope larger than what was shown stops the stream, has the field read up to the cap,
/// and asks again with that text (once). No line IDs and no edit tools: the app maps the scope to the field's text.
public struct InstructionRunner: Sendable {
    public typealias Reader = @Sendable (InstructionRead) async throws -> InstructionContext
    private let client: any MessagesStreaming
    private let model: @Sendable () -> ModelChoice
    private let personalPrompt: @Sendable () -> String
    private let vocabulary: @Sendable () async -> [String]
    /// `read_more` calls allowed per instruction (each costs a second or two of visible cursor movement).
    public static let maxReads = 2

    public init(client: any MessagesStreaming, model: @escaping @Sendable () -> ModelChoice,
                personalPrompt: @escaping @Sendable () -> String = { "" }, vocabulary: @escaping @Sendable () async -> [String] = { [] }) {
        self.client = client; self.model = model; self.personalPrompt = personalPrompt; self.vocabulary = vocabulary
    }

    /// The instruction's words, with `DocPresenter`'s confidence marks on the words the recognizer was unsure of.
    public static func present(_ words: [Word]) -> String {
        words.map { word in
            if let c = word.confidence, c < 0.9 { return "⟨\(word.text)|\(String(format: "%.2f", c))⟩" }
            return word.text
        }.joined(separator: " ")
    }

    /// - Parameters:
    ///   - instruction: the spoken instruction (confidence marks allowed).
    ///   - read: reads more of the field; returns the whole context grown by that read.
    public func run(instruction: String, context: InstructionContext, read: Reader) async throws -> InstructionOutcome {
        guard !context.isEmpty else { throw InstructionFailure.noText }
        let model = model()
        let system = Self.system(personal: personalPrompt(), vocabulary: await vocabulary())
        var context = context
        var reads = 0
        var reasked = false
        ask: while true {
            var messages: [JSONValue] = [.object(["role": .string("user"), "content": .string(Self.prompt(instruction: instruction, context: context))])]
            for _ in 0...Self.maxReads {
                try Task.checkCancellation()
                let offersRead = context.canReadAbove && reads < Self.maxReads
                let request = try Self.request(model: model, system: system, messages: messages, tools: offersRead)
                var text = ""
                var blocks: [Int: JSONValue] = [:]
                var inputs: [Int: String] = [:]
                var headerSeen = false
                do {
                    for try await event in client.stream(request: request) {
                        try Task.checkCancellation()
                        guard let value = try? JSONDecoder().decode(JSONValue.self, from: Data(event.data.utf8)) else { continue }
                        guard case .number(let raw) = value["index"], raw >= 0, raw < 1000 else { continue }
                        let index = Int(raw)
                        if let block = value["content_block"] { blocks[index] = block }
                        guard let delta = value["delta"] else { continue }
                        if case .string(let fragment) = delta["partial_json"] { inputs[index, default: ""] += fragment }
                        // Thinking blocks go back with a tool result as they came (their text and signature).
                        if case .object(var block) = blocks[index] {
                            for key in ["text", "thinking", "signature"] {
                                guard case .string(let fragment) = delta[key] else { continue }
                                if case .string(let old) = block[key] { block[key] = .string(old + fragment) } else { block[key] = .string(fragment) }
                            }
                            blocks[index] = .object(block)
                        }
                        if case .string(let fragment) = delta["text"] {
                            text += fragment
                            // The header decides early: a scope bigger than what was shown is read now, not after the whole rewrite.
                            if !headerSeen, text.contains(where: \.isNewline),
                               let (header, end) = InstructionReply.firstHeader(in: text), end < text.endIndex {
                                headerSeen = true
                                if !reasked, case .scope(let scope) = header, let more = scope.read(for: context) {
                                    context = try await readField(more, read: read)
                                    reads += 1; reasked = true
                                    continue ask
                                }
                            }
                        }
                    }
                } catch let error as MessagesStreamError {
                    if case .missingKey = error { throw InstructionFailure.missingKey }
                    throw InstructionFailure.provider(String(describing: error).prefix(300).description)
                } catch let error as InstructionFailure { throw error
                } catch is CancellationError { throw CancellationError()
                } catch { throw InstructionFailure.provider(String(describing: type(of: error))) }

                let calls = blocks.keys.sorted().compactMap { key -> (Int, String)? in
                    guard case .string("tool_use") = blocks[key]?["type"], case .string(let id) = blocks[key]?["id"] else { return nil }
                    return (key, id)
                }
                guard !calls.isEmpty else {
                    // A reply whose header never had a line after it (a deletion: "SCOPE: all" alone) is read for here.
                    if !headerSeen, !reasked, let (header, _) = InstructionReply.firstHeader(in: text), case .scope(let scope) = header,
                       let more = scope.read(for: context) {
                        context = try await readField(more, read: read)
                        reads += 1; reasked = true
                        continue ask
                    }
                    return try Self.outcome(reply: text, context: context, reads: reads, instruction: instruction)
                }
                // `read_more()`: one more block above, as the tool's result. A failed read is a tool error, never partial text.
                var content: [JSONValue] = []
                for key in blocks.keys.sorted() {
                    guard case .object(var block) = blocks[key] else { continue }
                    if case .string("tool_use") = block["type"] {
                        let json = inputs[key]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                        block["input"] = json.isEmpty ? .object([:]) : ((try? JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))) ?? .object([:]))
                    }
                    content.append(.object(block))
                }
                messages.append(.object(["role": .string("assistant"), "content": .array(content)]))
                var results: [JSONValue] = []
                for (_, id) in calls {
                    var result: String, isError = false
                    if context.canReadAbove, reads < Self.maxReads {
                        do {
                            let shown = context.above
                            context = try await readField(.block, read: read)
                            reads += 1
                            let new = String(context.above.dropLast(shown.count))
                            result = "{\"text\": \(Self.json(new)), \"more_remains\": \(context.canReadAbove ? "true" : "false")}"
                        } catch let failure as InstructionFailure {
                            if case .read(let message) = failure { result = "Read failed: \(message)" } else { throw failure }
                            isError = true
                        }
                    } else {
                        result = "Nothing more can be read above."; isError = true
                    }
                    results.append(.object(["type": .string("tool_result"), "tool_use_id": .string(id), "content": .string(result), "is_error": .bool(isError)]))
                }
                messages.append(.object(["role": .string("user"), "content": .array(results)]))
            }
            throw InstructionFailure.malformedReply
        }
    }

    private func readField(_ kind: InstructionRead, read: Reader) async throws -> InstructionContext {
        do { return try await read(kind) }
        catch let failure as InstructionFailure { throw failure }
        catch is CancellationError { throw CancellationError() }
        catch { throw InstructionFailure.read(String(describing: error)) }
    }


    /// The reply against the context: the scope's range and its replacement, or why nothing is edited.
    public static func outcome(reply: String, context: InstructionContext, reads: Int = 0, instruction: String = "") throws -> InstructionOutcome {
        let (header, body) = InstructionReply.parse(reply)
        let scope: InstructionScope
        switch header {
        case .malformed: throw InstructionFailure.malformedReply
        case .unknown(let name): throw InstructionFailure.unknownScope(name)
        case .scope(let value): scope = value
        }
        guard let range = scope.range(in: context) else {
            // Not offered: with a selection that is the user's to fix; otherwise the reply is unusable.
            throw scope == .selection || context.selection != nil ? InstructionFailure.unavailableScope(scope) : InstructionFailure.unknownScope(scope.rawValue)
        }
        let hasText = !range.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        // An empty body deletes the scope; an empty scope has nothing to delete.
        guard hasText || !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw InstructionFailure.emptyText }
        guard !scope.isPartial(in: context) else { throw InstructionFailure.partialScope(scope) }
        if hasText, InstructionGuard.isRemark(body), !InstructionGuard.isRemark(range.text) { throw InstructionFailure.commentary }
        let target = range.target(for: body)
        guard target != range.text else { throw InstructionFailure.unchanged }
        if InstructionGuard.overreaches(instruction: instruction, scope: scope, range: range, target: target, context: context) {
            throw InstructionFailure.overreach
        }
        return InstructionOutcome(scope: scope, range: range, target: target, context: context, reads: reads)
    }

    // MARK: Prompt

    public static func system(personal: String, vocabulary: [String]) -> String {
        var parts = [PromptLayers.instructionMode()]
        let personal = personal.trimmingCharacters(in: .whitespacesAndNewlines)
        if !personal.isEmpty { parts.append("Personal preferences:\n" + personal) }
        if !vocabulary.isEmpty { parts.append("Vocabulary spellings (use when context matches):\n" + vocabulary.prefix(200).joined(separator: ", ")) }
        return parts.joined(separator: "\n\n")
    }

    /// The user turn: the instruction, the field with the cursor (‸) and the selection («…») marked, and the scopes.
    public static func prompt(instruction: String, context: InstructionContext) -> String {
        var field = ""
        if context.moreAbove { field += "[text continues above, not read]\n" }
        field += context.above
        field += context.selection.map { "«\($0)»" } ?? "‸"
        field += context.below
        if context.moreBelow { field += "\n[text continues below, not read]" }
        var parts = ["<instruction>\n\(instruction)\n</instruction>", "<field>\n\(field)\n</field>"]
        if let selection = context.selection { parts.append("<selection>\n\(selection)\n</selection>") }
        if context.sessionLength > 0 { parts.append("<session>\n\(context.session)\n</session>") }
        // Each scope with what it holds, so the choice is made against the text it replaces, not its name.
        let scopes = context.scopes.compactMap { scope in scope.range(in: context).map { "- \(scope.rawValue): \(Self.preview($0.text))" } }
        parts.append(scopes.isEmpty ? "Offered scopes: none" : "Offered scopes (each replaces exactly this text):\n" + scopes.joined(separator: "\n"))
        return parts.joined(separator: "\n\n")
    }

    /// A scope's text in one short line: whole when short, else its start and end, with its length.
    static func preview(_ text: String) -> String {
        let flat = text.split(whereSeparator: \.isNewline).joined(separator: " / ").trimmingCharacters(in: .whitespaces)
        let shown = flat.count <= 70 ? flat : flat.prefix(35).trimmingCharacters(in: .whitespaces) + " … " + flat.suffix(30).trimmingCharacters(in: .whitespaces)
        return "\"\(shown)\" (\(text.count) characters)"
    }

    public static let readMoreTool: JSONValue = .object([
        "name": .string("read_more"),
        "description": .string("Shows one more block of the field's text above what you were shown. Returns {text, more_remains}. Call it only when the instruction needs text above that you cannot see."),
        "input_schema": .object(["type": .string("object"), "properties": .object([:])]),
    ])

    public static func request(model: ModelChoice, system: String, messages: [JSONValue], tools: Bool) throws -> Data {
        var fields: [String: JSONValue] = ["model": .string(model.rawValue), "max_tokens": .number(4096), "stream": .bool(true),
            // A rewrite needs no thinking: Haiku has it off. Sonnet 5.5 rejects `disabled` and thinks only between tool
            // calls (`between_tools`); Opus is adaptive at low effort (`ModelChoice.thinking`, as cleanup and the composer).
            "thinking": model.thinking, "system": .string(system), "messages": .array(messages),
            "cache_control": .object(["type": .string("ephemeral")])]
        if tools {
            fields["tools"] = .array([readMoreTool])
            fields["tool_choice"] = .object(["type": .string("auto")])
        }
        if model != .haiku { fields["output_config"] = .object(["effort": .string("low")]) }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(JSONValue.object(fields))
    }

    private static func json(_ text: String) -> String {
        (try? String(decoding: JSONEncoder().encode(text), as: UTF8.self)) ?? "\"\""
    }
}
