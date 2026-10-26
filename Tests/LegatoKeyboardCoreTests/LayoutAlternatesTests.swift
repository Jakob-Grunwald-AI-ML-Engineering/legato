import Foundation
import Testing
@testable import LegatoKeyboardCore

@Suite struct LayoutAlternatesTests {
    @Test func germanLetters() {
        #expect(Alternates.for("a").contains("ä"))
        #expect(Alternates.for("o").contains("ö"))
        #expect(Alternates.for("u").contains("ü"))
        #expect(Alternates.for("s").first == "ß")
    }

    @Test func quotes() {
        let dq = Alternates.for("\"")
        #expect(dq.contains("„") && dq.contains("“") && dq.contains("”"))
        let sq = Alternates.for("'")
        #expect(sq.contains("‚") && sq.contains("‘") && sq.contains("’"))
    }

    @Test func dashes() {
        #expect(Alternates.for("-").prefix(2) == ["–", "—"])
    }

    @Test func accentedVowelsInIOSOrder() {
        #expect(Alternates.for("a").prefix(4) == ["à", "á", "â", "ä"])
        #expect(Alternates.for("e").prefix(4) == ["è", "é", "ê", "ë"])
        #expect(Alternates.for("c").first == "ç")
        #expect(Alternates.for("n").first == "ñ")
    }

    @Test func uppercaseKeyGivesUppercaseAlternates() {
        #expect(Alternates.for("A").prefix(4) == ["À", "Á", "Â", "Ä"])
        #expect(Alternates.for("S").first == "ẞ")
    }

    @Test func keysWithoutAlternates() {
        #expect(Alternates.for("q").isEmpty)
        #expect(Alternates.for("1").isEmpty)
    }

    @Test func noDuplicates() {
        for ch in "abcdefghijklmnopqrstuvwxyz0123456789-\"'$?!" {
            let alts = Alternates.for(String(ch))
            #expect(Set(alts).count == alts.count, "\(ch)")
        }
    }

    @Test func layoutKeysCarryTheirAlternates() {
        let a = KeyboardLayout.page(.letters).rows[1].keys.first!
        #expect(a.alternates.contains("ä"))
    }
}
