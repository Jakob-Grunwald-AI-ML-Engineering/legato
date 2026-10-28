import Testing
@testable import LegatoKeyboardCore

@Suite struct AutoFillHandoffTests {
    @Test(arguments: ["username", "password", "newPassword", "oneTimeCode"])
    func credentialFieldsOfferAction(_ type: String) {
        #expect(AutoFillHandoff.offersAction(contentType: type))
    }

    @Test(arguments: [nil, "emailAddress", "URL", "name", "telephoneNumber", "USERNAME"] as [String?])
    func ordinaryFieldsDoNotOfferAction(_ type: String?) {
        #expect(!AutoFillHandoff.offersAction(contentType: type))
    }

    @Test func automaticSwitchingIsOptIn() {
        var policy = AutoFillHandoff()
        #expect(!AutoFillHandoff.defaultEnabled)
        let result1 = policy.shouldSwitch(documentID: "a", contentType: "username", visible: true, targetAvailable: true)
        #expect(!result1)
        let result2 = policy.shouldSwitch(documentID: "a", contentType: "username", enabled: true, visible: true, targetAvailable: true)
        #expect(result2)
    }

    @Test func returningToAnAttemptedFieldDoesNotSwitchAgain() {
        var policy = AutoFillHandoff()
        let result3 = policy.shouldSwitch(documentID: "a", contentType: "username", enabled: true, visible: true, targetAvailable: true)
        #expect(result3)
        let result4 = policy.shouldSwitch(documentID: "a", contentType: "username", enabled: true, visible: false, targetAvailable: true)
        #expect(!result4)
        let result5 = policy.shouldSwitch(documentID: "a", contentType: "username", enabled: true, visible: true, targetAvailable: true)
        #expect(!result5)
        let result6 = policy.shouldSwitch(documentID: "b", contentType: "oneTimeCode", enabled: true, visible: true, targetAvailable: true)
        #expect(result6)
        let result7 = policy.shouldSwitch(documentID: "a", contentType: "username", enabled: true, visible: true, targetAvailable: true)
        #expect(!result7)
    }

    @Test func readinessDoesNotConsumeAttempt() {
        var policy = AutoFillHandoff()
        let result8 = policy.shouldSwitch(documentID: nil, contentType: "username", enabled: true, visible: true, targetAvailable: true)
        #expect(!result8)
        let result9 = policy.shouldSwitch(documentID: "a", contentType: "username", enabled: true, visible: false, targetAvailable: true)
        #expect(!result9)
        let result10 = policy.shouldSwitch(documentID: "a", contentType: "username", enabled: true, visible: true, targetAvailable: false)
        #expect(!result10)
        let result11 = policy.shouldSwitch(documentID: "a", contentType: "username", enabled: true, visible: true, targetAvailable: true)
        #expect(result11)
    }

    @Test func changingCredentialTraitsOnSameDocumentAllowsOneNewAttempt() {
        var policy = AutoFillHandoff()
        let result12 = policy.shouldSwitch(documentID: "a", contentType: "emailAddress", enabled: true, visible: true, targetAvailable: true)
        #expect(!result12)
        let result13 = policy.shouldSwitch(documentID: "a", contentType: "username", enabled: true, visible: true, targetAvailable: true)
        #expect(result13)
        let result14 = policy.shouldSwitch(documentID: "a", contentType: "oneTimeCode", enabled: true, visible: true, targetAvailable: true)
        #expect(result14)
        let result15 = policy.shouldSwitch(documentID: "a", contentType: "username", enabled: true, visible: true, targetAvailable: true)
        #expect(!result15)
    }
}
