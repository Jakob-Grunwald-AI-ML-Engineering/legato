import Testing
@testable import LegatoMac

@Suite struct FallbackRouteTests {
    @Test func pastesWhenTrustedAndTargetStillFrontmost() {
        #expect(FallbackRoute.route(axTrusted: true, frontmostIsTarget: true) == .pasteKeystroke)
    }

    @Test func copiesWhenAccessibilityIsMissing() {
        #expect(FallbackRoute.route(axTrusted: false, frontmostIsTarget: true) == .copyOnly(.accessibilityMissing))
    }

    @Test func copiesWhenAnotherAppIsFrontmost() {
        #expect(FallbackRoute.route(axTrusted: true, frontmostIsTarget: false) == .copyOnly(.appChanged))
    }

    @Test func copiesWhenNeither() {
        #expect(FallbackRoute.route(axTrusted: false, frontmostIsTarget: false) == .copyOnly(.accessibilityMissing))
    }
}

@Suite struct FallbackRouteGuardTests {
    @Test func copiesIntoASecureField() {
        #expect(FallbackRoute.route(axTrusted: true, frontmostIsTarget: true, secureField: true) == .copyOnly(.secureField))
    }

    @Test func copiesWhenModifiersAreStillHeld() {
        #expect(FallbackRoute.route(axTrusted: true, frontmostIsTarget: true, modifiersReleased: false) == .copyOnly(.modifiersHeld))
    }

    @Test func pastesOnlyWhenEveryGuardPasses() {
        #expect(FallbackRoute.route(axTrusted: true, frontmostIsTarget: true, secureField: false, modifiersReleased: true) == .pasteKeystroke)
    }
}

@Suite struct CopyReasonTests {
    @Test func onlyHeldModifiersPass() {
        #expect(CopyReason.modifiersHeld.latches == false)
        #expect([CopyReason.accessibilityMissing, .secureField, .appChanged].allSatisfy { $0.latches })
    }

    @Test func theMostLastingReasonWins() {
        #expect(FallbackRoute.route(axTrusted: true, frontmostIsTarget: false, secureField: true, modifiersReleased: false) == .copyOnly(.secureField))
        #expect(FallbackRoute.route(axTrusted: true, frontmostIsTarget: false, modifiersReleased: false) == .copyOnly(.appChanged))
    }
}

@MainActor @Suite struct ModifierWaitTests {
    @Test func waitsForTheReleaseNotAFixedSecond() async {
        var polls = 0
        var slept = Duration.zero
        let released = await ModifierWait.untilReleased(held: { polls += 1; return polls <= 200 }, sleep: { slept += $0 })
        #expect(released && slept > .seconds(1), "Modifiers held for four seconds still end in a paste")
    }

    @Test func givesUpAtTheCap() async {
        var slept = Duration.zero
        let released = await ModifierWait.untilReleased(held: { true }, cap: .seconds(2), sleep: { slept += $0 })
        #expect(!released && slept == .seconds(2))
    }

    @Test func returnsAtOnceWhenNothingIsHeld() async {
        var slept = Duration.zero
        #expect(await ModifierWait.untilReleased(held: { false }, sleep: { slept += $0 }))
        #expect(slept == .zero)
    }
}

@Suite struct HotkeyTapFilterTests {
    private let keyV: UInt16 = 9
    private let commandFlag = UInt64(1 << 20)

    @Test func aTaggedCommandVIsIgnored() {
        #expect(HotkeyTapFilter.keyEvent(kind: .keyDown, keyCode: keyV, flagsRaw: commandFlag, userData: SyntheticEvent.userData) == nil)
        #expect(HotkeyTapFilter.keyEvent(kind: .keyUp, keyCode: keyV, flagsRaw: commandFlag, userData: SyntheticEvent.userData) == nil)
    }

    @Test func anUntaggedCommandVIsTheUsersAndKeepsOnlyDeviceIndependentFlags() {
        let event = HotkeyTapFilter.keyEvent(kind: .keyDown, keyCode: keyV, flagsRaw: commandFlag | 0x8, userData: 0)
        #expect(event == KeyEvent(kind: .keyDown, keyCode: keyV, flags: .command))
    }
}
