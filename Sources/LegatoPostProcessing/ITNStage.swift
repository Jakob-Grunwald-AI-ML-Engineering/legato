import FluidAudio
import Foundation
import LegatoCore

/// Inverse text normalization: spoken forms become written ones ("twenty five euros" becomes "25 euros").
///
/// FluidAudio's normalizer is English-only, so other languages pass through for the LLM stage to handle.
public struct ITNStage: TranscriptPostProcessor {
    public let id = "itn"

    public init() {}

    public func process(_ text: String, locale: Locale) async throws -> String {
        guard locale.language.languageCode?.identifier == "en" else { return text }
        return TextNormalizer.shared.normalizeSentence(text)
    }
}
