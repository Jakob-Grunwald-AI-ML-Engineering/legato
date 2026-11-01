import Foundation
import Testing
@testable import LegatoAppServices

struct ComposerMicrophonePreferenceTests {
    @Test func freshInstallKeepsExplicitlyArmedMicrophoneAvailable() {
        let defaults = UserDefaults(suiteName: "composer-mic-default-\(UUID())")!
        #expect(ComposerMicrophonePreference.keepActive(in: defaults))
    }

    @Test func backgroundMicrophoneChoicePersistsAcrossReaders() {
        let suite = "composer-mic-choice-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        ComposerMicrophonePreference.setKeepActive(false, in: defaults)
        #expect(!ComposerMicrophonePreference.keepActive(in: UserDefaults(suiteName: suite)!))
        ComposerMicrophonePreference.setKeepActive(true, in: defaults)
        #expect(ComposerMicrophonePreference.keepActive(in: UserDefaults(suiteName: suite)!))
    }
}
