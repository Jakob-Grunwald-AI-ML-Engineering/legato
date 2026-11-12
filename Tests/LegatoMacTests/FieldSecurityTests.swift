import Testing
@testable import LegatoMac

@Suite struct FieldSecurityTests {
    @Test func onlyAPositiveIdentificationIsAPasswordField() {
        #expect(FieldSecurity.classify(secureInput: true, subrole: .absent, role: .value("AXTextArea")) == .password)
        #expect(FieldSecurity.classify(secureInput: false, subrole: .value("AXSecureTextField"), role: .value("AXTextField")) == .password)
        #expect(FieldSecurity.classify(secureInput: false, subrole: .absent, role: .value("AXSecureTextField")) == .password)
        // A role that merely mentions "secure" is not a password field.
        #expect(FieldSecurity.classify(secureInput: false, subrole: .value("AXSecureSearchThing"), role: .value("AXTextField")) == .notPassword)
        #expect(FieldSecurity.classify(secureInput: false, subrole: .absent, role: .value("AXTextArea")) == .notPassword)
        #expect(FieldSecurity.classify(secureInput: false, subrole: .value(nil), role: .absent) == .notPassword)
    }

    @Test func aFailedReadIsUnknownNeverPassword() {
        #expect(FieldSecurity.classify(secureInput: false, subrole: .failed, role: .value("AXTextArea")) == .unknown)
        #expect(FieldSecurity.classify(secureInput: false, subrole: .absent, role: .failed) == .unknown)
        #expect(FieldSecurity.classify(secureInput: false, subrole: .failed, role: .failed) == .unknown)
        // A failure next to a positive identification is still a password field.
        #expect(FieldSecurity.classify(secureInput: false, subrole: .failed, role: .value("AXSecureTextField")) == .password)
    }

    @Test func anUnknownFieldDictatesThroughThePanelAndNoFieldIsCopyOnly() {
        // Still unknown after the warm-up, the capture reports no readable field.
        for mode in PanelDictationSetting.Mode.allCases {
            #expect(PanelDictationPolicy.usesPanel(mode, field: .unreadable))
            #expect(PanelDictationPolicy.usesPanel(mode, field: .password))
        }
    }
}
