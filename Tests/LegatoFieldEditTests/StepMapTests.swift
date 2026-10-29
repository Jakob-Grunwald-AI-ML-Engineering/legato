import Testing
import LegatoFieldEdit

struct RebaseRow: Sendable, CustomTestStringConvertible {
    let name: String
    let pending: Span
    let bias: Bias
    let expected: StepMap.Mapped
    var testDescription: String { name }

    init(_ name: String, _ location: Int, _ length: Int, _ expected: StepMap.Mapped) {
        self.init(name, location, length, .before, expected)
    }

    init(_ name: String, _ location: Int, _ length: Int, _ bias: Bias, _ expected: StepMap.Mapped) {
        self.name = name
        pending = Span(location: location, length: length)
        self.bias = bias
        self.expected = expected
    }
}

private func moved(_ location: Int, _ length: Int) -> StepMap.Mapped { .moved(Span(location: location, length: length)) }

@Suite struct StepMapTests {
    /// A landed replace of [10, 15) by three units (net −2).
    static let replace = StepMap(span: Span(location: 10, length: 5), insertedLength: 3)
    /// A landed insert of four units at 10.
    static let insert = StepMap(span: .at(10), insertedLength: 4)

    @Test(arguments: [
        RebaseRow("before", 2, 3, moved(2, 3)),
        RebaseRow("touching the start", 5, 5, moved(5, 5)),
        RebaseRow("touching the end", 15, 5, moved(13, 5)),
        RebaseRow("after", 20, 2, moved(18, 2)),
        RebaseRow("inside", 12, 2, .deleted),
        RebaseRow("overlapping the start", 8, 4, .deleted),
        RebaseRow("overlapping the end", 14, 4, .deleted),
        RebaseRow("the same range", 10, 5, .deleted),
        RebaseRow("containing it", 8, 10, .deleted),
        RebaseRow("insert inside the deleted range", 12, 0, .deleted),
        RebaseRow("insert at its start, bias before", 10, 0, .before, moved(10, 0)),
        RebaseRow("insert at its start, bias after", 10, 0, .after, moved(13, 0)),
        RebaseRow("insert at its end", 15, 0, .before, moved(13, 0)),
        RebaseRow("insert at its end, bias after", 15, 0, .after, moved(13, 0)),
        RebaseRow("insert before", 5, 0, moved(5, 0)),
        RebaseRow("insert after", 20, 0, .after, moved(18, 0)),
    ])
    func rebaseThroughAReplace(_ row: RebaseRow) {
        #expect(Self.replace.map(row.pending, bias: row.bias) == row.expected)
    }

    @Test(arguments: [
        RebaseRow("ending at the insert", 5, 5, moved(5, 5)),
        RebaseRow("starting at the insert", 10, 4, moved(14, 4)),
        RebaseRow("around the insert", 8, 4, .deleted),
        RebaseRow("insert at the same point, bias before", 10, 0, .before, moved(10, 0)),
        RebaseRow("insert at the same point, bias after", 10, 0, .after, moved(14, 0)),
    ])
    func rebaseThroughAnInsert(_ row: RebaseRow) {
        #expect(Self.insert.map(row.pending, bias: row.bias) == row.expected)
    }

    @Test func positionsInsideAReplacedRangeCollapseToItsSide() {
        #expect(Self.replace.map(position: 12, bias: .before) == 10)
        #expect(Self.replace.map(position: 12, bias: .after) == 13)
        #expect(Self.replace.map(position: 30) == 28)
        #expect(Self.replace.map(position: 3) == 3)
    }

    @Test func mapFromAStepUsesTheInsertedUTF16Length() {
        let map = StepMap(EditStep(span: Span(location: 0, length: 1), text: "👩🏽‍💻", expect: "x"))
        #expect(map.insertedLength == "👩🏽‍💻".utf16.count)
        #expect(map.map(Span(location: 4, length: 1)) == moved(3 + "👩🏽‍💻".utf16.count, 1))
    }
}
