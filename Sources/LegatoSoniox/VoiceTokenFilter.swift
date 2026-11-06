import Foundation

/// Recall-first streaming policy. Decisions use only audio already available, never hold words,
/// and remain sticky across provisional/final revisions of the same half-second start bin.
actor VoiceTokenFilter {
    typealias Matcher = @Sendable ([Float]) async throws -> Float
    private var audio: [Float] = []
    private var audioOffset = 0
    private struct Decision { let admit: Bool; let status: String }
    private var decisions: [Int: Decision] = [:]
    private var retiredBefore = -1
    private var lastEvidenceBin = -1
    private var lastPositiveBin = -100
    private var lowEvidenceCount = 0
    private var unavailable = false
    private var latestStartMs = -1.0
    private var latestEndMs = 0.0
    private var speechRunStartSample = 0
    private let matcher: Matcher
    init(matcher: @escaping Matcher) { self.matcher = matcher }
    func append(_ data: Data) {
        let bytes = [UInt8](data)
        for i in stride(from: 0, to: bytes.count - bytes.count % 2, by: 2) {
            audio.append(Float(Int16(bitPattern: UInt16(bytes[i]) | UInt16(bytes[i + 1]) << 8)) / 32768)
        }
        let excess = max(0, audio.count - 30 * 16000)
        if excess > 0 { audio.removeFirst(excess); audioOffset += excess }
    }
    // `force` remains for provider endpoint compatibility; no endpoint can release held text,
    // because this policy has no pending word queue.
    func filter(_ tokens: [SonioxToken], force: Bool) async -> (tokens: [SonioxToken], withheld: Bool, status: String) {
        var output: [SonioxToken] = []
        var withheld = false
        var status = unavailable ? "unavailable" : "uncertain"
        for token in tokens {
            if token.text.hasPrefix("<") { output.append(token); continue }
            let decision = await decision(token)
            if decision.admit { output.append(token) } else { withheld = true }
            if decision.status == "unavailable" || status != "unavailable" { status = decision.status }
        }
        return (output, withheld, unavailable ? "unavailable" : withheld ? "filtered" : status)
    }
    private func decision(_ token: SonioxToken) async -> Decision {
        guard let start = token.startMs, let end = token.endMs, start.isFinite, end.isFinite,
              start >= 0, end >= start, end < Double(Int.max / 16000) else {
            lowEvidenceCount = 0
            return Decision(admit: true, status: unavailable ? "unavailable" : "uncertain")
        }
        let bin = Int(start / 500)
        if let decision = decisions[bin] { return decision }
        // Retired timestamps cannot resurrect a previously rejected token after cache eviction.
        guard bin >= retiredBefore else { return Decision(admit: false, status: "filtered") }
        // A pause ends the previous own-voice grace and its acoustic context. TV starting
        // after a pause must earn its own decision instead of borrowing the user's last words.
        if start > latestStartMs {
            if start - latestEndMs >= 700 {
                lastPositiveBin = -100; lowEvidenceCount = 0
                speechRunStartSample = Int(start * 16)
            }
            latestStartMs = start; latestEndMs = max(latestEndMs, end)
        }
        let result: Decision
        if bin < lastEvidenceBin {
            // A late provider revision must not consume or inherit newer rejection evidence.
            result = Decision(admit: true, status: unavailable ? "unavailable" : "uncertain")
        } else if unavailable { result = Decision(admit: true, status: "unavailable") }
        else {
            let upper = Int(end * 16)
            let lower = max(audioOffset, max(speechRunStartSample, upper - 32000))
            let availableUpper = audioOffset + audio.count
            if upper > availableUpper || upper - lower < 5600 {
                lowEvidenceCount = 0
                result = Decision(admit: true, status: "uncertain")
            } else {
                let samples = Array(audio[(lower - audioOffset)..<(upper - audioOffset)])
                let energy = samples.reduce(Float(0)) { $0 + $1 * $1 } / Float(samples.count)
                if energy <= 0.00001 {
                    lowEvidenceCount = 0
                    result = Decision(admit: true, status: "uncertain")
                } else {
                    do {
                        let score = try await matcher(samples)
                        guard score.isFinite else { throw InvalidScore() }
                        if bin > lastEvidenceBin {
                            if score >= 0.45 { lastPositiveBin = bin; lowEvidenceCount = 0 }
                            else if score < 0.20 {
                                lowEvidenceCount = bin - lastEvidenceBin <= 3 ? lowEvidenceCount + 1 : 1
                            } else { lowEvidenceCount = 0 }
                            lastEvidenceBin = bin
                        }
                        let reject = score < 0.20 && lowEvidenceCount >= 3 && bin - lastPositiveBin > 3
                        result = Decision(admit: !reject, status: reject ? "filtered" : score >= 0.45 ? "matching" : "uncertain")
                    } catch {
                        // An unavailable optional filter must never cost the user their dictation.
                        unavailable = true; lowEvidenceCount = 0
                        result = Decision(admit: true, status: "unavailable")
                    }
                }
            }
        }
        decisions[bin] = result
        if decisions.count > 4096 {
            for key in decisions.keys.sorted().prefix(decisions.count - 4096) {
                decisions.removeValue(forKey: key); retiredBefore = max(retiredBefore, key + 1)
            }
        }
        return result
    }
    private struct InvalidScore: Error {}
}
