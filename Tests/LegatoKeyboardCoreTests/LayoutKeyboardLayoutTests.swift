import Foundation
import Testing
@testable import LegatoKeyboardCore

@Suite struct LayoutKeyboardLayoutTests {
    private func chars(_ row: KeyboardRow) -> String {
        row.keys.compactMap { if case .character(let c) = $0.action { c } else { nil } }.joined()
    }

    @Test func lettersPageIsQwerty() {
        let rows = KeyboardLayout.page(.letters).rows
        #expect(rows.count == 4)
        #expect(chars(rows[0]) == "qwertyuiop")
        #expect(chars(rows[1]) == "asdfghjkl")
        #expect(chars(rows[2]) == "zxcvbnm")
    }

    @Test func lettersThirdRowHasShiftAndDelete() {
        let r = KeyboardLayout.page(.letters).rows[2]
        #expect(r.keys.first?.action == .shift)
        #expect(r.keys.last?.action == .delete)
    }

    @Test func bottomRowHasModeGlobeMicSpaceReturn() {
        let r = KeyboardLayout.page(.letters).rows[3]
        #expect(r.keys.map(\.action) == [.modeSwitch(.numbers), .globe, .mic, .space, .returnKey])
        let n = KeyboardLayout.page(.numbers).rows[3]
        #expect(n.keys.first?.action == .modeSwitch(.letters))
        let s = KeyboardLayout.page(.symbols).rows[3]
        #expect(s.keys.first?.action == .modeSwitch(.letters))
    }

    @Test func numbersPage() {
        let rows = KeyboardLayout.page(.numbers).rows
        #expect(chars(rows[0]) == "1234567890")
        #expect(chars(rows[1]) == "-/:;()$&@\"")
        #expect(rows[2].keys.first?.action == .modeSwitch(.symbols))
        #expect(chars(rows[2]) == ".,?!'")
        #expect(rows[2].keys.last?.action == .delete)
    }

    @Test func symbolsPage() {
        let rows = KeyboardLayout.page(.symbols).rows
        #expect(chars(rows[0]) == "[]{}#%^*+=")
        #expect(chars(rows[1]) == "_\\|~<>€£¥•")
        #expect(rows[2].keys.first?.action == .modeSwitch(.numbers))
        #expect(chars(rows[2]) == ".,?!'")
    }

    @Test func everyRowSpansTheSameRelativeWidth() {
        for page in KeyboardPage.allCases {
            for row in KeyboardLayout.page(page).rows {
                #expect(abs(row.totalWidth - 10) < 0.0001, "\(page) \(row.totalWidth)")
            }
        }
    }

    @Test func spaceIsWidestAndLettersAreUnit() {
        let rows = KeyboardLayout.page(.letters).rows
        #expect(rows[0].keys.allSatisfy { $0.width == 1 })
        let space = rows[3].keys.first { $0.action == .space }!
        #expect(rows[3].keys.allSatisfy { $0.width <= space.width })
    }

    @Test func keyIdsAreUniquePerPage() {
        for page in KeyboardPage.allCases {
            let ids = KeyboardLayout.page(page).rows.flatMap(\.keys).map(\.id)
            #expect(Set(ids).count == ids.count, "\(page)")
        }
    }

    @Test func emojiPlaceholderActionExists() {
        #expect(KeyAction.emoji != .space)
    }

    @Test func lettersAreUppercasedOnDemand() {
        #expect(Key.character("q").output(uppercase: true) == "Q")
        #expect(Key.character("q").output(uppercase: false) == "q")
        #expect(Key.character("1").output(uppercase: true) == "1")
    }
}
