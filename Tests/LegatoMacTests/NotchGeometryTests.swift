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
    @Test func islandReachesScreenTopAtComposerHeights() {
        let screen = CGRect(x: 0, y: 0, width: 1512, height: 982), visible = CGRect(x: 0, y: 40, width: 1512, height: 910)
        let closed = NotchGeometry.island(screen: screen, visible: visible, safeTop: 32, height: 230)
        #expect(closed == CGRect(x: 450, y: 720, width: 612, height: 262))
        let tall = NotchGeometry.island(screen: screen, visible: visible, safeTop: 32, height: 440)
        #expect(tall.maxY == 982 && tall.height == 472)
        #expect(tall.midX == screen.midX)
    }
    @Test func islandFollowsThe16InchNotchAtPillHeights() {
        let screen = CGRect(x: 0, y: 0, width: 1728, height: 1117), visible = CGRect(x: 0, y: 0, width: 1728, height: 1117)
        let pill = NotchGeometry.island(screen: screen, visible: visible, safeTop: 38, width: 460, height: 64)
        #expect(pill == CGRect(x: 618, y: 1015, width: 492, height: 102))
        let failed = NotchGeometry.island(screen: screen, visible: visible, safeTop: 38, width: 460, height: 112)
        #expect(failed.maxY == pill.maxY && failed.height == 150)
    }
    @Test func islandWithoutNotchIsTheDetachedCard() {
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900), visible = CGRect(x: 0, y: 0, width: 1440, height: 876)
        let island = NotchGeometry.island(screen: screen, visible: visible, safeTop: 0, height: 188)
        #expect(island == NotchGeometry.frame(screen: screen, visible: visible, safeTop: 0, height: 188))
        #expect(island.maxY == 868 && island.width == 580)
    }
    @Test func islandOnExternalDisplayKeepsItsOrigin() {
        let island = NotchGeometry.island(screen: CGRect(x: -1920, y: 200, width: 1920, height: 1080), visible: CGRect(x: -1920, y: 200, width: 1920, height: 1056), safeTop: 0, width: 460, height: 64)
        #expect(island.midX == -960 && island.maxY == 1248 && island.width == 460)
    }
    @Test func islandWithHiddenMenuBarStillReachesTheTop() {
        let island = NotchGeometry.island(screen: CGRect(x: 0, y: 0, width: 1512, height: 982), visible: CGRect(x: 0, y: 0, width: 1512, height: 982), safeTop: 32, height: 188)
        #expect(island.maxY == 982 && island.height == 220)
    }
    @Test func islandStaysOnNarrowScreens() {
        let island = NotchGeometry.island(screen: CGRect(x: 0, y: 0, width: 500, height: 800), visible: CGRect(x: 0, y: 0, width: 500, height: 770), safeTop: 32, height: 188)
        #expect(island.width == 476 && island.minX == 12)
    }
    @Test func notchWidthIsTheGapBetweenAuxiliaryAreas() {
        let width = NotchGeometry.notchWidth(left: CGRect(x: 0, y: 950, width: 656, height: 32), right: CGRect(x: 856, y: 950, width: 656, height: 32))
        #expect(width == 200)
    }
    @Test func notchWidthFallsBackWithoutAreas() {
        #expect(NotchGeometry.notchWidth(left: nil, right: nil) == 185)
        #expect(NotchGeometry.notchWidth(left: CGRect(x: 0, y: 0, width: 600, height: 32), right: nil, fallback: 150) == 150)
        #expect(NotchGeometry.notchWidth(left: CGRect(x: 0, y: 0, width: 800, height: 32), right: CGRect(x: 700, y: 0, width: 100, height: 32)) == 185)
    }
}
