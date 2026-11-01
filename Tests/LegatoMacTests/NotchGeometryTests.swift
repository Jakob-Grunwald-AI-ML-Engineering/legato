import Foundation
import Testing
@testable import LegatoMac

@Suite struct NotchGeometryTests {
    @Test func notchPanelStartsBelowCamera() {
        let frame = NotchGeometry.frame(screen: CGRect(x: 0, y: 0, width: 1512, height: 982), visible: CGRect(x: 0, y: 40, width: 1512, height: 910), safeTop: 32)
        #expect(frame == CGRect(x: 466, y: 590, width: 580, height: 360))
    }
    @Test func noNotchUsesMenuBarBottom() {
        let frame = NotchGeometry.frame(screen: CGRect(x: 0, y: 0, width: 1440, height: 900), visible: CGRect(x: 0, y: 0, width: 1440, height: 876), safeTop: 0)
        #expect(frame.maxY == 868)
    }
    @Test func externalDisplayKeepsItsOwnOrigin() {
        let frame = NotchGeometry.frame(screen: CGRect(x: -1920, y: 200, width: 1920, height: 1080), visible: CGRect(x: -1920, y: 200, width: 1920, height: 1056), safeTop: 0)
        #expect(frame.midX == -960)
        #expect(frame.maxY == 1248)
    }
    @Test func hiddenMenuBarStillClearsNotch() {
        let frame = NotchGeometry.frame(screen: CGRect(x: 0, y: 0, width: 1512, height: 982), visible: CGRect(x: 0, y: 0, width: 1512, height: 982), safeTop: 32)
        #expect(frame.maxY == 950)
    }
}
