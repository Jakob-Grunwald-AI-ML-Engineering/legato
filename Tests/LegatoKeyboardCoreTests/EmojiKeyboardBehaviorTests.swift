import Foundation
import Testing
@testable import LegatoKeyboardCore

@Suite struct EmojiKeyboardBehaviorTests {
    @Test func appSettingRoundTripsToAnotherDefaultsReader() throws {
        let suite = "EmojiKeyboardBehaviorTests.\(UUID().uuidString)"
        let app = try #require(UserDefaults(suiteName: suite))
        defer { app.removePersistentDomain(forName: suite) }
        #expect(!EmojiKeyboardBehavior.usesSystemSwitcher(in: app))
        EmojiKeyboardBehavior.setUsesSystemSwitcher(true, in: app)
        let keyboard = try #require(UserDefaults(suiteName: suite))
        #expect(EmojiKeyboardBehavior.usesSystemSwitcher(in: keyboard))
        EmojiKeyboardBehavior.setUsesSystemSwitcher(false, in: app)
        #expect(!EmojiKeyboardBehavior.usesSystemSwitcher(in: keyboard))
    }

    @Test func unknownStoredValueFallsBackToLocalPanel() throws {
        let suite = "EmojiKeyboardBehaviorTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("future-mode", forKey: EmojiKeyboardBehavior.preferenceKey)
        #expect(!EmojiKeyboardBehavior.usesSystemSwitcher(in: defaults))
    }

    @Test func textFieldsOfferPanelWhileNumericAndCredentialFieldsDoNot() {
        #expect(EmojiKeyboardBehavior.offersLocalPanel(numeric: false, secure: false, contentType: nil))
        #expect(!EmojiKeyboardBehavior.offersLocalPanel(numeric: true, secure: false, contentType: nil))
        #expect(!EmojiKeyboardBehavior.offersLocalPanel(numeric: false, secure: true, contentType: nil))
        for type in ["username", "password", "newPassword", "oneTimeCode"] {
            #expect(!EmojiKeyboardBehavior.offersLocalPanel(numeric: false, secure: false, contentType: type))
        }
    }
}
