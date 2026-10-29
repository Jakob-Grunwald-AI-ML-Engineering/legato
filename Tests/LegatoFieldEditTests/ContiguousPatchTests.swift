import Foundation
import Testing
import LegatoFieldEdit

private struct PatchFixture: Decodable {
    let id, old, new, prefix: String
}

private let fixtures: [String: PatchFixture] = {
    let url = Bundle.module.url(forResource: "patches", withExtension: "json", subdirectory: "Fixtures")!
    let list = try! JSONDecoder().decode([PatchFixture].self, from: Data(contentsOf: url))
    return Dictionary(uniqueKeysWithValues: list.map { ($0.id, $0) })
}()

/// Removed / inserted, in Characters and in UTF-16 units, of the smallest byte-exact patch per spike fixture.
struct PatchSize: Sendable, CustomTestStringConvertible {
    let id: String
    let removed: Int, inserted: Int
    let removedUTF16: Int, insertedUTF16: Int
    var testDescription: String { id }
}

@Suite struct ContiguousPatchTests {
    @Test(arguments: [
        PatchSize(id: "P01", removed: 2, inserted: 2, removedUTF16: 2, insertedUTF16: 2),
        PatchSize(id: "P02", removed: 0, inserted: 4, removedUTF16: 0, insertedUTF16: 4),
        PatchSize(id: "P03", removed: 4, inserted: 0, removedUTF16: 4, insertedUTF16: 0),
        PatchSize(id: "P04", removed: 2, inserted: 4, removedUTF16: 2, insertedUTF16: 4),
        // Decomposed é → precomposed é: Swift-equal Characters, but not byte-equal, so the patch keeps them apart.
        PatchSize(id: "P05", removed: 1, inserted: 1, removedUTF16: 2, insertedUTF16: 1),
        PatchSize(id: "P06", removed: 2, inserted: 2, removedUTF16: 2, insertedUTF16: 2),
        PatchSize(id: "P07", removed: 2, inserted: 2, removedUTF16: 2, insertedUTF16: 2),
        PatchSize(id: "P08", removed: 0, inserted: 2, removedUTF16: 0, insertedUTF16: 2),
        PatchSize(id: "P09", removed: 2, inserted: 2, removedUTF16: 2, insertedUTF16: 2),
        PatchSize(id: "P10", removed: 2, inserted: 2, removedUTF16: 2, insertedUTF16: 2),
        PatchSize(id: "P11", removed: 11, inserted: 12, removedUTF16: 11, insertedUTF16: 12),
        PatchSize(id: "P12", removed: 2, inserted: 2, removedUTF16: 2, insertedUTF16: 2),
    ])
    func fixturePatchesAreMinimalAndByteExact(_ size: PatchSize) throws {
        let fixture = try #require(fixtures[size.id])
        let field = fixture.prefix + fixture.old
        let step = try #require(ContiguousPatch.between(fixture.old, fixture.new, at: fixture.prefix.utf16.count))
        #expect(step.expect.count == size.removed)
        #expect(step.text.count == size.inserted)
        #expect(step.span.length == size.removedUTF16)
        #expect(step.text.utf16.count == size.insertedUTF16)
        #expect(step.expect.utf16.count == step.span.length)
        let patched = try #require(step.apply(to: field))
        #expect(Array(patched.utf8) == Array((fixture.prefix + fixture.new).utf8))
    }

    @Test func p01ReplacesOnlyTheSwappedLettersAfterTheAnchor() throws {
        let fixture = try #require(fixtures["P01"])
        let step = try #require(ContiguousPatch.between(fixture.old, fixture.new, at: 9))
        #expect(step == EditStep(span: Span(location: 9 + 6, length: 2), text: "he", expect: "eh"))
    }

    @Test func spansCountUTF16UnitsAcrossEmoji() throws {
        let step = try #require(ContiguousPatch.between("👩🏽‍💻 teh", "👩🏽‍💻 the", at: 0))
        #expect(step.span.location == "👩🏽‍💻 t".utf16.count)
        #expect(step.span.length == 2)
    }

    @Test func byteEqualTextsHaveNoPatch() {
        #expect(ContiguousPatch.between("same text", "same text", at: 4) == nil)
        #expect(ContiguousPatch.between("", "", at: 0) == nil)
    }

    @Test func applyRefusesAStepWhoseExpectedTextIsNotThere() {
        let step = EditStep(span: Span(location: 5, length: 3), text: "the", expect: "teh")
        #expect(step.apply(to: "Send teh report") == "Send the report")
        #expect(step.apply(to: "Send tex report") == nil)
        #expect(step.apply(to: "Send") == nil)
    }
}
