import Foundation
import Testing
@testable import LegatoKeyboardCore

@Suite struct KeptTextTests {
    @Test func keepsOneItemAndReplacesIt() {
        let store = KeptTextStore(LinkStore(MemoryLinkStore()))
        store.keep("  first take \n")
        #expect(store.read()?.text == "first take")
        store.keep("second take")
        #expect(store.read()?.text == "second take")
        store.keep("   ")
        #expect(store.read()?.text == "second take")
        store.clear()
        #expect(store.read() == nil)
    }

    @Test func previewCutsFromTheHead() {
        let item = KeptText(text: "milk and the eggs on Tuesday.")
        #expect(item.preview(maxCharacters: 100) == "milk and the eggs on Tuesday.")
        let cut = item.preview(maxCharacters: 12)
        #expect(cut.hasPrefix("…") && cut.hasSuffix("Tuesday.") && cut.count == 12)
    }
}
