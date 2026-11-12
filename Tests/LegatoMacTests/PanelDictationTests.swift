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

    @Test func alwaysCoversEveryFieldAndAPasswordFieldIsAnyUnreadableField() {
        #expect(PanelDictationPolicy.usesPanel(.always, field: .liveEditable))
        #expect(PanelDictationPolicy.usesPanel(.always, field: .unreadable))
        #expect(PanelDictationPolicy.usesPanel(.always, field: .password))
        #expect(PanelDictationPolicy.usesPanel(.whenNeeded, field: .password))
    }

    @Test func theLivePillShowsNoWordsAndThePanelModePillShowsThemAll() {
        // Typing straight into the field (the default for a field that can be edited live): listening and controls only.
        #expect(DictationPillContent.forPolicy(.whenNeeded, field: .liveEditable) == .listeningControls)
        // Panel mode (always, or a field that cannot be edited live): the growing text.
        #expect(DictationPillContent.forPolicy(.always, field: .liveEditable) == .growingText)
        #expect(DictationPillContent.forPolicy(.whenNeeded, field: .unreadable) == .growingText)
        #expect(DictationPillContent.forPolicy(.whenNeeded, field: .readOnly) == .growingText)
        #expect(DictationPillContent.forPolicy(.whenNeeded, field: .password) == .growingText)
        #expect(DictationPillContent.forTake(panelActive: true) == .growingText)
        #expect(DictationPillContent.forTake(panelActive: false) == .listeningControls)
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

/// A take handed to the panel part-way (`MacFieldQueue.Handover`): what the field shows stays, the panel continues it.
@MainActor @Suite struct PanelContinuationTests {
    private func rest(_ text: String, typed: Int, _ versions: String...) -> String {
        var continuation = PanelContinuation(text: text, typed: typed)
        for version in versions { _ = continuation.rest(of: version) }
        return continuation.rest
    }

    @Test func theRestFollowsTheTypedWordsThroughRevisionsAndCleanup() {
        // A word still being spoken goes on from its typed letters.
        #expect(rest("Urg", typed: 3, "Urgent callback.") == "ent callback.")
        #expect(rest("ur", typed: 2, "Urgent callback.") == "gent callback.")
        // Cleanup capitalizes and adds a stop: the typed words are not typed again.
        #expect(rest("deck tide", typed: 5, "Deck tide.") == "tide.")
        // A typed word the revision replaced stays and stands for the new one; the rest starts after as many words.
        #expect(rest("deck tide", typed: 4, "Squall tide tide sail.") == " tide tide sail.")
        #expect(rest("deck t", typed: 6, "deck tide", "Squall tide tide sail.") == "ide tide sail.")
        #expect(rest("wind", typed: 3, "anchor wind", "Anchor wind harbor.") == " wind harbor.")
        #expect(rest("deck", typed: 0, "Deck tide.") == "Deck tide.")
        // The newest text has fewer words than the field shows: nothing more to type.
        #expect(rest("deck tide rope", typed: 14, "Deck tide.") == "")
    }

    @Test func theFieldShowsWhatItsRegionsTypedOfARun() {
        // A revision changed typed words: they stand for as many words of the newest text.
        #expect(MacFieldQueue.typedPrefix(current: Array("sail north"), desired: Array("sail wind harbor")) == 9)
        #expect(MacFieldQueue.typedPrefix(current: Array("sail nor"), desired: Array("sail north")) == 8)
        let region = MacFieldQueue.TypedRegion(current: Array(" deck t"), desired: Array(" deck tide"), source: Array("deck tide"),
                                               separator: [" "], original: [])
        #expect(MacFieldQueue.typedCount([region]) == 6)
        let untouched = MacFieldQueue.TypedRegion(current: Array("old"), desired: Array("new words"), source: Array("new words"),
                                                  separator: [], original: Array("old"))
        #expect(MacFieldQueue.typedCount([untouched]) == 0)
    }
}
