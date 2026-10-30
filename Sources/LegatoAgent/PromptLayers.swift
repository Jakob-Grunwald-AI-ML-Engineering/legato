import Foundation

public enum PromptLayers {
    public static func build(mode: ComposerMode, personal: String, vocabulary: [String]) -> String {
        return [read("base"), read(mode.rawValue), "Personal preferences:\n" + personal,
                "Vocabulary spellings (use when context matches):\n" + vocabulary.joined(separator: ", ")].joined(separator: "\n\n")
    }
    public static func instruction(for phase: WritingPhase) -> String {
        switch phase {
        case .quick:
            "Speech is ongoing. Make fast, small spelling, punctuation and obvious local corrections with replace_in_line. Preserve meaning and pins. Do not restructure, move, delete, or replace whole lines, and do not retry deferred broad tools. Leave composing/reorganization for the pause turn. If no local fix is needed, finish immediately."
        case .targeted:
            "The user explicitly targeted a word or quoted range. Apply that instruction now using the necessary document tools, scoped to the provided target IDs/quoted span. Do not append the instruction or rewrite unrelated parts. Preserve pins and facts."
        case .pause:
            "The user has paused. Compose the intended draft from raw notes and directives; reorganize only where it helps. Resolve writing instructions into authored content. Leave already suitable text alone; finish when satisfied. New speech will cancel this turn."
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
