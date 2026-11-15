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

    @Test func aFirstLaunchShowsTheFullKeyboardWithACollapseControl() {
        withDefaults { _, defaults in
            let expansion = KeyboardExpansion(persistence: .init(defaults: defaults))
            #expect(expansion.mode == .full)
            #expect(expansion.control == .collapse)
        }
        #expect(KeyboardExpansion().mode == .full)
    }

    @Test func togglingCollapsesAndExpandsAgain() {
        var expansion = KeyboardExpansion()
        expansion.toggle()
        #expect(expansion.mode == .strip)
        #expect(expansion.control == .expand)
        expansion.toggle()
        #expect(expansion.mode == .full)
        #expect(expansion.control == .collapse)
    }

    @Test func theLastChoiceSurvivesRecreatingTheKeyboard() {
        withDefaults { suite, defaults in
            var first = KeyboardExpansion(persistence: .init(defaults: defaults))
            first.toggle()
            var recreated = KeyboardExpansion(persistence: .init(defaults: UserDefaults(suiteName: suite)!))
            #expect(recreated.mode == .strip)
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
            #expect(retained.mode == .strip)
            retained.toggle()
            first.reload()
            #expect(first.mode == .full)
        }
    }

    // MARK: height

    @Test func theHeightCandidatesAreTheExperimentsList() {
        #expect(StripHeight.candidates == [0, 1, 30, 54])
    }

    @Test func cyclingWalksTheCandidatesAndWrapsAround() {
        var height = StripHeight.candidates[0]
        var seen = [height]
        for _ in 0..<StripHeight.candidates.count {
            height = StripHeight.next(after: height)
            seen.append(height)
        }
        #expect(seen == [0, 1, 30, 54, 0])
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
        var expansion = KeyboardExpansion()
        #expect(expansion.swipeToggles(dx: -4, dy: 40))
        expansion.toggle()
        #expect(expansion.swipeToggles(dx: 4, dy: -40))
    }

    @Test func aSwipeTheOtherWayShortOrSidewaysDoesNothing() {
        var expansion = KeyboardExpansion()
        #expect(!expansion.swipeToggles(dx: 0, dy: -40))
        #expect(!expansion.swipeToggles(dx: 0, dy: 10))
        #expect(!expansion.swipeToggles(dx: 60, dy: 40))
        expansion.toggle()
        #expect(!expansion.swipeToggles(dx: 0, dy: 40))
    }
}
