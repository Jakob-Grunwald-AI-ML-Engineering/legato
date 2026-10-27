import Testing
@testable import LegatoVocabulary

@Suite("PhoneticKey")
struct PhoneticKeyTests {
    /// Kölner Phonetik codes: the examples of the German Wikipedia article "Kölner Phonetik" (Müller-Lüdenscheidt,
    /// Breschnew, Wikipedia) and the umlaut/transliteration pair Müller/Mueller, plus the two spellings of Claude.
    @Test(arguments: [
        ("Müller", "657"),
        ("Mueller", "657"),
        ("Müller-Lüdenscheidt", "65752682"),
        ("Breschnew", "17863"),
        ("Wikipedia", "3412"),
        ("kloud", "452"),
        ("Claude", "452"),
        ("Grunwald", "476352"),
        ("Grünwald", "476352"),
        ("Straße", "8278"),
        ("Strasse", "8278"),
    ])
    func koelnerReferenceCodes(_ row: (String, String)) {
        #expect(PhoneticKey.koelner(row.0) == row.1)
    }

    @Test func koelnerIgnoresCaseAndNonLetters() {
        #expect(PhoneticKey.koelner("  MÜLLER! ") == "657")
        #expect(PhoneticKey.koelner("") == "")
        #expect(PhoneticKey.koelner("123") == "")
    }

    @Test func koelnerKeepsALeadingVowelCodeButDropsTheOthers() {
        #expect(PhoneticKey.koelner("Ute") == "02")
        #expect(PhoneticKey.koelner("Maya") == "6")
    }

    /// Metaphone codes (Lawrence Philips, 1990) from Apache Commons Codec's `MetaphoneTest.java`
    /// (src/test/java/org/apache/commons/codec/language/MetaphoneTest.java, commons-codec master), whose
    /// default code length is 4; the rows below are checked at that length, `CHARACTER` at 5.
    @Test(arguments: [
        ("SCIENCE", "SNS"),
        ("SCENE", "SN"),
        ("GNU", "N"),
        ("SIGNED", "SNT"),
        ("GHENT", "KNT"),
        ("BAUGH", "B"),
        ("PHISH", "FX"),
        ("SHOT", "XT"),
        ("SCHEDULE", "SKTL"),
        ("TEACH", "TX"),
        ("CITY", "ST"),
        ("CAT", "KT"),
        ("DODGE", "TJ"),
        ("COMB", "KM"),
        ("TOMB", "TM"),
        ("jumped", "JMPT"),
        ("testing", "TSTN"),
        ("The", "0"),
    ])
    func metaphoneReferenceCodes(_ row: (String, String)) {
        #expect(PhoneticKey.metaphone(row.0, maxLength: 4) == row.1)
    }

    @Test func metaphoneLongerCodeFromCommonsCodec() {
        #expect(PhoneticKey.metaphone("CHARACTER", maxLength: 5) == "XRKTR")
    }

    @Test func metaphoneAgreesOnTheWordsTheMatcherNeeds() {
        #expect(PhoneticKey.metaphone("kloud") == PhoneticKey.metaphone("Claude"))
        #expect(PhoneticKey.metaphone("kubernetties") == PhoneticKey.metaphone("Kubernetes"))
        #expect(PhoneticKey.metaphone("Maya") != PhoneticKey.metaphone("EMEA"))
    }
}
