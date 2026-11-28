import Foundation
import LegatoVoiceIdentity

/// Offline replay of a kept voice recording through the production `VoiceTokenFilter`, for the Mac replay tool.
/// The token cache is the stream's responses, each with `t`: the seconds of audio sent when it arrived, so the filter
/// sees exactly as much audio as it would have live. Without `t`, all audio is available at once.
public enum VoiceFilterReplay {
    public struct Response: Codable, Sendable, Equatable {
        public var t: Double?
        public var tokens: [SonioxToken]
        public var finished: Bool?
        public init(t: Double? = nil, tokens: [SonioxToken], finished: Bool? = nil) { self.t = t; self.tokens = tokens; self.finished = finished }
    }
    /// The cached stream next to a recording (`tokens.json`).
    public struct TokenCache: Codable, Sendable, Equatable {
        public var model: String?
        public var responses: [Response]
        public init(model: String? = nil, responses: [Response]) { self.model = model; self.responses = responses }
    }
    /// A final provider token and whether the filter let it through.
    public struct Decision: Sendable, Equatable {
        public var token: SonioxToken
        public var admitted: Bool
    }

    /// Final word tokens in order, each marked admitted or withheld by the filter with `matcher`.
    public static func run(samples: [Float], responses: [Response], matcher: @escaping @Sendable ([Float]) async throws -> Float) async -> [Decision] {
        let filter = VoiceTokenFilter(matcher: matcher)
        var sent = 0, decisions: [Decision] = []
        for response in responses {
            let target = response.t.map { min(samples.count, max(sent, Int(($0 * 16000).rounded()))) } ?? samples.count
            if target > sent { await filter.append(pcm16(samples[sent..<target])); sent = target }
            let force = response.finished == true || response.tokens.contains { $0.text == "<fin>" || $0.text == "<end>" }
            let output = await filter.filter(response.tokens, force: force).tokens
            var next = 0
            for token in response.tokens {
                let admitted = next < output.count && output[next] == token
                if admitted { next += 1 }
                if token.isFinal && !token.text.hasPrefix("<") { decisions.append(Decision(token: token, admitted: admitted)) }
            }
        }
        return decisions
    }

    private static func pcm16(_ samples: ArraySlice<Float>) -> Data {
        var data = Data(capacity: samples.count * 2)
        for sample in samples {
            let value = Int16((max(-1, min(1, sample.isFinite ? sample : 0)) * 32767).rounded())
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        return data
    }
}

/// Word counts of one replay against the recording's labels. A word is the run of final tokens from one with a
/// leading space (or the first) to the next; it lies in the interval holding its midpoint. A word counts as
/// admitted only when every piece got through; `partial` counts words that got through in part.
public struct VoiceReplayScore: Sendable, Equatable, Codable {
    /// Words inside reading intervals (the user's own voice).
    public var ownWords = 0
    public var ownAdmitted = 0
    public var ownPartial = 0
    /// Words inside quiet intervals (the surroundings: TV, other people).
    public var backgroundWords = 0
    public var backgroundAdmitted = 0
    public var backgroundPartial = 0
    /// Words outside every labelled interval, or without timing.
    public var unlabelledWords = 0
    public init() {}

    public init(decisions: [VoiceFilterReplay.Decision], intervals: [VoiceRecordingInterval]) {
        var words: [(start: Double?, end: Double?, admitted: Int, pieces: Int)] = []
        for decision in decisions {
            let token = decision.token
            if words.isEmpty || token.text.first?.isWhitespace == true {
                words.append((token.startMs, token.endMs, 0, 0))
            }
            let last = words.count - 1
            if words[last].start == nil { words[last].start = token.startMs }
            if let end = token.endMs { words[last].end = end }
            words[last].pieces += 1
            if decision.admitted { words[last].admitted += 1 }
        }
        for word in words {
            guard let start = word.start else { unlabelledWords += 1; continue }
            let middle = (start + (word.end ?? start)) / 2
            let all = word.admitted == word.pieces, some = word.admitted > 0 && !all
            switch intervals.first(where: { $0.contains(ms: middle) })?.kind {
            case .reading: ownWords += 1; if all { ownAdmitted += 1 }; if some { ownPartial += 1 }
            case .quiet: backgroundWords += 1; if all { backgroundAdmitted += 1 }; if some { backgroundPartial += 1 }
            case nil: unlabelledWords += 1
            }
        }
    }

    public static func + (a: Self, b: Self) -> Self {
        var sum = a
        sum.ownWords += b.ownWords; sum.ownAdmitted += b.ownAdmitted; sum.ownPartial += b.ownPartial
        sum.backgroundWords += b.backgroundWords; sum.backgroundAdmitted += b.backgroundAdmitted; sum.backgroundPartial += b.backgroundPartial
        sum.unlabelledWords += b.unlabelledWords
        return sum
    }
}
