import Testing
import LegatoCore
@testable import LegatoCoreML

struct CoreMLPromptTests {
    @Test func preservesAllExampleTurnsAndDisablesThinking() throws {
        let rendered = CoreMLPrompt.render(instructions: "Clean", examples: [.init(user: "um A", assistant: "A"), .init(user: "uh B", assistant: "B")], prompt: "  C\n")
        #expect(rendered == "<|im_start|>system\nClean<|im_end|>\n<|im_start|>user\num A<|im_end|>\n<|im_start|>assistant\nA<|im_end|>\n<|im_start|>user\nuh B<|im_end|>\n<|im_start|>assistant\nB<|im_end|>\n<|im_start|>user\n  C\n<|im_end|>\n<|im_start|>assistant\n<think>\n\n</think>\n\n")
        let messages = CoreMLPrompt.messages(instructions: "Clean", examples: [.init(user: "um A", assistant: "A")], prompt: "C")
        #expect(messages.count == 4)
        #expect(messages.compactMap { $0["role"] as? String } == ["system", "user", "assistant", "user"])
        #expect(messages.compactMap { $0["content"] as? String } == ["Clean", "um A", "A", "C"])
    }

    @Test func gemmaFoldsInstructionsIntoFirstUserTurnAndPreservesAllExamples() {
        let rendered = CoreMLPrompt.render(instructions: "  Clean\n", examples: [
            .init(user: "  um A\n", assistant: " A "), .init(user: "uh B", assistant: "B")
        ], prompt: "  C\n", family: .gemma3)
        #expect(rendered == "<bos><start_of_turn>user\n  Clean\n\n\num A<end_of_turn>\n<start_of_turn>model\nA<end_of_turn>\n<start_of_turn>user\nuh B<end_of_turn>\n<start_of_turn>model\nB<end_of_turn>\n<start_of_turn>user\nC<end_of_turn>\n<start_of_turn>model\n")
    }

    @Test func gemmaWithoutExamplesPlacesInstructionsInTheFinalUserTurn() {
        let rendered = CoreMLPrompt.render(instructions: "Clean", examples: [], prompt: "  C\n", family: .gemma3)
        #expect(rendered == "<bos><start_of_turn>user\nClean\n\nC<end_of_turn>\n<start_of_turn>model\n")
    }

    @Test func largerCheckpointsKeepTheSameOutputReservation() throws {
        try CoreMLPrompt.validate(input: 3_070, outputLimit: 1_024, context: 4_096)
        #expect(throws: LLMError.contextTooLong) { try CoreMLPrompt.validate(input: 3_071, outputLimit: 1_024, context: 4_096) }
    }

    @Test func reservesOutputAndTwoWindowTokens() throws {
        try CoreMLPrompt.validate(input: 1_022, outputLimit: 1_024, context: 2_048)
        #expect(throws: LLMError.contextTooLong) { try CoreMLPrompt.validate(input: 1_023, outputLimit: 1_024, context: 2_048) }
        #expect(throws: LLMError.contextTooLong) { try CoreMLPrompt.validate(input: 0, outputLimit: 1_024, context: 2_048) }
        #expect(throws: LLMError.contextTooLong) { try CoreMLPrompt.validate(input: 10, outputLimit: 0, context: 2_048) }
    }
}

@Suite("Core ML turn openings (prefill ahead)")
struct CoreMLTurnOpeningTests {
    @Test(arguments: [CoreMLPromptFamily.qwen3, .gemma3])
    func theOpeningIsAPrefixOfTheContinuation(family: CoreMLPromptFamily) {
        let opening = CoreMLPrompt.continuationOpening(user: "hello wrld", family: family)
        #expect(CoreMLPrompt.continuation(user: "hello wrld", family: family).hasPrefix(opening))
        #expect(CoreMLPrompt.continuation(user: "hello wrld", family: family).hasPrefix(opening.replacingOccurrences(of: "hello wrld", with: "")))
    }
}
