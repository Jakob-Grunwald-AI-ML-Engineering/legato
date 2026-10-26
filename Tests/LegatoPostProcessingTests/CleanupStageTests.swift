import Foundation
import LegatoCore
import Synchronization
import Testing
@testable import LegatoPostProcessing

// MARK: guard

@Suite("CleanupGuard")
struct CleanupGuardTests {
    private let guardrail = CleanupGuard()

    @Test(arguments: [
        // punctuation and casing only
        ("hello how are you doing today", "Hello, how are you doing today?"),
        ("wir treffen uns morgen um zehn", "Wir treffen uns morgen um zehn."),
        // spelling
        ("ich muß das heute noch erledigen und dann nach hause gehen",
         "Ich muss das heute noch erledigen und dann nach Hause gehen."),
        // written forms
        ("wir treffen uns am dritten märz um vierzehn uhr im büro",
         "Wir treffen uns am 3. März um 14 Uhr im Büro."),
        // a misrecognition of a name
        ("ask kloud to summarize the meeting notes for me", "Ask Claude to summarize the meeting notes for me."),
        // nothing to fix
        ("Already fine.", "Already fine."),
    ])
    func acceptsFixesThatKeepTheContent(_ pair: (String, String)) {
        #expect(guardrail.accepts(pair.1, reference: pair.0))
    }

    @Test(arguments: [
        // an added sentence
        ("please send me the report by friday",
         "Please send me the report by Friday. Thank you so much for your help."),
        // dropped content
        ("please send me the report by friday and cc anna and ben", "Please send me the report by Friday."),
        // a rewrite into another language
        ("das ist gut", "That is good."),
        // an answer instead of a cleanup
        ("what is the capital of france", "The capital of France is Paris."),
        // nothing came back
        ("hello there my friend", ""),
        ("hello there my friend", "  \n"),
    ])
    func rejectsAddedOrDroppedContent(_ pair: (String, String)) {
        #expect(!guardrail.accepts(pair.1, reference: pair.0))
    }

    @Test func punctuationAndCasingChangesHaveZeroDrift() {
        #expect(guardrail.drift(candidate: "Hello, World!", reference: "hello world") == 0)
    }

    @Test func driftIsTheWordEditDistanceOverTheLongerText() {
        // one substituted word out of four
        #expect(abs(guardrail.drift(candidate: "a b c x", reference: "a b c d") - 0.25) < 1e-9)
        // two dropped words out of four
        #expect(abs(guardrail.drift(candidate: "a b", reference: "a b c d") - 0.5) < 1e-9)
    }

    @Test func tokensAreLowercasedWordsWithoutPunctuation() {
        #expect(CleanupGuard.tokens("Hello, Wörld! It's 25€.") == ["hello", "wörld", "it", "s", "25"])
    }

    @Test func emptyReferenceAcceptsOnlyEmptyDrift() {
        #expect(guardrail.drift(candidate: "", reference: "") == 0)
    }
}

// MARK: stage

private final class FakeBackend: LLMBackend {
    let id = "fake"
    let maxPromptCharacters: Int?
    private let availabilityValue: LLMAvailability
    private let reply: @Sendable (String) throws -> String
    private struct State { var instructions: [String] = []; var prompts: [String] = [] }
    private let state = Mutex(State())

    init(maxPromptCharacters: Int? = nil, availability: LLMAvailability = .available,
         reply: @escaping @Sendable (String) throws -> String) {
        self.maxPromptCharacters = maxPromptCharacters
        self.availabilityValue = availability
        self.reply = reply
    }

    var availability: LLMAvailability { get async { availabilityValue } }
    var prompts: [String] { state.withLock { $0.prompts } }
    var instructions: [String] { state.withLock { $0.instructions } }

    func respond(instructions: String, prompt: String) async throws -> String {
        state.withLock { $0.instructions.append(instructions); $0.prompts.append(prompt) }
        return try reply(prompt)
    }
}

/// The text the stage put in the prompt: what sits between the transcript tags.
private func transcript(in prompt: String) -> String {
    guard let open = prompt.range(of: "<transcript>"), let close = prompt.range(of: "</transcript>") else { return prompt }
    return String(prompt[open.upperBound ..< close.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
}

private let de = Locale(identifier: "de-DE")
private let en = Locale(identifier: "en-US")

@Suite("LLMCleanupStage")
struct CleanupStageTests {
    @Test func theInstructionsAndPromptCarryTheLocale() async throws {
        let backend = FakeBackend { transcript(in: $0) }
        _ = try await LLMCleanupStage(backend: backend).process("hallo welt", locale: de)
        let combined = (backend.instructions + backend.prompts).joined(separator: "\n")
        #expect(combined.contains("de-DE"))
        #expect(combined.contains("German"))
        #expect(backend.prompts.first?.contains("hallo welt") == true)
    }

    @Test func theInstructionsForbidAddingOrDroppingContent() {
        let text = LLMCleanupStage.instructions(locale: en).lowercased()
        for phrase in ["punctuation", "spelling", "never add", "only the"] {
            #expect(text.contains(phrase), "missing: \(phrase)")
        }
    }

    @Test func theUsersVocabularyReachesTheInstructions() async throws {
        let backend = FakeBackend { transcript(in: $0) }
        _ = try await LLMCleanupStage(backend: backend, vocabulary: ["Legato", "Grunwald"])
            .process("hallo welt", locale: de)
        let instructions = backend.instructions.joined(separator: "\n")
        #expect(instructions.contains("Legato"))
        #expect(instructions.contains("Grunwald"))
    }

    @Test func noVocabularyNamesNoWords() {
        let text = LLMCleanupStage.instructions(locale: en)
        for name in ["Claude", "ChatGPT", "OpenAI", "GitHub"] {
            #expect(!text.contains(name), "unexpected built-in name: \(name)")
        }
    }

    @Test func aGoodReplyReplacesTheText() async throws {
        let backend = FakeBackend { _ in "Hello, how are you?" }
        let out = try await LLMCleanupStage(backend: backend).process("hello how are you", locale: en)
        #expect(out == "Hello, how are you?")
    }

    @Test func replyWrappersAreStripped() async throws {
        let replies = [
            "<transcript>Hello, how are you?</transcript>",
            "\"Hello, how are you?\"",
            "<think>\n\n</think>\n\nHello, how are you?",
            "  Hello, how are you?\n",
        ]
        for reply in replies {
            let backend = FakeBackend { _ in reply }
            let out = try await LLMCleanupStage(backend: backend).process("hello how are you", locale: en)
            #expect(out == "Hello, how are you?", "for reply \(reply.debugDescription)")
        }
    }

    @Test func aReplyThatDriftsIsRejectedAndTheInputKept() async throws {
        let backend = FakeBackend { _ in "Hello, how are you? I am fine, thank you for asking me today." }
        let out = try await LLMCleanupStage(backend: backend).process("hello how are you", locale: en)
        #expect(out == "hello how are you")
    }

    @Test func aGuardrailErrorKeepsTheInput() async throws {
        let backend = FakeBackend { _ in throw LLMError.guardrail }
        let out = try await LLMCleanupStage(backend: backend).process("hello how are you", locale: en)
        #expect(out == "hello how are you")
    }

    @Test func anEmptyReplyKeepsTheInput() async throws {
        let backend = FakeBackend { _ in "" }
        #expect(try await LLMCleanupStage(backend: backend).process("hello how are you", locale: en) == "hello how are you")
    }

    @Test func anUnavailableBackendThrowsWithoutBeingCalled() async {
        let backend = FakeBackend(availability: .unavailable(reason: "no model")) { $0 }
        await #expect(throws: LLMError.self) {
            _ = try await LLMCleanupStage(backend: backend).process("hello", locale: en)
        }
        #expect(backend.prompts.isEmpty)
    }

    @Test func otherBackendErrorsPropagateSoThePipelineCanPassThrough() async {
        struct Boom: Error {}
        let backend = FakeBackend { _ in throw Boom() }
        await #expect(throws: Boom.self) {
            _ = try await LLMCleanupStage(backend: backend).process("hello there", locale: en)
        }
    }

    // MARK: chunking

    @Test func chunksBreakAtSentenceBoundaries() {
        let text = "First sentence here. Second one follows! Is a third a question? Yes, and a fourth ends it."
        let chunks = LLMCleanupStage.chunks(of: text, maxCharacters: 45)
        #expect(chunks.count >= 2)
        for chunk in chunks {
            #expect(chunk.count <= 45, "too long: \(chunk)")
            #expect([".", "!", "?"].contains(String(chunk.last!)), "cut mid-sentence: \(chunk)")
        }
        #expect(chunks.joined(separator: " ") == text)
    }

    @Test func lowercaseSentencesStillBreakAtTheirPeriods() {
        // Speech output often has periods but no capitals; the break must still fall on a period.
        let text = "guten morgen zusammen. ich möchte kurz den stand zusammenfassen. wir haben die version verschickt. es kamen wenige rückmeldungen."
        let chunks = LLMCleanupStage.chunks(of: text, maxCharacters: 70)
        #expect(chunks.count >= 2)
        for chunk in chunks {
            #expect(chunk.count <= 70, "too long: \(chunk)")
            #expect(chunk.hasSuffix("."), "cut mid-sentence: \(chunk)")
        }
        #expect(chunks.joined(separator: " ") == text)
    }

    @Test func shortTextIsOneChunk() {
        #expect(LLMCleanupStage.chunks(of: "One. Two.", maxCharacters: 100) == ["One. Two."])
    }

    @Test func aSingleSentenceOverTheLimitSplitsAtWords() {
        let text = "one two three four five six seven eight nine ten"
        let chunks = LLMCleanupStage.chunks(of: text, maxCharacters: 20)
        #expect(chunks.count > 1)
        #expect(chunks.allSatisfy { $0.count <= 20 })
        #expect(chunks.joined(separator: " ") == text)
    }

    @Test func longInputIsSentOneChunkPerCall() async throws {
        let text = "First sentence here. Second one follows! Is a third a question? Yes, and a fourth ends it."
        let backend = FakeBackend(maxPromptCharacters: 1_000_000) { transcript(in: $0) }
        let stage = LLMCleanupStage(backend: backend, maxChunkCharacters: 45)
        let out = try await stage.process(text, locale: en)
        #expect(backend.prompts.count == LLMCleanupStage.chunks(of: text, maxCharacters: 45).count)
        #expect(backend.prompts.count >= 2)
        #expect(out == text)
    }

    @Test func theBackendLimitShrinksTheChunkSize() async throws {
        let text = "First sentence here. Second one follows! Is a third a question? Yes, and a fourth ends it."
        // The limit leaves room for the instructions; the stage must still chunk below it.
        let limit = LLMCleanupStage.instructions(locale: en).count + 140
        let backend = FakeBackend(maxPromptCharacters: limit) { transcript(in: $0) }
        let out = try await LLMCleanupStage(backend: backend, maxChunkCharacters: 100_000).process(text, locale: en)
        #expect(backend.prompts.count >= 2)
        #expect(out == text)
    }

    @Test func aChunkThatFailsTheGuardOrGuardrailKeepsOnlyItsOwnText() async throws {
        let text = "alpha beta gamma. delta epsilon zeta. eta theta iota."
        let backend = FakeBackend { prompt in
            let t = transcript(in: prompt)
            if t.contains("delta") { throw LLMError.guardrail }
            return t.prefix(1).uppercased() + t.dropFirst()
        }
        let out = try await LLMCleanupStage(backend: backend, maxChunkCharacters: 20).process(text, locale: en)
        #expect(out == "Alpha beta gamma. delta epsilon zeta. Eta theta iota.")
    }
}
