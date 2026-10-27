import Foundation
import NaturalLanguage

/// A person, place or organisation found in a text.
public struct EntitySpan: Sendable, Equatable {
    /// The name as written in the text; a multi-word name keeps its spaces.
    public var text: String
    public var kind: VocabularyEntry.Kind

    public init(text: String, kind: VocabularyEntry.Kind) {
        self.text = text
        self.kind = kind
    }
}

/// Finds named entities in a text. A seam over `NLTagger` so learner tests don't depend on the OS model.
public protocol EntityTagging: Sendable {
    /// The names in `text`, in reading order. `language` is a bare code ("de", "en").
    func entities(in text: String, language: String) -> [EntitySpan]
}

/// ``EntityTagging`` backed by `NLTagger` with the `.nameType` scheme.
public struct NLEntityTagger: EntityTagging {
    public init() {}

    public func entities(in text: String, language: String) -> [EntitySpan] {
        guard !text.isEmpty else { return [] }
        let tagger = NLTagger(tagSchemes: [.nameType])
        tagger.string = text
        tagger.setLanguage(NLLanguage(rawValue: language), range: text.startIndex..<text.endIndex)
        var out: [EntitySpan] = []
        tagger.enumerateTags(
            in: text.startIndex..<text.endIndex, unit: .word, scheme: .nameType,
            options: [.joinNames, .omitWhitespace, .omitPunctuation]
        ) { tag, range in
            let kind: VocabularyEntry.Kind?
            switch tag {
            case .personalName: kind = .person
            case .placeName: kind = .place
            case .organizationName: kind = .organisation
            default: kind = nil
            }
            if let kind { out.append(EntitySpan(text: String(text[range]), kind: kind)) }
            return true
        }
        return out
    }
}
