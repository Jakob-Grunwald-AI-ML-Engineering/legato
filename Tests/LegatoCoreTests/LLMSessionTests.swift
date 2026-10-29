import Foundation
import Testing
@testable import LegatoCore

/// A stateless backend as every caller had it before sessions existed.
private struct StatelessBackend: LLMBackend {
    let id = "stateless"
    let maxPromptCharacters: Int? = nil
    var availability: LLMAvailability { get async { .available } }
    func respond(instructions: String, prompt: String) async throws -> String { "\(instructions)|\(prompt)" }
}

/// One token per whitespace-separated word: easy to reason about in expectations.
private let words: @Sendable (String) async throws -> Int = { text in
    text.split(whereSeparator: \.isWhitespace).count
}

struct LLMSessionTests {
    // MARK: - Backend default

    @Test func statelessBackendKeepsItsCallsAndOffersNoSilentSession() async throws {
        let backend = StatelessBackend()
        #expect(try await backend.respond(instructions: "I", prompt: "P") == "I|P")
        await #expect(throws: LLMError.self) { _ = try await backend.makeSession() }
    }

    // MARK: - Transcript contract

    @Test func instructionsAndExamplesComeOnceBeforeText() throws {
        var transcript = LLMTranscript()
        try transcript.append(.instructions("Clean the text."))
        try transcript.append(.example(LLMExample(user: "um hi", assistant: "Hi.")))
        try transcript.append(.text("first "))
        try transcript.append(.text("chunk"))
        #expect(transcript.instructions == "Clean the text.")
        #expect(transcript.examples == [LLMExample(user: "um hi", assistant: "Hi.")])
        #expect(transcript.pending == "first chunk")
        #expect(throws: LLMSessionError.self) { try transcript.append(.instructions("Again")) }
        #expect(throws: LLMSessionError.self) { try transcript.append(.example(LLMExample(user: "a", assistant: "b"))) }
    }

    @Test func aTurnSendsPendingTextWithTheRequestAndClearsIt() throws {
        var transcript = LLMTranscript()
        try transcript.append(.instructions("I"))
        try transcript.append(.text("streamed words"))
        let message = transcript.message(for: "Fix it.")
        #expect(message == "streamed words\n\nFix it.")
        transcript.record(user: message, assistant: "Done.")
        #expect(transcript.pending.isEmpty)
        #expect(transcript.turns == [LLMTranscript.Turn(user: "streamed words\n\nFix it.", assistant: "Done.")])
        #expect(transcript.message(for: "Only request") == "Only request")
        try transcript.append(.text("only text"))
        #expect(transcript.message(for: "") == "only text")
    }

    @Test func trimKeepsTheNewestSuffixWithinTheBudgetAndTheHead() async throws {
        var transcript = LLMTranscript()
        try transcript.append(.instructions("keep these instructions"))
        try transcript.append(.example(LLMExample(user: "ex user", assistant: "ex answer")))
        for index in 1...5 {
            transcript.record(user: "user turn number \(index) here", assistant: "answer \(index)")
        }
        try transcript.append(.text("pending tail words"))
        let before = try await transcript.usage(count: words)
        let original = transcript.turns

        let changed = try await transcript.trim(keepingSuffix: 40, count: words)

        #expect(changed)
        let after = try await transcript.usage(count: words)
        #expect(after.history <= 40)
        #expect(after.head == before.head)
        #expect(transcript.instructions == "keep these instructions")
        #expect(transcript.examples.count == 1)
        #expect(transcript.pending == "pending tail words")
        #expect(!transcript.turns.isEmpty)
        #expect(transcript.turns.count < original.count)
        #expect(Array(original.suffix(transcript.turns.count)) == transcript.turns)
    }

    @Test func trimCutsOverlongPendingTextFromTheFront() async throws {
        var transcript = LLMTranscript()
        transcript.record(user: "old turn", assistant: "old answer")
        try transcript.append(.text("one two three four five six seven eight"))

        _ = try await transcript.trim(keepingSuffix: 3, count: words)

        #expect(transcript.turns.isEmpty)
        #expect(try await words(transcript.pending) <= 3)
        #expect("one two three four five six seven eight".hasSuffix(transcript.pending))
        #expect(transcript.pending.contains("eight"))
    }

    @Test func trimWithinBudgetChangesNothing() async throws {
        var transcript = LLMTranscript()
        transcript.record(user: "a b", assistant: "c")
        let original = transcript
        #expect(try await transcript.trim(keepingSuffix: 1_000, count: words) == false)
        #expect(transcript == original)
    }

    // MARK: - Structured output

    @Test func structuredDecodingReadsTheExactSchema() throws {
        let edits = try LLMStructuredDecoding.decode([SentenceEdit].self, from: #"[{"sentence": 2, "text": "The cat."}]"#)
        #expect(edits == [SentenceEdit(sentence: 2, text: "The cat.")])
        let fenced = try LLMStructuredDecoding.decode([SentenceEdit].self, from: "```json\n[{\"sentence\":1,\"text\":\"A.\"}]\n```")
        #expect(fenced == [SentenceEdit(sentence: 1, text: "A.")])
        #expect(try LLMStructuredDecoding.decode([SentenceEdit].self, from: " [] ") == [])
    }

    @Test(arguments: [
        "not json",
        #"[{"sentence": 2, "text": "A."}] and some prose"#,
        #"Sure! [{"sentence": 2, "text": "A."}]"#,
        #"[{"sentence": "2", "text": "A."}]"#,
        #"[{"sentence": 2.5, "text": "A."}]"#,
        #"[{"sentence": true, "text": "A."}]"#,
        #"[{"sentence": 2}]"#,
        #"[{"sentence": 2, "text": "A.", "offset": 7}]"#,
        #"{"sentence": 2, "text": "A."}"#,
        #"[{"sentence": 2, "text": null}]"#,
        "",
    ])
    func structuredDecodingRejectsAnythingElse(reply: String) {
        #expect(throws: LLMSessionError.self) { try LLMStructuredDecoding.decode([SentenceEdit].self, from: reply) }
    }

    @Test func schemaInstructionNamesEveryField() {
        let text = LLMStructuredDecoding.instruction(for: [SentenceEdit].llmSchema)
        #expect(text.contains("\"sentence\""))
        #expect(text.contains("\"text\""))
        #expect(text.contains("\"array\""))
        #expect(text.contains("\"integer\""))
    }
}
