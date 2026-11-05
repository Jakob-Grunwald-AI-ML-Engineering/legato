import Foundation
import LegatoCore

/// Only audio captured after a tap, while the take's connection is being prepared. The beginning is
/// never evicted: an overlong connection fails visibly rather than silently dropping opening words.
struct TakeAudioBuffer {
    enum Failure: Error, LocalizedError {
        case full
        var errorDescription: String? { "Connecting took too long. Please try recording again." }
    }
    private var chunks: [AudioChunk] = []
    private var seconds: Double = 0
    var frameCount: Int { chunks.reduce(0) { $0 + $1.samples.count / max(1, $1.format.channelCount) } }
    let limit: Double
    init(limit: Double = 15) { self.limit = limit }
    mutating func append(_ chunk: AudioChunk) throws {
        let duration = Double(chunk.samples.count) / Double(max(1, chunk.format.channelCount)) / chunk.format.sampleRate
        guard duration.isFinite, duration >= 0, seconds + duration <= limit else { throw Failure.full }
        chunks.append(chunk); seconds += duration
    }
    mutating func takeAll() -> [AudioChunk] {
        let result = chunks; removeAll(); return result
    }
    mutating func removeAll() { chunks = []; seconds = 0 }
}

/// Shared only on the main actor between microphone consumption and connection admission.
@MainActor final class PendingTakeAudio {
    var buffer = TakeAudioBuffer()
    var ready = false
    var failure: (any Error)?
}
