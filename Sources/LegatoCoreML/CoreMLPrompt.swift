import Foundation
import LegatoCore

/// Exact Qwen3 conversation rendering; the native tokenizer checks it against its checkpoint template.
enum CoreMLPrompt {
    static func messages(instructions: String, examples: [LLMExample], prompt: String) -> [[String: any Sendable]] {
        var result: [[String: any Sendable]] = [["role": "system", "content": instructions]]
        for example in examples {
            result.append(["role": "user", "content": example.user])
            result.append(["role": "assistant", "content": example.assistant])
        }
        result.append(["role": "user", "content": prompt])
        return result
    }
    static func render(instructions: String, examples: [LLMExample], prompt: String) -> String {
        messages(instructions: instructions, examples: examples, prompt: prompt).map {
            "<|im_start|>\($0["role"] as? String ?? "")\n\($0["content"] as? String ?? "")<|im_end|>\n"
        }.joined() + "<|im_start|>assistant\n<think>\n\n</think>\n\n"
    }
    static func validate(input: Int, outputLimit: Int, context: Int) throws {
        guard input > 0, outputLimit > 0, context > 2, outputLimit <= context - 2,
              input <= context - outputLimit - 2 else { throw LLMError.contextTooLong }
    }
}
