import Testing
@testable import LegatoClaude

/// Feeds `json` in `size`-scalar chunks and returns the pieces handed out and the field.
private func run(_ json: String, size: Int, key: String = "text") -> (pieces: [String], field: StreamedStringField) {
    var field = StreamedStringField(key: key), pieces: [String] = []
    let scalars = Array(json.unicodeScalars)
    for start in stride(from: 0, to: scalars.count, by: size) {
        var chunk = String.UnicodeScalarView()
        chunk.append(contentsOf: scalars[start..<min(start + size, scalars.count)])
        pieces.append(field.feed(String(chunk)))
    }
    return (pieces, field)
}

@Test(arguments: [1, 2, 3, 7, 1000])
func theTextFieldIsDecodedWhateverTheChunking(_ size: Int) {
    let json = #"{"sentenceID":"t-1","text":"Hi \"Anna\", a\\b\nline\ttab ä 😀 end"}"#
    let result = run(json, size: size)
    #expect(result.pieces.joined() == "Hi \"Anna\", a\\b\nline\ttab ä 😀 end")
    #expect(result.field.isComplete)
}

@Test(arguments: [1, 4, 1000])
func eitherKeyOrderAndOtherFieldsAreHandled(_ size: Int) {
    let before = run(#"{"text":"first","sentenceID":"x \"text\": no"}"#, size: size)
    #expect(before.pieces.joined() == "first")
    let after = run(#"{ "sentenceID" : "id", "n": [1,{"text":"nested"}], "text" : "second" }"#, size: size)
    #expect(after.pieces.joined() == "second" && after.field.isComplete)
}

@Test func anEscapeSplitAcrossChunksIsHeldBack() {
    var field = StreamedStringField(key: "text")
    #expect(field.feed(#"{"text":"ab\"#) == "ab", "A lone backslash waits for its letter")
    #expect(field.feed("n") == "\n")
    #expect(field.feed(#"\u00"#) == "", "Half a unicode escape waits")
    #expect(field.feed("e4") == "ä")
    #expect(field.feed(#"\ud83d"#) == "", "A high surrogate waits for its pair")
    #expect(field.feed(#"\ude00"#) == "😀")
    #expect(!field.isComplete)
    #expect(field.feed(#"x"}"#) == "x" && field.isComplete)
}

@Test func loneSurrogatesBecomeReplacementCharacters() {
    #expect(run(#"{"text":"\ud83dX"}"#, size: 3).pieces.joined() == "\u{FFFD}X")
    #expect(run(#"{"text":"\ude00"}"#, size: 3).pieces.joined() == "\u{FFFD}")
}

@Test func nothingIsHandedOutBeforeTheValueStartsOrAfterItEnds() {
    var field = StreamedStringField(key: "text")
    #expect(field.feed(#"{"sentenceID":"a","te"#) == "")
    #expect(field.feed(#"xt":"#) == "")
    #expect(field.feed(#" "ok"#) == "ok")
    #expect(field.feed(#""}"#) == "" && field.isComplete)
    #expect(field.feed(#"{"text":"again"}"#) == "")
}
