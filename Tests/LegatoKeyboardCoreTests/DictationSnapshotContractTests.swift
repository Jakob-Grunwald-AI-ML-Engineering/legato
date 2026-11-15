import Foundation
import Testing
@testable import LegatoKeyboardCore

@Test func dictationSnapshotCarriesProducerTextAcrossLink() throws {
    var value = LiveDictationSnapshot(runID: "take", version: 7,
        segments: [.init(id: 0, text: "Hello", final: true), .init(id: 1, text: ", world.", final: true)], complete: true)
    #expect(value.text == "Hello, world.")
    value.text = "Producer's exact\ntext"
    let restored = try JSONDecoder().decode(LiveDictationSnapshot.self, from: JSONEncoder().encode(value))
    #expect(restored.text == "Producer's exact\ntext")
    #expect(restored.runID == "take")
    #expect(restored.version == 7)
}

@Test func oldSnapshotAssemblesPunctuationAtDecodeBoundary() throws {
    let data = Data(#"{"runID":"old","version":1,"segments":[{"id":0,"text":"Hello","cleaned":false,"final":true},{"id":1,"text":", world","cleaned":false,"final":true}],"complete":true}"#.utf8)
    #expect(try JSONDecoder().decode(LiveDictationSnapshot.self, from: data).text == "Hello, world")
}

@Test func retiredTypistBoundaryBehaviorLivesInSharedInsertion() {
    #expect(FieldInsertion.prepare(", and then", contextBefore: "Hello", capitalization: .sentences) == ", and then")
    #expect(FieldInsertion.prepare("world", contextBefore: "Hello", capitalization: .sentences) == " world")
    #expect(FieldInsertion.prepare("hello", contextBefore: "", capitalization: .none) == "hello")
}
