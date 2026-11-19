import Foundation

public enum PromptLayers {
    /// The cleanup-only prompt for line-by-line dictation into a field (the ABC surface; never the writer).
    public static func dictationCleanup() -> String { read("dictation-cleanup") }
    /// The iPhone's staged send (#316): speech becomes the text the speaker means, shaped by its type (`DictationCleanupStyle.send`).
    public static func dictationSend() -> String { read("dictation-send") }
    /// The cleanup-only prompt for a whole dictation take sent in one call (on stop or after a pause).
    public static func dictationTakeCleanup() -> String { read("dictation-take-cleanup") }
    /// The keyboard's instruction mode: one spoken instruction rewrites one scope of the field (`InstructionRunner`).
    public static func instructionMode() -> String { read("instruction") }
    private static func read(_ name: String) -> String {
        guard let url = Bundle.module.url(forResource: name, withExtension: "md", subdirectory: "Prompts")
            ?? Bundle.module.url(forResource: name, withExtension: "md") else { return "" }
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }
}
