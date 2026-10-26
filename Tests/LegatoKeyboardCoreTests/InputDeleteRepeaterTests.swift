import Foundation
import Testing
@testable import LegatoKeyboardCore

@Suite struct InputDeleteRepeaterTests {
    private let t = Date(timeIntervalSince1970: 1_000)
    private func at(_ s: Double) -> Date { t.addingTimeInterval(s) }

    @Test func nothingBeforeHalfASecond() {
        var r = DeleteRepeater()
        r.begin(at: t)
        #expect(r.tick(at: at(0.49)).isEmpty)
    }

    @Test func firstRepeatAtHalfASecond() {
        var r = DeleteRepeater()
        r.begin(at: t)
        #expect(r.tick(at: at(0.5)) == [.character])
    }

    @Test func thenEveryTenthOfASecond() {
        var r = DeleteRepeater()
        r.begin(at: t)
        _ = r.tick(at: at(0.5))
        #expect(r.tick(at: at(0.59)).isEmpty)
        #expect(r.tick(at: at(0.6)) == [.character])
        #expect(r.tick(at: at(0.7)) == [.character])
    }

    @Test func aLateTickCatchesUp() {
        var r = DeleteRepeater()
        r.begin(at: t)
        #expect(r.tick(at: at(0.8)) == [.character, .character, .character, .character])
    }

    @Test func wordWiseFromOneAndAHalfSeconds() {
        var r = DeleteRepeater()
        r.begin(at: t)
        _ = r.tick(at: at(1.4))
        #expect(r.tick(at: at(1.5)) == [.word])
        #expect(r.tick(at: at(1.6)) == [.word])
    }

    @Test func aSingleLateTickMixesCharactersAndWords() {
        var r = DeleteRepeater()
        r.begin(at: t)
        #expect(r.tick(at: at(1.6)) == Array(repeating: .character, count: 10) + [.word, .word])
    }

    @Test func endStopsAndBeginRestarts() {
        var r = DeleteRepeater()
        r.begin(at: t)
        r.end()
        #expect(!r.isActive)
        #expect(r.tick(at: at(2)).isEmpty)
        r.begin(at: at(10))
        #expect(r.isActive)
        #expect(r.tick(at: at(10.5)) == [.character])
    }
}
