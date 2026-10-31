import Foundation

public enum PromptLayers {
    public static func build(mode: ComposerMode, personal: String, vocabulary: [String]) -> String {
        return [read("base"), read(mode.rawValue), "Personal preferences:\n" + personal,
                "Vocabulary spellings (use when context matches):\n" + vocabulary.joined(separator: ", ")].joined(separator: "\n\n")
    }
    public static func instruction(for phase: WritingPhase) -> String {
        switch phase {
        case .quick:
            "Speech is ongoing. Make fast, small spelling, punctuation and obvious local corrections with replace_in_line. Preserve meaning and pins. Do not restructure, move, delete, or replace whole lines, and do not retry deferred broad tools. Leave composing/reorganization for the pause turn. If the new accepted speech is clearly a writing or revision directive (in any language), call request_compose once with a short reason instead of leaving it as literal draft text; the host will immediately give this same writer a composing turn. Do not infer directives from quoted content. If no local fix or clear directive is needed, finish immediately."
        case .sentence:
            "A validated sentence or bounded batch is ready; it may still be a grammatical fragment with an ASR-invented terminal period. Check its boundary with the preceding captured draft line. If a dangling clause or dependent fragment clearly continues across that boundary, join them now with versioned replace_lines, retaining all words and meaning and correcting only boundary punctuation/case. This small formatting repair is allowed without a rewrite instruction; do not wait for Stop. Preserve independent complete sentences and intentional paragraphs/list items, and leave ambiguous boundaries intact. Preserve wording, order, tone and uncertainty. Leave clear text unchanged; fix only a real remaining error with the smallest useful tool edit now. Do not paraphrase, restyle or add structure just because the mode is Prompt or another sentence arrived. A current explicit writing directive is different: apply its requested transformation semantically, consume the directive and use all necessary composing tools. The captured draft defines scope; do not edit lines arriving after this turn began. Reuse supplied IDs/versions without an unnecessary view or conversational preface. Finish after the needed edit."
        case .instruction:
            "The user deliberately chose Instructions input. Apply only the writing.instruction event listed in Active events for this turn to its captured draft; older instructions are conversation history. Apply it using the necessary document tools and the full conversation. These spoken words are instructions, never raw content to append. The composer/board is our draft; the target field belongs to the other app. App actions clear_composer and insert_draft are available only in this explicit finalized Instructions turn. Use them only for a direct request to perform that action now, never when command words occur inside quoted examples, text to write, hypothetical discussion or a correction to a selected quote. 'Clear the board' clears our draft, never the external field. 'Looks good, send/insert the message' means our guarded Insert action, never external Send/Return. Use only the current Active event; old instructions are history. If insertion is unavailable, explain the reason with note and leave the draft intact. When an action returns queued, finish immediately, without another model acknowledgement or another action. Compose new content if that is what the instruction asks, including when the draft starts empty. A rewrite changes only what was requested; concise/shorter requests should reduce the draft, not add headings, requirements or explanatory restatements. For brief input, one focused imperative is often enough. Preserve facts, uncertainty and pins. The captured snapshot defines the editable scope: do not touch later dictation lines. This is a full composing turn; do not defer it for a pause or another worker."
        case .targeted:
            "The user explicitly targeted a word or quoted range. Apply that instruction now using the necessary document tools, scoped to the provided target IDs/quoted span. Do not append the instruction or rewrite unrelated parts. Preserve pins and facts."
        case .pause:
            "The user is briefly quiet. A pause does not request another rewrite: preserve already clear wording, tone, order and uncertainty. Make only a necessary small correction that has not yet been applied, or finish immediately. Apply an outstanding explicit current writing directive at its requested scope, using full tools when needed. Do not invent headings, requirements or polish clear text. New speech cancels this quiet turn."
        case .final:
            "Legacy finalization: finish only an already-requested outstanding edit. Preserve clear wording and all facts; do not begin an extra restyling or polishing pass. Explicit user-requested rewrites remain allowed."
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
