import Foundation
import Testing
@testable import LegatoAppServices

@Test func pauseClampsToTheSupportedRangeAndStep() {
    #expect(InstructionSendSetting.clampedPause(0) == 1.0)
    #expect(InstructionSendSetting.clampedPause(9) == 5.0)
    #expect(InstructionSendSetting.clampedPause(2.3) == 2.5)
    #expect(InstructionSendSetting.clampedPause(2.2) == 2.0)
    #expect(InstructionSendSetting.clampedPause(.nan) == 2.0)
}

@Test func settingDefaultsToManualAndReadsAutomaticLive() throws {
    let suite = "instruction-send-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    #expect(InstructionSendSetting.mode(in: defaults) == .manual)
    #expect(InstructionSendSetting.automaticDelay(in: defaults) == nil)
    defaults.set("automatic", forKey: InstructionSendSetting.modeKey)
    #expect(InstructionSendSetting.automaticDelay(in: defaults) == 2.0)
    defaults.set(7.0, forKey: InstructionSendSetting.pauseKey)
    #expect(InstructionSendSetting.automaticDelay(in: defaults) == 5.0)
    defaults.set("bogus", forKey: InstructionSendSetting.modeKey)
    #expect(InstructionSendSetting.automaticDelay(in: defaults) == nil)
}
