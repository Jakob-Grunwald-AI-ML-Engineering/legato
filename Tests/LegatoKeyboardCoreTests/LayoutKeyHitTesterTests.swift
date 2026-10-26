import Foundation
import Testing
@testable import LegatoKeyboardCore

@Suite struct LayoutKeyHitTesterTests {
    // Two rows, 3 keys each, 100x40 keys with 10pt gaps; margin 5 at left/top.
    private func tester() -> KeyHitTester {
        var frames: [KeyFrame] = []
        for row in 0..<2 {
            for col in 0..<3 {
                frames.append(KeyFrame(id: "\(row).\(col)", row: row,
                    rect: KeyRect(x: 5 + Double(col) * 110, y: 5 + Double(row) * 50, width: 100, height: 40)))
            }
        }
        return KeyHitTester(frames: frames)
    }

    @Test func insideAKey() {
        #expect(tester().key(at: KeyPoint(x: 60, y: 25)) == "0.0")
        #expect(tester().key(at: KeyPoint(x: 280, y: 75)) == "1.2")
    }

    @Test func horizontalGapGoesToNearest() {
        #expect(tester().key(at: KeyPoint(x: 107, y: 25)) == "0.0")
        #expect(tester().key(at: KeyPoint(x: 113, y: 25)) == "0.1")
    }

    @Test func verticalGapGoesToNearestRow() {
        #expect(tester().key(at: KeyPoint(x: 60, y: 47)) == "0.0")
        #expect(tester().key(at: KeyPoint(x: 60, y: 53)) == "1.0")
    }

    @Test func gapIntersectionGoesToNearestKey() {
        #expect(tester().key(at: KeyPoint(x: 112, y: 52)) == "1.1")
    }

    @Test func edgeKeysExtendToTheBorder() {
        #expect(tester().key(at: KeyPoint(x: 0, y: 25)) == "0.0")
        #expect(tester().key(at: KeyPoint(x: 500, y: 25)) == "0.2")
        #expect(tester().key(at: KeyPoint(x: 60, y: 0)) == "0.0")
        #expect(tester().key(at: KeyPoint(x: 60, y: 200)) == "1.0")
        #expect(tester().key(at: KeyPoint(x: 999, y: 999)) == "1.2")
    }

    @Test func noFramesNoHit() {
        #expect(KeyHitTester(frames: []).key(at: KeyPoint(x: 1, y: 1)) == nil)
    }

    @Test func worksWithLayoutWidths() {
        let frames = KeyboardLayout.page(.letters).frames(in: KeyRect(x: 0, y: 0, width: 400, height: 200), spacing: 0)
        let t = KeyHitTester(frames: frames)
        #expect(t.key(at: KeyPoint(x: 1, y: 10)) == "char:q")
        #expect(t.key(at: KeyPoint(x: 399, y: 10)) == "char:p")
        #expect(t.key(at: KeyPoint(x: 200, y: 199)) == "space")
    }
}
