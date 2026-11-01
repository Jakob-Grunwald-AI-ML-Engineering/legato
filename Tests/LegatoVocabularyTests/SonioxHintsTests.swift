import Foundation
import Testing
@testable import LegatoVocabulary

@Test func sonioxHintsCapAt100AfterEligibility() {
    let entries = (0..<150).map { VocabularyEntry(text: "Term\($0)", source: .manual, lastSeen: Date()) }
    let result = HintSelector(languages: ["de", "en"]).hints(from: VocabularySnapshot(entries: entries), for: .soniox, limit: 500)
    #expect(result.count == 100)
}
