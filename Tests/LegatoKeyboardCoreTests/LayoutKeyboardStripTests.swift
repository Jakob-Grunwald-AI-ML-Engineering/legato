import Foundation
import Testing
@testable import LegatoKeyboardCore

@Suite struct LayoutKeyboardStripTests {
    private func withDefaults(_ body: (String, UserDefaults) -> Void) {
        let suite = "LayoutKeyboardStripTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        body(suite, defaults)
    }

    @Test func expandedChoiceSurvivesRecreatingTheKeyboardAndDefaults() {
        withDefaults { suite, defaults in
            var first = KeyboardExpansion(stripEnabled: true, persistence: .init(defaults: defaults))
            first.toggle()
            let recreated = KeyboardExpansion(stripEnabled: true, persistence: .init(defaults: UserDefaults(suiteName: suite)!))
            #expect(recreated.mode == .full)
            #expect(recreated.control == .collapse)
        }
    }

    @Test func collapsedChoiceSurvivesRecreatingTheKeyboardAndDefaults() {
        withDefaults { suite, defaults in
            var first = KeyboardExpansion(stripEnabled: true, persistence: .init(defaults: defaults))
            first.toggle()
            var expanded = KeyboardExpansion(stripEnabled: true, persistence: .init(defaults: UserDefaults(suiteName: suite)!))
            #expect(expanded.mode == .full)
            expanded.toggle()
            let recreated = KeyboardExpansion(stripEnabled: true, persistence: .init(defaults: UserDefaults(suiteName: suite)!))
            #expect(recreated.mode == .strip)
            #expect(recreated.control == .expand)
        }
    }

    @Test func disabledCompactSettingOverridesAndResetsTheRememberedChoice() {
        withDefaults { suite, defaults in
            var first = KeyboardExpansion(stripEnabled: true, persistence: .init(defaults: defaults))
            first.toggle()
            #expect(KeyboardExpansion(stripEnabled: true, persistence: .init(defaults: defaults)).mode == .full)
            let disabled = KeyboardExpansion(stripEnabled: false, persistence: .init(defaults: UserDefaults(suiteName: suite)!))
            #expect(disabled.mode == .full)
            #expect(disabled.control == nil)
            let enabled = KeyboardExpansion(stripEnabled: true, persistence: .init(defaults: UserDefaults(suiteName: suite)!))
            #expect(enabled.mode == .strip)
        }
    }

    @Test func changingTheSettingPersistsTheCollapsedReset() {
        withDefaults { suite, defaults in
            var first = KeyboardExpansion(stripEnabled: true, persistence: .init(defaults: defaults))
            first.toggle()
            var expanded = KeyboardExpansion(stripEnabled: true, persistence: .init(defaults: UserDefaults(suiteName: suite)!))
            #expect(expanded.mode == .full)
            expanded.setStripEnabled(false)
            expanded.setStripEnabled(true)
            let recreated = KeyboardExpansion(stripEnabled: true, persistence: .init(defaults: UserDefaults(suiteName: suite)!))
            #expect(recreated.mode == .strip)
        }
    }

    @Test func withoutTheStripSettingTheKeyboardIsFullAndHasNoToggle() {
        let expansion = KeyboardExpansion(stripEnabled: false)
        #expect(expansion.mode == .full)
        #expect(expansion.control == nil)
    }

    @Test func withTheStripSettingASessionStartsCollapsedWithAnExpandControl() {
        let expansion = KeyboardExpansion(stripEnabled: true)
        #expect(expansion.mode == .strip)
        #expect(expansion.control == .expand)
    }

    @Test func togglingExpandsAndCollapsesAgain() {
        var expansion = KeyboardExpansion(stripEnabled: true)
        expansion.toggle()
        #expect(expansion.mode == .full)
        #expect(expansion.control == .collapse)
        expansion.toggle()
        #expect(expansion.mode == .strip)
        #expect(expansion.control == .expand)
    }

    @Test func togglingWithoutTheStripSettingDoesNothing() {
        var expansion = KeyboardExpansion(stripEnabled: false)
        expansion.toggle()
        #expect(expansion.mode == .full)
        #expect(expansion.control == nil)
    }

    @Test func changingTheSettingStartsASessionAgainCollapsed() {
        var expansion = KeyboardExpansion(stripEnabled: true)
        expansion.toggle()
        expansion.setStripEnabled(false)
        #expect(expansion.mode == .full)
        expansion.setStripEnabled(true)
        #expect(expansion.mode == .strip)
    }

    @Test func theSameSettingKeepsTheExpandedState() {
        var expansion = KeyboardExpansion(stripEnabled: true)
        expansion.toggle()
        expansion.setStripEnabled(true)
        #expect(expansion.mode == .full)
    }

    // MARK: height

    @Test func theHeightCandidatesAreTheExperimentsList() {
        #expect(StripHeight.candidates == [0, 1, 30, 44, 56])
    }

    @Test func cyclingWalksTheCandidatesAndWrapsAround() {
        var height = StripHeight.candidates[0]
        var seen = [height]
        for _ in 0..<StripHeight.candidates.count {
            height = StripHeight.next(after: height)
            seen.append(height)
        }
        #expect(seen == [0, 1, 30, 44, 56, 0])
    }

    @Test func cyclingFromAnUnknownHeightStartsTheList() {
        #expect(StripHeight.next(after: 37) == 0)
    }

    @Test func aStoredHeightOutsideTheCandidatesFallsBackToTheStandard() {
        #expect(StripHeight.resolve(stored: nil) == StripHeight.standard)
        #expect(StripHeight.resolve(stored: 37) == StripHeight.standard)
        #expect(StripHeight.resolve(stored: 1) == 1)
        #expect(StripHeight.resolve(stored: 0) == 0)
    }

    @Test func aSwipeUpOnTheStripExpandsAndASwipeDownOnTheFullKeyboardCollapses() {
        var expansion = KeyboardExpansion(stripEnabled: true)
        #expect(expansion.swipeToggles(dx: 4, dy: -40))
        expansion.toggle()
        #expect(expansion.swipeToggles(dx: -4, dy: 40))
    }

    @Test func aSwipeTheOtherWayShortOrSidewaysDoesNothing() {
        var expansion = KeyboardExpansion(stripEnabled: true)
        #expect(!expansion.swipeToggles(dx: 0, dy: 40))
        #expect(!expansion.swipeToggles(dx: 0, dy: -10))
        #expect(!expansion.swipeToggles(dx: 60, dy: -40))
        expansion.toggle()
        #expect(!expansion.swipeToggles(dx: 0, dy: -40))
    }

    @Test func withoutTheStripSettingNoSwipeToggles() {
        let expansion = KeyboardExpansion(stripEnabled: false)
        #expect(!expansion.swipeToggles(dx: 0, dy: -40))
        #expect(!expansion.swipeToggles(dx: 0, dy: 40))
    }
}
