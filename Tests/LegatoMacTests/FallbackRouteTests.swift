import Testing
@testable import LegatoMac

@Suite struct FallbackRouteTests {
    @Test func pastesWhenTrustedAndTargetStillFrontmost() {
        #expect(FallbackRoute.route(axTrusted: true, frontmostIsTarget: true) == .pasteKeystroke)
    }

    @Test func copiesWhenAccessibilityIsMissing() {
        #expect(FallbackRoute.route(axTrusted: false, frontmostIsTarget: true) == .copyOnly)
    }

    @Test func copiesWhenAnotherAppIsFrontmost() {
        #expect(FallbackRoute.route(axTrusted: true, frontmostIsTarget: false) == .copyOnly)
    }

    @Test func copiesWhenNeither() {
        #expect(FallbackRoute.route(axTrusted: false, frontmostIsTarget: false) == .copyOnly)
    }
}
