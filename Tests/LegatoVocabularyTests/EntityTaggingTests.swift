import Testing
@testable import LegatoVocabulary

@Suite struct EntityTaggingTests {
    @Test func emptyTextHasNoEntities() {
        #expect(NLEntityTagger().entities(in: "", language: "en").isEmpty)
    }

    @Test func findsAPlaceAndAJoinedPersonName() {
        let spans = NLEntityTagger().entities(in: "Yesterday Tim Cook flew to Berlin.", language: "en")
        #expect(spans.contains(EntitySpan(text: "Tim Cook", kind: .person)))
        #expect(spans.contains(EntitySpan(text: "Berlin", kind: .place)))
    }
}
