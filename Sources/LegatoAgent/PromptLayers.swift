import Foundation

public enum PromptLayers {
    public static func build(mode: ComposerMode, personal: String, vocabulary: [String]) -> String {
        return [read("base"), read(mode.rawValue), "Personal preferences:\n" + personal,
                "Vocabulary spellings (use when context matches):\n" + vocabulary.joined(separator: ", ")].joined(separator: "\n\n")
    }
    public static func instruction(for phase: WritingPhase) -> String {
        switch phase {
        case .quick:
            "Speech is ongoing. Make useful local spelling, punctuation, grammar, phrasing and word-choice improvements with replace_in_line. Preserve meaning and pins. Do not restructure, move, delete, or replace whole lines, and do not retry deferred broad tools. Leave broader composing/reorganization for a captured composing turn; do not defer useful local improvements until Stop. If the new accepted speech is clearly a writing or revision directive (in any language), call request_compose once with a short reason instead of leaving it as literal draft text; the host will immediately give this same writer a composing turn. Do not infer directives from quoted content. If no useful local improvement or clear directive is needed, finish immediately."
        case .sentence:
            "A validated sentence or bounded batch is ready. Improve the captured draft proactively: style, word choice, flow, paragraphing and useful structure are welcome without an explicit rewrite request. Preserve meaning, intent, facts, commitments and uncertainty; do not invent content or expand unnecessarily. Check the new unit with preceding captured context: validation can retain grammatical fragments or ASR-invented periods, so join related clauses and remove verbal clutter into coherent prose when the intended meaning is clear. Respect deliberate lists, independent sentences and user-requested structure. Use all necessary versioned tools now rather than waiting for Stop. Consume current explicit writing directives and apply their requested transformation instead of appending them. The captured draft defines scope; do not edit lines arriving after this turn began. Reuse supplied IDs/versions without an unnecessary view or conversational preface. Finish after the useful improvements."
        case .instruction:
            "The user deliberately chose Instructions input. Apply only the writing.instruction event listed in Active events for this turn to its captured draft; older instructions are conversation history. Apply it using the necessary document tools and the full conversation. These spoken words are instructions, never raw content to append. The composer/board is our draft; the target field belongs to the other app. App actions clear_composer and insert_draft are available only in this explicit finalized Instructions turn. Use them only for a direct request to perform that action now, never when command words occur inside quoted examples, text to write, hypothetical discussion or a correction to a selected quote. 'Clear the board' clears our draft, never the external field. 'Looks good, send/insert the message' means our guarded Insert action, never external Send/Return. Use only the current Active event; old instructions are history. If insertion is unavailable, explain the reason with note and leave the draft intact. When an action returns queued, finish immediately, without another model acknowledgement or another action. Compose new content if that is what the instruction asks, including when the draft starts empty. Preserve the intended meaning while improving style, word choice and formatting; concise/shorter requests should reduce the draft, not add requirements or explanatory restatements. For brief input, one focused imperative is often enough. Preserve facts, uncertainty and pins. The captured snapshot defines the editable scope: do not touch later dictation lines. This is a full composing turn; do not defer it for a pause or another worker."
        case .targeted:
            "The user explicitly targeted a word or quoted range. Apply that instruction now using the necessary document tools, scoped to the provided target IDs/quoted span. Do not append the instruction or rewrite unrelated parts. Preserve pins and facts."
        case .pause:
            "The user is briefly quiet. Complete useful pending improvements to style, word choice, flow and formatting while preserving meaning, facts, intent and uncertainty. Apply an outstanding explicit current writing directive at its requested scope using full tools when needed. Add no unsupported content or unnecessary detail; finish when the draft reads well. New speech cancels this quiet turn. This guidance does not request an additional turn after drain-only Pause or Insert."
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
