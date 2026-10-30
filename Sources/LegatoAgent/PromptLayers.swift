import Foundation

public enum PromptLayers {
    public static func build(mode: ComposerMode, personal: String, vocabulary: [String]) -> String {
        return [read("base"), read(mode.rawValue), "Personal preferences:\n" + personal,
                "Vocabulary spellings (use when context matches):\n" + vocabulary.joined(separator: ", ")].joined(separator: "\n\n")
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
