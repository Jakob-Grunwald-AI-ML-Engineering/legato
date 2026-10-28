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

    @Test func reservesOutputAndTwoWindowTokens() throws {
        try CoreMLPrompt.validate(input: 1_022, outputLimit: 1_024, context: 2_048)
        #expect(throws: LLMError.contextTooLong) { try CoreMLPrompt.validate(input: 1_023, outputLimit: 1_024, context: 2_048) }
        #expect(throws: LLMError.contextTooLong) { try CoreMLPrompt.validate(input: 0, outputLimit: 1_024, context: 2_048) }
        #expect(throws: LLMError.contextTooLong) { try CoreMLPrompt.validate(input: 10, outputLimit: 0, context: 2_048) }
    }
}
