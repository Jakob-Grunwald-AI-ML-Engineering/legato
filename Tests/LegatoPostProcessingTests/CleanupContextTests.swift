import Foundation
import LegatoCore
import Synchronization
import Testing
@testable import LegatoPostProcessing

/// Records what it was sent and answers with a fixed reply.
private final class RecordingBackend: LLMBackend {
    let id = "recording"
    let maxPromptCharacters: Int? = nil
    private let sent = Mutex<[(instructions: String, prompt: String)]>([])
    private let reply: String
    init(reply: String) { self.reply = reply }
    var availability: LLMAvailability { get async { .available } }
    var calls: [(instructions: String, prompt: String)] { sent.withLock { $0 } }
    func respond(instructions: String, prompt: String) async throws -> String {
        sent.withLock { $0.append((instructions, prompt)) }
        return reply
    }
    func respond(instructions: String, examples: [LLMExample], prompt: String) async throws -> String {
        try await respond(instructions: instructions, prompt: prompt)
    }
}

private let en = Locale(identifier: "en_US")

@Suite struct CleanupContextTests {
    @Test func withoutContextThePromptIsTheStandardOne() async throws {
        let backend = RecordingBackend(reply: "<text>How are you?</text>")
        _ = try await LLMCleanupStage(backend: backend).process("how are you", locale: en)
        let call = try #require(backend.calls.first)
        #expect(call.prompt == CleanupPrompt.standard.userMessage("how are you", en, []))
        #expect(call.instructions == CleanupPrompt.standard.instructions(en, []))
    }

    @Test func theContextComesFirstMarkedAsContextAndIsNotPartOfTheReply() async throws {
        let backend = RecordingBackend(reply: "<text>How are you?</text>")
        let out = try await LLMCleanupStage(backend: backend, context: "  Hello world. ").process("how are you", locale: en)
        let call = try #require(backend.calls.first)
        #expect(call.prompt == "<before>\nHello world.\n</before>\n" + CleanupPrompt.standard.userMessage("how are you", en, []))
        #expect(call.instructions.hasSuffix(LLMCleanupStage.contextInstruction))
        #expect(out == "How are you?")
    }

    @Test func onlyTheEndOfALongContextIsShownStartingAtAWord() {
        let long = (1...200).map { "word\($0)" }.joined(separator: " ")
        let bounded = LLMCleanupStage.boundedContext(long)
        #expect(bounded.count <= LLMCleanupStage.maxContextCharacters)
        #expect(long.hasSuffix(bounded))
        #expect(bounded.hasPrefix("word"), "no cut word at the start")
    }
}
