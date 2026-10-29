import Foundation
import Speech

@available(iOS 26.0, *)
func progressiveWithAlternatives(locale: Locale) -> SpeechTranscriber {
    var preset = SpeechTranscriber.Preset.progressiveTranscription
    preset.reportingOptions.insert(.alternativeTranscriptions)
    preset.attributeOptions.insert(.transcriptionConfidence)
    return SpeechTranscriber(locale: locale, preset: preset)
}

@available(iOS 26.0, *)
func alternatives(in result: SpeechTranscriber.Result) -> [AttributedString] {
    result.alternatives
}
