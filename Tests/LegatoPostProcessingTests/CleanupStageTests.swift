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

    // MARK: numbers and dropped content

    @Test(arguments: [
        ("twenty one euros", "21 euros"),
        ("call me at three thirty", "Call me at 3:30."),
        ("das kostet zwölf euro fünfzig", "Das kostet 12,50 Euro."),
        ("am zweiten juni", "am 2. Juni"),
        ("das kostet fünfundzwanzig euro", "Das kostet 25 Euro."),
        ("es sind dreißig grad", "Es sind 30 Grad."),
        ("it costs one hundred and five dollars", "It costs 105 dollars."),
        ("the meeting is on the third of may", "The meeting is on the 3rd of May."),
        ("twenty five euros", "€25"),
    ])
    func acceptsSpokenNumbersWrittenAsDigits(_ pair: (String, String)) {
        #expect(guardrail.accepts(pair.1, reference: pair.0))
    }

    private static let fiveSentences =
        "we shipped the new version on monday. the team collected a lot of feedback from customers. "
        + "most people liked the faster start up time. a few asked for a dark mode. we will plan the next release on friday."

    @Test func rejectsACleanupThatDropsAWholeSentenceOfALongText() {
        let dropped = "We shipped the new version on Monday. The team collected a lot of feedback from customers. "
            + "Most people liked the faster start up time. We will plan the next release on Friday."
        #expect(!guardrail.accepts(dropped, reference: Self.fiveSentences))
        // The same drop in a transcript without punctuation.
        let flat = Self.fiveSentences.replacingOccurrences(of: ".", with: "")
        let flatDropped = "We shipped the new version on Monday. The team collected a lot of feedback from customers. "
            + "Most people liked the faster start up time. We will plan the next release on Friday."
        #expect(!guardrail.accepts(flatDropped, reference: flat))
    }

    @Test func rejectsADroppedShortSentenceWhenTheReferenceHasSentences() {
        let reference = "we shipped the new version on monday. thanks a lot. the team collected a lot of feedback from customers. "
            + "most people liked the faster start up time."
        let dropped = "We shipped the new version on Monday. The team collected a lot of feedback from customers. "
            + "Most people liked the faster start up time."
        #expect(!guardrail.accepts(dropped, reference: reference))
    }

    @Test func acceptsTheFaithfulCleanupOfALongText() {
        let faithful = "We shipped the new version on Monday. The team collected a lot of feedback from customers. "
            + "Most people liked the faster start-up time. A few asked for a dark mode. We will plan the next release on Friday."
        #expect(guardrail.accepts(faithful, reference: Self.fiveSentences))
    }

    @Test func aNumberThatIsNotThereIsStillMissing() {
        #expect(!guardrail.accepts("It costs dollars.", reference: "it costs thirty dollars and fifty cents per month"))
    }

    // MARK: CJK

    @Test func chineseAndJapaneseTokenizeByCharacter() {
        #expect(CleanupGuard.tokens("今天天气很好。") == ["今", "天", "天", "气", "很", "好"])
        #expect(CleanupGuard.tokens("こんにちは世界") == ["こ", "ん", "に", "ち", "は", "世", "界"])
        #expect(CleanupGuard.tokens("iPhoneで写真") == ["iphone", "で", "写", "真"])
    }

    @Test func punctuationOnlyChangesToChineseHaveNoDrift() {
        #expect(guardrail.drift(candidate: "今天天气很好，我们去公园。", reference: "今天天气很好我们去公园") == 0)
    }

    @Test func aDroppedChineseSentenceIsRejected() {
        let reference = "今天天气很好。我们去公园散步。然后我们去吃午饭。下午回家休息。"
        #expect(guardrail.accepts("今天天气很好。我们去公园散步。然后我们去吃午饭。下午回家休息。", reference: reference))
        #expect(!guardrail.accepts("今天天气很好。我们去公园散步。下午回家休息。", reference: reference))
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

/// The text the stage put in the prompt: what sits between the text tags.
private func transcript(in prompt: String) -> String {
    for tag in ["text", "transcript"] {
        if let open = prompt.range(of: "<\(tag)>"), let close = prompt.range(of: "</\(tag)>") {
            return String(prompt[open.upperBound ..< close.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
    return prompt
}

private let de = Locale(identifier: "de-DE")
private let en = Locale(identifier: "en-US")

@Suite("LLMCleanupStage")
struct CleanupStageTests {
    @Test func theTextReachesThePromptAndTheExamplesEndInItsLanguage() async throws {
        let backend = FakeBackend { transcript(in: $0) }
        _ = try await LLMCleanupStage(backend: backend).process("hallo welt", locale: de)
        #expect(backend.prompts.first?.contains("hallo welt") == true)
        // The nearest example counts most, so the last one is in the transcript's language.
        let german = CleanupPrompt.standard.examples(de)
        let english = CleanupPrompt.standard.examples(en)
        #expect(german.last?.assistant.contains("Samstag") == true)
        #expect(english.last?.assistant.contains("morning") == true)
    }

    @Test func theInstructionsForbidAddingOrDroppingContent() {
        let text = CleanupPrompt.standard.instructions(en, []).lowercased()
        for phrase in ["punctuation", "spelling", "every sentence", "never translate", "add anything", "nothing else"] {
            #expect(text.contains(phrase), "missing: \(phrase)")
        }
    }

    @Test func theUsersVocabularyReachesThePrompt() async throws {
        let backend = FakeBackend { transcript(in: $0) }
        _ = try await LLMCleanupStage(backend: backend, vocabulary: ["Legato", "Grunwald"])
            .process("hallo welt", locale: de)
        let prompt = backend.prompts.joined(separator: "\n")
        #expect(prompt.contains("Legato"))
        #expect(prompt.contains("Grunwald"))
        #expect(!backend.instructions.joined(separator: "\n").contains("Legato"))
    }

    @Test func noVocabularyNamesNoWords() {
        let text = CleanupPrompt.standard.instructions(en, [])
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

    @Test func theTermsLineShrinksTheChunkBudget() async throws {
        let long = String(repeating: "wort ", count: 20).trimmingCharacters(in: .whitespaces) + "."
        let text = Array(repeating: long, count: 12).joined(separator: " ")
        func calls(vocabulary: [String]) async throws -> Int {
            let backend = FakeBackend(maxPromptCharacters: 4_000) { transcript(in: $0) }
            _ = try await LLMCleanupStage(backend: backend, vocabulary: vocabulary).process(text, locale: de)
            return backend.prompts.count
        }
        let terms = (1...20).map { "Fachbegriff\($0)" }
        let without = try await calls(vocabulary: [])
        let with = try await calls(vocabulary: terms)
        #expect(with > without)
    }


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
        // The limit leaves room for the instructions and examples; the stage must still chunk below it.
        let examples = CleanupPrompt.standard.examples(en).reduce(0) { $0 + $1.user.count + $1.assistant.count }
        let limit = CleanupPrompt.standard.instructions(en, []).count + examples + 140
        let backend = FakeBackend(maxPromptCharacters: limit) { transcript(in: $0) }
        let out = try await LLMCleanupStage(backend: backend, maxChunkCharacters: 100_000).process(text, locale: en)
        #expect(backend.prompts.count >= 2)
        #expect(out == text)
    }

    // MARK: CJK

    private static let chinese = "今天天气很好。我们去公园散步。然后我们去吃午饭。下午回家休息。"

    @Test(arguments: ["zh-CN", "ja-JP", "zh-Hant-TW"])
    func chineseAndJapaneseChunksJoinWithoutSpaces(_ identifier: String) async throws {
        let backend = FakeBackend { transcript(in: $0) }
        let out = try await LLMCleanupStage(backend: backend, maxChunkCharacters: 14)
            .process(Self.chinese, locale: Locale(identifier: identifier))
        #expect(backend.prompts.count >= 2, "the text was cut into chunks")
        #expect(out == Self.chinese)
        for prompt in backend.prompts { #expect(!transcript(in: prompt).contains(" ")) }
    }

    @Test func spacedLanguagesStillJoinWithASpace() async throws {
        let text = "First sentence here. Second one follows! Is a third a question?"
        let backend = FakeBackend { transcript(in: $0) }
        let out = try await LLMCleanupStage(backend: backend, maxChunkCharacters: 25).process(text, locale: en)
        #expect(backend.prompts.count >= 2)
        #expect(out == text)
    }

    @Test func aChineseSentenceOverTheLimitIsCutByCharacters() {
        let text = "今天天气很好我们去公园散步然后我们去吃午饭下午回家休息"
        let chunks = LLMCleanupStage.chunks(of: text, maxCharacters: 10, joiner: "")
        #expect(chunks.count > 1)
        #expect(chunks.allSatisfy { $0.count <= 10 })
        #expect(chunks.joined() == text)
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
