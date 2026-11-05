import Foundation
import LegatoVoiceIdentity

/// Filters before the segmenter: rejected words cannot reach tail, cleanup, insertion or History.
/// Two seconds of local context costs initial latency; no speaker decision is inferred from token text.
actor VoiceTokenFilter {
    typealias Matcher = @Sendable ([Float]) async throws -> Float
    private var audio: [Float] = []
    private var audioOffset = 0
    private var finalTokens: [SonioxToken] = []
    private var scores: [Int: Float] = [:]
    private let matcher: Matcher
    private(set) var withheld = false
    init(matcher: @escaping Matcher) { self.matcher = matcher }
    func append(_ data: Data) {
        let bytes = [UInt8](data)
        for i in stride(from: 0, to: bytes.count - bytes.count % 2, by: 2) {
            audio.append(Float(Int16(bitPattern: UInt16(bytes[i]) | UInt16(bytes[i + 1]) << 8)) / 32768)
        }
        let excess = max(0, audio.count - 30 * 16000)
        if excess > 0 { audio.removeFirst(excess); audioOffset += excess }
    }
    func filter(_ tokens: [SonioxToken], force: Bool) async throws -> (tokens: [SonioxToken], withheld: Bool) {
        finalTokens.append(contentsOf: tokens.filter { $0.isFinal })
        guard finalTokens.count <= 4096 else { throw VoiceIdentityError.invalidModel }
        var output: [SonioxToken] = []
        var remaining: [SonioxToken] = []
        withheld = false
        for (index, token) in finalTokens.enumerated() {
            if token.text.hasPrefix("<") { output.append(token); continue }
            switch try await decision(token, force: force) {
            case .some(true): output.append(token)
            case .some(false): withheld = true
            case .none:
                remaining = Array(finalTokens[index...]); withheld = true
            }
            if !remaining.isEmpty { break }
        }
        finalTokens = remaining
        for token in tokens where remaining.isEmpty && !token.isFinal && !token.text.hasPrefix("<") {
            if try await decision(token, force: force) == true { output.append(token) }
            else { withheld = true }
        }
        return (output, withheld)
    }
    private func decision(_ token: SonioxToken, force: Bool) async throws -> Bool? {
        guard let start = token.startMs, let end = token.endMs, start.isFinite, end.isFinite,
              start >= 0, end >= start, end < Double(Int.max / 16000) else { return false }
        // Half-second bins cap repeated inference on provisional revisions. Center on the word;
        // never carry a positive decision across a speaker's later turn.
        let bin = Int((start + end) / 1000)
        if let score = scores[bin] { return score >= 0.58 }
        let center = bin * 8000 + 4000
        let lower = max(0, center - 16000)
        let desiredUpper = lower + 32000
        let availableUpper = audioOffset + audio.count
        if desiredUpper > availableUpper && !force { return nil }
        let upper = min(desiredUpper, availableUpper)
        guard lower >= audioOffset, upper - lower >= 5600 else { return false }
        let samples = Array(audio[(lower - audioOffset)..<(upper - audioOffset)])
        let energy = samples.reduce(Float(0)) { $0 + $1 * $1 } / Float(samples.count)
        guard energy > 0.00001 else { return false }
        let score = try await matcher(samples)
        guard score.isFinite else { throw VoiceIdentityError.invalidModel }
        scores[bin] = score
        if scores.count > 128 {
            for key in scores.keys.sorted().prefix(scores.count - 128) { scores.removeValue(forKey: key) }
        }
        return score >= 0.58
    }
}
