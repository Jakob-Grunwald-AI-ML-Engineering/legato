import SwiftUI
import Testing
@testable import LegatoComposerUI

struct WordEffectSurfaceTests {
    @Test func localEffectsHaveAConstantHaloIndependentOfDocumentHeight() {
        let near = CGRect(x: 20, y: 30, width: 90, height: 24)
        let distant = near.offsetBy(dx: 0, dy: 93_408)
        let a = WordEffectSurface.bounds(for: near)!
        let b = WordEffectSurface.bounds(for: distant)!
        #expect(a == near.insetBy(dx: -8, dy: -8))
        #expect(a.size == b.size)
        #expect(a.width * a.height * 3 * 3 * 4 < 1_179_648)
    }
    @Test func oversizedOrInvalidRunsDrawWithoutAnOffscreenEffect() {
        #expect(WordEffectSurface.bounds(for: CGRect(x: 0, y: 0, width: 423, height: 31_136)) == nil)
        #expect(WordEffectSurface.bounds(for: .infinite) == nil)
        #expect(WordEffectSurface.bounds(for: .null) == nil)
        #expect(WordEffectSurface.bounds(for: .zero) == nil)
    }
}
