import Foundation
import LegatoCore
import Synchronization
import Testing
#if canImport(FoundationModels)
import FoundationModels
#endif
@testable import LegatoPostProcessing

/// Records what the stage sends, split by entry point, so the tests can tell turns from folded text.
private final class TurnRecordingBackend: LLMBackend {
    let id = "turns"
    let maxPromptCharacters: Int?
    private let reply: @Sendable (String) -> String
    private struct State { var instructions: [String] = []; var examples: [[LLMExample]] = []; var prompts: [String] = [] }
    private let state = Mutex(State())

    init(maxPromptCharacters: Int? = nil, reply: @escaping @Sendable (String) -> String) {
        self.maxPromptCharacters = maxPromptCharacters
        self.reply = reply
    }

    var availability: LLMAvailability { get async { .available } }
    var instructions: [String] { state.withLock { $0.instructions } }
    var examples: [[LLMExample]] { state.withLock { $0.examples } }
    var prompts: [String] { state.withLock { $0.prompts } }

    func respond(instructions: String, prompt: String) async throws -> String {
        try await respond(instructions: instructions, examples: [], prompt: prompt)
    }

    func respond(instructions: String, examples: [LLMExample], prompt: String) async throws -> String {
        state.withLock { $0.instructions.append(instructions); $0.examples.append(examples); $0.prompts.append(prompt) }
        return reply(prompt)
    }
}

/// A backend that only knows the original two-argument entry point.
private final class LegacyBackend: LLMBackend {
    let id = "legacy"
    let maxPromptCharacters: Int? = nil
    private struct State { var instructions: [String] = []; var prompts: [String] = [] }
    private let state = Mutex(State())
    var availability: LLMAvailability { get async { .available } }
    var instructions: [String] { state.withLock { $0.instructions } }
    var prompts: [String] { state.withLock { $0.prompts } }

    func respond(instructions: String, prompt: String) async throws -> String {
        state.withLock { $0.instructions.append(instructions); $0.prompts.append(prompt) }
        return "ok"
    }
}

private let en = Locale(identifier: "en-US")
private let de = Locale(identifier: "de-DE")

/// A prompt whose every part is recognisable in the backend's input.
private func probe(extract: @escaping @Sendable (String) -> String = { $0 }) -> CleanupPrompt {
    CleanupPrompt(
        name: "probe",
        instructions: { locale, vocabulary in "SYSTEM[\(locale.identifier)|\(vocabulary.joined(separator: ","))]" },
        examples: { locale in
            [LLMExample(user: "EX-IN-\(locale.identifier)", assistant: "EX-OUT-\(locale.identifier)")]
        },
        userMessage: { text, locale, vocabulary in "USER[\(locale.identifier)|\(vocabulary.joined(separator: ","))]\(text)" },
        extractText: extract)
}

@Suite("CleanupPrompt")
struct CleanupPromptTests {
    @Test(arguments: CleanupStyle.allCases)
    func firstCompleteOuterBlockIgnoresTrailingEmptyWrappers(style: CleanupStyle) async throws {
        let expected = "Also, ich bleibe lieber hier und schaue noch ein bisschen auf den Regen."
        let backend = TurnRecordingBackend { _ in "<text>\(expected)</text>\n\n<text>\n</text>" }
        let stage = LLMCleanupStage(backend: backend, prompt: style.prompt, acceptance: .promptLed)
        let result = try await stage.process("also ich bleibe lieber hier und schaue noch ein bisschen auf den regen", locale: de)
        #expect(result == expected)
    }

    @Test func balancedNestedTextTagsRemainLiteralInsideTheFirstOuterBlock() {
        let expected = "# Prompt\n\nUse `<text>first <text>inner</text></text>`.\n\n- Keep 🙂."
        let reply = "<text>\n\(expected)\n</text>\n<text></text>"
        #expect(CleanupPrompt.extractTaggedText(reply) == expected)
    }

    @Test func incompleteOuterBlockKeepsAllRemainingContentIncludingNestedTags() {
        let expected = "# Prompt\n\nLiteral <text>nested</text>"
        #expect(CleanupPrompt.extractTaggedText("<text>\n\(expected)\n") == expected)
    }

    @Test func anEmptyFirstBlockDoesNotSelectALaterSibling() {
        #expect(CleanupPrompt.extractTaggedText("<text> \n</text><text>later sibling</text>") == "")
    }

    @Test func anUntaggedReplyRetainsLegacyWrapperRemoval() {
        #expect(CleanupPrompt.extractTaggedText("“Hello.”") == "Hello.")
    }

    @Test func theStageSendsTheExamplesAsTurnsAndNotInsideTheInstructions() async throws {
        let backend = TurnRecordingBackend { _ in "Hello there." }
        _ = try await LLMCleanupStage(backend: backend, prompt: probe()).process("hello there", locale: de)
        #expect(backend.examples == [[LLMExample(user: "EX-IN-de-DE", assistant: "EX-OUT-de-DE")]])
        #expect(backend.instructions == ["SYSTEM[de-DE|]"])
    }

    @Test func theUserMessageAndTheInstructionsReceiveTheLocaleAndTheVocabulary() async throws {
        let backend = TurnRecordingBackend { _ in "Hello Legato." }
        _ = try await LLMCleanupStage(backend: backend, vocabulary: ["Legato", "Grunwald"], prompt: probe())
            .process("hello legato", locale: en)
        #expect(backend.instructions == ["SYSTEM[en-US|Legato,Grunwald]"])
        #expect(backend.prompts == ["USER[en-US|Legato,Grunwald]hello legato"])
    }

    @Test func theReplyGoesThroughThePromptsExtractor() async throws {
        let backend = TurnRecordingBackend { _ in "noise <out>Hello there.</out> noise" }
        let extractor: @Sendable (String) -> String = { reply in
            guard let open = reply.range(of: "<out>"), let close = reply.range(of: "</out>") else { return reply }
            return String(reply[open.upperBound ..< close.lowerBound])
        }
        let out = try await LLMCleanupStage(backend: backend, prompt: probe(extract: extractor))
            .process("hello there", locale: en)
        #expect(out == "Hello there.")
    }

    @Test func aBackendWithoutTurnsGetsTheExamplesFoldedIntoTheInstructions() async throws {
        let backend = LegacyBackend()
        _ = try await backend.respond(
            instructions: "RULES", examples: [LLMExample(user: "IN-1", assistant: "OUT-1")], prompt: "NOW")
        let instructions = try #require(backend.instructions.first)
        #expect(instructions.hasPrefix("RULES"))
        #expect(instructions.contains("IN-1"))
        #expect(instructions.contains("OUT-1"))
        #expect(backend.prompts == ["NOW"])
    }

    @Test func noExamplesLeavesTheInstructionsUntouched() async throws {
        let backend = LegacyBackend()
        _ = try await backend.respond(instructions: "RULES", examples: [], prompt: "NOW")
        #expect(backend.instructions == ["RULES"])
    }

    @Test func theChunkBudgetCountsTheExamples() async throws {
        let long = String(repeating: "wort ", count: 60).trimmingCharacters(in: .whitespaces) + "."
        let manySentences = Array(repeating: long, count: 6).joined(separator: " ")
        func chunkCount(examples: Int) async throws -> Int {
            let prompt = CleanupPrompt(
                name: "sized",
                instructions: { _, _ in "RULES" },
                examples: { _ in Array(repeating: LLMExample(user: String(repeating: "u", count: 200), assistant: String(repeating: "a", count: 200)), count: examples) },
                userMessage: { text, _, _ in text },
                extractText: { $0 })
            let backend = TurnRecordingBackend(maxPromptCharacters: 2_000) { $0 }
            _ = try await LLMCleanupStage(backend: backend, prompt: prompt).process(manySentences, locale: de)
            return backend.prompts.count
        }
        let none = try await chunkCount(examples: 0)
        let three = try await chunkCount(examples: 3)
        #expect(three > none)
    }

    @Test func aRejectedChunkIsReportedAndKeepsItsInput() async throws {
        let backend = TurnRecordingBackend { _ in "Hello, how are you? I am fine, thank you for asking me today." }
        let results = try await LLMCleanupStage(backend: backend, prompt: probe())
            .processChunks("hello how are you", locale: en)
        let result = try #require(results.first)
        #expect(results.count == 1)
        #expect(result.input == "hello how are you")
        #expect(result.output == "hello how are you")
        #expect(result.reply == "Hello, how are you? I am fine, thank you for asking me today.")
        #expect(!result.accepted)
    }

    @Test func anAcceptedChunkCarriesTheCleanedText() async throws {
        let backend = TurnRecordingBackend { _ in "Hello, how are you?" }
        let results = try await LLMCleanupStage(backend: backend, prompt: probe())
            .processChunks("hello how are you", locale: en)
        #expect(results.map(\.output) == ["Hello, how are you?"])
        #expect(results.map(\.accepted) == [true])
    }

    #if canImport(FoundationModels)
    @Test func foundationModelsGetsTheInstructionsThenEachExampleAsPromptAndResponse() {
        let transcript = FoundationModelsBackend.transcript(
            instructions: "RULES",
            examples: [LLMExample(user: "in one", assistant: "out one"), LLMExample(user: "in two", assistant: "out two")])
        func describe(_ entry: Transcript.Entry) -> String {
            func text(_ segments: [Transcript.Segment]) -> String {
                segments.compactMap { segment -> String? in
                    if case .text(let part) = segment { return part.content }
                    return nil
                }.joined()
            }
            switch entry {
            case .instructions(let value): return "instructions:" + text(value.segments)
            case .prompt(let value): return "prompt:" + text(value.segments)
            case .response(let value): return "response:" + text(value.segments)
            default: return "other"
            }
        }
        #expect(transcript.map(describe) == [
            "instructions:RULES", "prompt:in one", "response:out one", "prompt:in two", "response:out two",
        ])
    }
    #endif
}

@Suite struct WritingModeStructureTests {
    @Test func emptyChunkFallbackPreservesParagraphsAndIndentation() async throws {
        let source = "  # Heading\n\n- first item\n    nested item\n\nLast paragraph.  "
        let backend = TurnRecordingBackend { _ in "" }
        let result = try await LLMCleanupStage(backend: backend, maxChunkCharacters: 18).process(source, locale: Locale(identifier: "en"))
        #expect(result == source)
    }
}

@Suite struct PromptLedAcceptanceTests {
    @Test(arguments: CleanupStyle.allCases)
    func substantialRewritesAndFormattedOutputReachCaller(style: CleanupStyle) async throws {
        let expected = "# Next steps\n\n- Prüfe den Build.\n- Review tomorrow, vielleicht. 🙂"
        let backend = TurnRecordingBackend { _ in "<text>\(expected)</text>" }
        let stage = LLMCleanupStage(backend: backend, prompt: style.prompt, acceptance: .promptLed)
        let result = try await stage.processGuarded("äh der billed und dann review morgen vielleicht", locale: Locale(identifier: "de"))
        #expect(result.text == expected)
        #expect(!result.rejected)
    }

    @Test(arguments: ["", "   ", "<text>\n\n</text>"])
    func emptyExtractedOutputRetainsExactSource(reply: String) async throws {
        let source = "  # Heading\n\n    - Item\n\nLast paragraph.  "
        let backend = TurnRecordingBackend { _ in reply }
        let stage = LLMCleanupStage(backend: backend, maxChunkCharacters: 16, prompt: CleanupStyle.markdown.prompt, acceptance: .promptLed)
        #expect(try await stage.process(source, locale: Locale(identifier: "en")) == source)
    }

    @Test func aRefusedChunkKeepsSeparatorsBesideAnAcceptedChunk() async throws {
        let source = "first paragraph.\n\n    second paragraph.\n"
        let backend = TurnRecordingBackend { prompt in
            prompt.contains("first paragraph") ? "<text>First paragraph.</text>" : ""
        }
        let result = try await LLMCleanupStage(backend: backend, maxChunkCharacters: 20, prompt: CleanupStyle.markdown.prompt, acceptance: .promptLed)
            .process(source, locale: Locale(identifier: "en"))
        #expect(result == "First paragraph.\n\n    second paragraph.\n")
    }

    @Test func markdownChunksJoinAsSeparateBlocks() async throws {
        let backend = TurnRecordingBackend { prompt in prompt.contains("first section") ? "<text># First</text>" : "<text># Second</text>" }
        let result = try await LLMCleanupStage(backend: backend, maxChunkCharacters: 15, prompt: CleanupStyle.markdown.prompt, acceptance: .promptLed)
            .process("first section. second section.", locale: Locale(identifier: "en"))
        #expect(result == "# First\n\n# Second")
    }
}
