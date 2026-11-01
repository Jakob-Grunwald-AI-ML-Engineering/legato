import Foundation

public enum PromptLayers {
    public static func build(mode: ComposerMode, personal: String, vocabulary: [String]) -> String {
        return [read("base"), read(mode.rawValue), "Personal preferences:\n" + personal,
                "Vocabulary spellings (use when context matches):\n" + vocabulary.joined(separator: ", ")].joined(separator: "\n\n")
    }
    /// The cleanup-only prompt for line-by-line dictation into a field (the ABC surface; never the writer).
    public static func dictationCleanup() -> String { read("dictation-cleanup") }
    public static func instruction(for phase: WritingPhase) -> String {
        switch phase {
        case .quick:
            "New input arrived. Make only the useful local spelling, punctuation and word-choice fixes with replace_in_line, preserving meaning and pins. Do not restructure, move, delete, or replace whole lines. If the input is clearly a writing or revision directive (in any language), call request_compose once with a short reason; the host will immediately give this same writer a composing turn. If nothing useful is needed, finish immediately."
        case .sentence:
            "The user edited the draft or changed the writing mode. Reconcile the draft with that: respect the user's edit, apply the new mode's style where it fits, and preserve meaning, facts, commitments, uncertainty and pins. Do not undo the edit and do not add content. Use versioned tools, reuse supplied IDs/versions, and finish after the useful changes."
        case .instruction:
            "The user spoke an instruction. Apply only the writing.instruction event listed in Active events for this turn to its captured draft; older instructions are conversation history. Carry it out with the necessary document tools and the full conversation. These spoken words are instructions, never raw content to append. If the instruction asks for new content, compose it into the draft, including when the draft starts empty; if it asks for a change, edit the draft. The composer/board is our draft; the target field belongs to the other app. App actions clear_composer and insert_draft are available only in this finalized instruction turn. Use them only for a direct request to perform that action now, never when command words occur inside quoted examples, text to write, hypothetical discussion or a correction to a selected quote. 'Clear the board' clears our draft, never the external field. 'Looks good, send/insert the message' means our guarded Insert action, never external Send/Return. Use only the current Active event; old instructions are history. If insertion is unavailable, explain the reason with note and leave the draft intact. When an action returns queued, finish immediately, without another model acknowledgement or another action. Preserve the intended meaning while improving style, word choice and formatting; concise/shorter requests should reduce the draft, not add requirements or explanatory restatements. For brief input, one focused edit is often enough. Preserve facts, uncertainty and pins. The captured snapshot defines the editable scope: do not touch lines added later."
        case .targeted:
            "The user explicitly targeted a word or quoted range. Apply that instruction now using the necessary document tools, scoped to the provided target IDs/quoted span. Do not append the instruction or rewrite unrelated parts. Preserve pins and facts."
        case .pause:
            "The user is briefly quiet. Complete only pending work from an outstanding instruction, using full tools when needed, preserving meaning, facts, intent and uncertainty. Add no unsupported content or unnecessary detail; finish when the draft reads well. New speech cancels this quiet turn."
        case .final:
            "Legacy finalization: finish only already-pending editing work, including useful style and formatting improvements that preserve meaning, facts, intent and uncertainty. Do not begin an additional automatic polishing pass. Explicit user-requested transformations remain allowed."
        }
    }
    /// Only existing specialized prompts may be loaded as writing skills; Auto is the dispatcher.
    public static func writingGuidance(for mode: ComposerMode) throws -> String {
        guard mode != .auto else { throw GuidanceError.unsupportedMode }
        let content = read(mode.rawValue)
        guard !content.isEmpty else { throw GuidanceError.missingResource }
        return content
    }
    private enum GuidanceError: Error { case unsupportedMode, missingResource }
    private static func read(_ name: String) -> String {
        guard let url = Bundle.module.url(forResource: name, withExtension: "md", subdirectory: "Prompts")
            ?? Bundle.module.url(forResource: name, withExtension: "md") else { return "" }
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }
}
