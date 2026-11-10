#if LEGATO_INTERNAL
import Foundation
import LegatoAgent
import LegatoAppServices

/// Deterministic, credential-free fixture. It has no provider client or network route.
struct MacOfflineInstructionRunner: InstructionRunning {
    func run(instruction: String, context: InstructionContext, read: InstructionRunner.Reader) async throws -> InstructionOutcome {
        let lower = instruction.lowercased()
        let scope: InstructionScope = context.selection != nil ? .selection : lower.contains("whole") || lower.contains("all text") ? .all : lower.contains("dictated") && context.sessionLength > 0 ? .session : .paragraph
        guard let range = scope.range(in: context) else { throw InstructionFailure.noText }
        let text = range.selected ?? (range.before + range.after)
        let result: String
        if lower.contains("uppercase") || lower.contains("upper case") || lower.contains("capital letters") { result = text.uppercased() }
        else if lower.contains("lowercase") || lower.contains("lower case") { result = text.lowercased() }
        else if lower.contains("delete") { result = "" }
        else { throw InstructionFailure.unreadable("Offline fixture supports uppercase, lowercase and delete instructions.") }
        return try InstructionRunner.outcome(reply: "SCOPE: \(scope.rawValue)\n" + result, context: context, instruction: instruction)
    }
}
#endif
