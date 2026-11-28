import Foundation
import Testing
import LegatoVoiceIdentity
@testable import LegatoSoniox

@Suite(.timeLimit(.minutes(1))) struct VoiceFilterReplayTests {
    private func token(_ text: String, _ start: Double?, _ end: Double?) -> SonioxToken {
        SonioxToken(text: text, isFinal: true, startMs: start, endMs: end)
    }

    @Test func scoreCountsWordsByTheIntervalHoldingTheirMidpoint() {
        let intervals = [VoiceRecordingInterval(kind: .reading, startMs: 0, endMs: 1000, prompt: "Hello wonder."),
                         VoiceRecordingInterval(kind: .quiet, startMs: 1400, endMs: 3000)]
        let decisions: [VoiceFilterReplay.Decision] = [
            .init(token: token(" Hello", 0, 400), admitted: true),
            .init(token: token(" won", 500, 700), admitted: true),
            .init(token: token("der.", 700, 900), admitted: false),
            .init(token: token(" gap", 1200, 1300), admitted: true),
            .init(token: token(" TV", 1500, 1800), admitted: true),
            .init(token: token(" noise", 1900, 2200), admitted: false),
            .init(token: token(" untimed", nil, nil), admitted: true),
        ]
        let score = VoiceReplayScore(decisions: decisions, intervals: intervals)
        #expect(score.ownWords == 2 && score.ownAdmitted == 1 && score.ownPartial == 1)
        #expect(score.backgroundWords == 2 && score.backgroundAdmitted == 1 && score.backgroundPartial == 0)
        #expect(score.unlabelledWords == 2)
        let doubled = score + score
        #expect(doubled.ownWords == 4 && doubled.backgroundAdmitted == 2 && doubled.unlabelledWords == 4)
    }

    /// Loud audio stands for the user and matches; quiet audio stands for the TV and does not. The production filter
    /// lets the user's words through and, after its recall-first grace, withholds the TV's.
    @Test func replayRunsTheProductionFilterOverCachedTokens() async throws {
        var samples = [Float](repeating: 0.5, count: 10 * 16000)
        samples += [Float](repeating: 0.1, count: 10 * 16000)
        var responses: [VoiceFilterReplay.Response] = []
        for index in 0..<18 {
            let start = 500.0 + Double(index) * 500
            responses.append(.init(t: (start + 600) / 1000, tokens: [token(" mine", start, start + 400)]))
        }
        for index in 0..<16 {
            let start = 11_000.0 + Double(index) * 500
            responses.append(.init(t: (start + 600) / 1000, tokens: [token(" tv", start, start + 400)]))
        }
        responses.append(.init(t: 20, tokens: [SonioxToken(text: "<end>", isFinal: true)], finished: true))
        let decisions = await VoiceFilterReplay.run(samples: samples, responses: responses) { window in
            window.reduce(0) { $0 + abs($1) } / Float(window.count) > 0.3 ? 0.9 : 0.05
        }
        #expect(decisions.count == 34)
        let intervals = [VoiceRecordingInterval(kind: .reading, startMs: 0, endMs: 10_000, prompt: "…"),
                         VoiceRecordingInterval(kind: .quiet, startMs: 11_000, endMs: 20_000)]
        let score = VoiceReplayScore(decisions: decisions, intervals: intervals)
        #expect(score.ownWords == 18 && score.ownAdmitted == 18)
        #expect(score.backgroundWords == 16 && score.backgroundAdmitted == 2)
        // The cache's file shape round-trips.
        let cache = VoiceFilterReplay.TokenCache(model: "stt-rt-v6", responses: responses)
        #expect(try JSONDecoder().decode(VoiceFilterReplay.TokenCache.self, from: JSONEncoder().encode(cache)) == cache)
    }
}
