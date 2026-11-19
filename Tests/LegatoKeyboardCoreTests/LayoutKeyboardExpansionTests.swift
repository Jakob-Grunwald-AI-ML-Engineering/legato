import Foundation
import Testing
@testable import LegatoKeyboardCore

@Suite struct LayoutKeyboardExpansionTests {
    private func withDefaults(_ body: (String, UserDefaults) -> Void) {
        let suite = "LayoutKeyboardExpansionTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        body(suite, defaults)
    }

    @Test func aFirstLaunchShowsTheFullKeyboard() {
        withDefaults { _, defaults in
            #expect(KeyboardExpansion(persistence: .init(defaults: defaults)).mode == .full)
        }
        #expect(KeyboardExpansion().mode == .full)
    }

    @Test func togglingMinimisesAndExpandsAgain() {
        var expansion = KeyboardExpansion()
        expansion.toggle()
        #expect(expansion.mode == .minimised)
        expansion.toggle()
        #expect(expansion.mode == .full)
    }

    @Test func theLastChoiceSurvivesRecreatingTheKeyboard() {
        withDefaults { suite, defaults in
            var first = KeyboardExpansion(persistence: .init(defaults: defaults))
            first.toggle()
            var recreated = KeyboardExpansion(persistence: .init(defaults: UserDefaults(suiteName: suite)!))
            #expect(recreated.mode == .minimised)
            recreated.toggle()
            #expect(KeyboardExpansion(persistence: .init(defaults: UserDefaults(suiteName: suite)!)).mode == .full)
        }
    }

    @Test func retainedKeyboardsReloadTheLatestGlobalChoice() {
        withDefaults { suite, defaults in
            var first = KeyboardExpansion(persistence: .init(defaults: defaults))
            var retained = KeyboardExpansion(persistence: .init(defaults: UserDefaults(suiteName: suite)!))
            first.toggle()
            #expect(retained.mode == .full)
            retained.reload()
            #expect(retained.mode == .minimised)
            retained.toggle()
            first.reload()
            #expect(first.mode == .full)
        }
    }
}
