import Foundation
import Testing
@testable import LegatoAppServices
import LegatoAgent

@Suite struct DictationSendSettingTests {
    private func defaults() -> UserDefaults {
        let name = "dictation-send-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test func defaultsToLiveWithAFiveSecondPauseAndHaikuCleanup() {
        let store = defaults()
        #expect(DictationSendSetting.mode(in: store) == .live)
        #expect(DictationSendSetting.pause(in: store) == 5)
        #expect(DictationSendSetting.cleanupModel(in: store) == .haiku)
    }

    @Test func theCleanupModelIsHaikuOrSonnet() {
        let store = defaults()
        store.set("sonnet", forKey: DictationSendSetting.cleanupModelKey)
        #expect(DictationSendSetting.cleanupModel(in: store) == .sonnet)
        store.set("opus", forKey: DictationSendSetting.cleanupModelKey)
        #expect(DictationSendSetting.cleanupModel(in: store) == .haiku)
        #expect(ModelChoice.cleanupChoices.map(\.settingValue) == ["haiku", "sonnet"])
    }

    @Test func storedModesRoundTripAndUnknownValuesFallBack() {
        let store = defaults()
        for mode in DictationSendSetting.Mode.allCases {
            store.set(mode.rawValue, forKey: DictationSendSetting.modeKey)
            #expect(DictationSendSetting.mode(in: store) == mode)
        }
        store.set("nonsense", forKey: DictationSendSetting.modeKey)
        #expect(DictationSendSetting.mode(in: store) == .live)
    }

    @Test func thePauseIsClampedToOneToTenSeconds() {
        #expect(DictationSendSetting.clampedPause(0) == 1)
        #expect(DictationSendSetting.clampedPause(-3) == 1)
        #expect(DictationSendSetting.clampedPause(3) == 3)
        #expect(DictationSendSetting.clampedPause(10) == 10)
        #expect(DictationSendSetting.clampedPause(99) == 10)
        #expect(DictationSendSetting.clampedPause(.nan) == 5)
        let store = defaults()
        store.set(42.0, forKey: DictationSendSetting.pauseKey)
        #expect(DictationSendSetting.pause(in: store) == 10)
        store.set(0.2, forKey: DictationSendSetting.pauseKey)
        #expect(DictationSendSetting.pause(in: store) == 1)
    }
}
