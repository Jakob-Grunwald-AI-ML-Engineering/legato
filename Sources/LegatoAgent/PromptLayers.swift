import Foundation

public enum PromptLayers {
    public static func build(mode: ComposerMode, personal: String, vocabulary: [String]) -> String {
        func read(_ name: String) -> String {
            guard let url = Bundle.module.url(forResource: name, withExtension: "md", subdirectory: "Prompts")
                ?? Bundle.module.url(forResource: name, withExtension: "md") else { return "" }
            return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        }
        return [read("base"), read(mode.rawValue), "Personal preferences:\n" + personal,
                "Vocabulary spellings (use when context matches):\n" + vocabulary.joined(separator: ", ")].joined(separator: "\n\n")
    }
}
