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
            "A complete sentence or bounded batch of notes is ready. Author it now, even while the user continues speaking: remove fillers, stutters and abandoned repetitions; integrate its intent into the draft using the current mode. This is a composing turn, not just spellchecking. Interpret revision directives semantically in any language (for example, 'make it shorter' revises the draft rather than becoming draft text). Use necessary document tools on the captured draft; new speech is queued for the next turn. Do not incorporate or edit lines that arrived after this turn began. Preserve facts, uncertainty, alternatives and pins. Make one coherent improvement, then finish; do not repeatedly polish suitable text."
        case .targeted:
            "The user explicitly targeted a word or quoted range. Apply that instruction now using the necessary document tools, scoped to the provided target IDs/quoted span. Do not append the instruction or rewrite unrelated parts. Preserve pins and facts."
        case .pause:
            "The user has paused briefly. Act now: turn unprocessed speech and rough notes into a clear, natural draft in the user's voice, even without an explicit rewrite command. Remove dictation filler and repetition, repair grammar and phrasing, and organize ideas where it improves readability. Resolve writing directives into authored content; preserve every fact and pinned correction. Do not wait for Stop or a longer pause. Leave already suitable authored text alone; finish when satisfied. New speech will cancel this turn."
        case .final:
            "Dictation has ended and pending input has drained. Complete the intended draft using the same context and tools. Apply any remaining necessary cleanup or restructuring, preserving facts and pins. Leave a good draft alone and finish."
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
