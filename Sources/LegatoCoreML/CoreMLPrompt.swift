import Foundation
import LegatoCore

public enum CoreMLPromptFamily: String, Sendable, Hashable { case qwen3, gemma3 }

/// Exact checkpoint conversation rendering; the native tokenizer checks it against its checkpoint template.
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
    static func render(instructions: String, examples: [LLMExample], prompt: String, family: CoreMLPromptFamily = .qwen3) -> String {
        let turns = messages(instructions: instructions, examples: examples, prompt: prompt)
        switch family {
        case .qwen3:
            return turns.map {
                "<|im_start|>\($0["role"] as? String ?? "")\n\($0["content"] as? String ?? "")<|im_end|>\n"
            }.joined() + "<|im_start|>assistant\n<think>\n\n</think>\n\n"
        case .gemma3:
            var system = ""
            var rendered = "<bos>"
            for turn in turns {
                let role = turn["role"] as? String ?? ""
                let text = turn["content"] as? String ?? ""
                if role == "system" { system += text; continue }
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                let content = system.isEmpty ? trimmed : system + "\n\n" + trimmed
                system = ""
                rendered += "<start_of_turn>\(role == "assistant" ? "model" : "user")\n\(content)<end_of_turn>\n"
            }
            return rendered + "<start_of_turn>model\n"
        }
    }
    static func validate(input: Int, outputLimit: Int, context: Int) throws {
        guard input > 0, outputLimit > 0, context > 2, outputLimit <= context - 2,
              input <= context - outputLimit - 2 else { throw LLMError.contextTooLong }
    }
}
