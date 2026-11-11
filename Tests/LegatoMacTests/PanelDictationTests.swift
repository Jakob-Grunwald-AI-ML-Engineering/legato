import Foundation
import Testing
@testable import LegatoMac

@Suite struct PanelDictationPolicyTests {
    @Test func onlyFieldsThatCannotBeEditedLiveUseThePanelByDefault() {
        #expect(PanelDictationSetting.defaultMode == .whenNeeded)
        #expect(!PanelDictationPolicy.usesPanel(.whenNeeded, field: .liveEditable))
        #expect(PanelDictationPolicy.usesPanel(.whenNeeded, field: .readOnly))
        #expect(PanelDictationPolicy.usesPanel(.whenNeeded, field: .unreadable))
    }

    @Test func alwaysCoversEveryFieldExceptASecureOne() {
        #expect(PanelDictationPolicy.usesPanel(.always, field: .liveEditable))
        #expect(PanelDictationPolicy.usesPanel(.always, field: .unreadable))
        #expect(!PanelDictationPolicy.usesPanel(.always, field: .secure))
        #expect(!PanelDictationPolicy.usesPanel(.whenNeeded, field: .secure))
    }

    @Test func theStoredSettingFallsBackToTheDefault() throws {
        let defaults = try #require(UserDefaults(suiteName: "panel-dictation-\(UUID().uuidString)"))
        #expect(PanelDictationSetting.mode(in: defaults) == .whenNeeded)
        defaults.set("always", forKey: PanelDictationSetting.key)
        #expect(PanelDictationSetting.mode(in: defaults) == .always)
        defaults.set("bogus", forKey: PanelDictationSetting.key)
        #expect(PanelDictationSetting.mode(in: defaults) == .whenNeeded)
    }
}

@Suite struct PanelTakeTests {
    @Test func piecesJoinInSpeakingOrderAndALateRevisionReplacesItsPiece() {
        var take = PanelTake()
        take.live(id: "a", text: "hello there", complete: false)
        take.live(id: "a", text: "Hello there.", complete: true)
        take.line("Second line.")
        take.live(id: "a", text: "Hello, there.", complete: true)
        #expect(take.text == "Hello, there. Second line.")
        #expect(!take.isGrowing)
    }

    @Test func aGrowingPieceHoldsBackOnlyWhatFollowsIt() {
        var take = PanelTake()
        take.line(id: "1", "Done.")
        take.stream(id: "2", text: "Still clea", final: false)
        take.line(id: "3", "After.")
        #expect(take.isGrowing)
        let taken = take.takeFinished(); #expect(taken == "Done.")
        #expect(take.text == "Still clea After.")
        take.stream(id: "2", text: "", final: true, retracted: true)
        let rest = take.takeFinished(); #expect(rest == " After.")
        #expect(take.isEmpty)
    }

    @Test func aPieceAlreadyTypedIsNeverTypedAgain() {
        var take = PanelTake()
        take.live(id: "run", text: "Typed.", complete: true)
        let taken = take.takeFinished(); #expect(taken == "Typed.")
        take.live(id: "run", text: "Typed, revised.", complete: true)
        #expect(take.isEmpty)
        let again = take.takeFinished(); #expect(again == "")
    }

    @Test func aNewLineAfterTypedTextGetsNoSpace() {
        var take = PanelTake()
        take.line("One.")
        _ = take.takeFinished()
        take.line("\nTwo.")
        let taken = take.takeFinished(); #expect(taken == "\nTwo.")
    }
}

@Suite struct AccessibilityWarmupTests {
    @Test func theTreeIsRequestedAtMostOncePerBudgetAndRetriesOnlyWithinIt() {
        var warmup = AccessibilityWarmup()
        let start = ContinuousClock.now
        let first = warmup.shouldRequest(pid: 42, now: start)
        let second = warmup.shouldRequest(pid: 42, now: start + .milliseconds(10))
        #expect(first && !second)
        #expect(warmup.retryDeadline(pid: 42, now: start + .milliseconds(100)) == start + AccessibilityWarmup.budget)
        #expect(warmup.retryDeadline(pid: 42, now: start + AccessibilityWarmup.budget) == nil)
        #expect(warmup.retryDeadline(pid: 7, now: start) == nil)
        // A request that did not take (sent while the app launched) is repeated once the budget passed.
        let repeated = warmup.shouldRequest(pid: 42, now: start + AccessibilityWarmup.budget)
        #expect(repeated)
        warmup.forget(pid: 42)
        let afresh = warmup.shouldRequest(pid: 42, now: start + AccessibilityWarmup.budget + .milliseconds(1))
        #expect(afresh)
    }

    @Test func theBudgetStaysShortOfHalfASecond() {
        #expect(AccessibilityWarmup.budget <= .milliseconds(500))
        #expect(AccessibilityWarmup.interval >= .milliseconds(20))
    }

    @MainActor @Test func retryStopsAtTheDeadlineOrTheFirstValue() async {
        let start = ContinuousClock.now
        var clock = start, probes = 0
        let none: Int? = await AccessibilityWarmup.retry(until: start + .milliseconds(200), interval: .milliseconds(50),
                                                           now: { clock }, sleep: { clock += $0 }) { probes += 1; return nil }
        #expect(none == nil)
        #expect(probes == 5) // at 0, 50, 100, 150 and 200 ms
        probes = 0; clock = start
        let found = await AccessibilityWarmup.retry(until: start + .seconds(1), interval: .milliseconds(50),
                                                    now: { clock }, sleep: { clock += $0 }) { probes += 1; return probes == 3 ? probes : nil }
        #expect(found == 3)
        probes = 0
        let once: Int? = await AccessibilityWarmup.retry(until: nil, sleep: { _ in Issue.record("no wait without a request") }) { probes += 1; return nil }
        #expect(once == nil && probes == 1)
    }
}

@Suite struct ChromiumHostTests {
    @Test func browsersWebAppShimsAndElectronMatchNativeAppsDoNot() {
        let icu: (String) -> Bool = { $0.hasSuffix("Framework.framework/Resources/icudtl.dat") }
        #expect(ChromiumHost.matches(executableName: "Google Chrome", frameworks: ["Google Chrome Framework.framework"], fileExists: icu))
        #expect(ChromiumHost.matches(executableName: "app_mode_loader", frameworks: [], fileExists: { _ in false }))
        #expect(ChromiumHost.matches(executableName: "Slack", frameworks: ["Electron Framework.framework", "Squirrel.framework"], fileExists: { _ in false }))
        #expect(!ChromiumHost.matches(executableName: "Pages", frameworks: ["Some Framework.framework"], fileExists: { _ in false }))
        #expect(!ChromiumHost.matches(executableName: "TextEdit", frameworks: [], fileExists: icu))
    }
}
