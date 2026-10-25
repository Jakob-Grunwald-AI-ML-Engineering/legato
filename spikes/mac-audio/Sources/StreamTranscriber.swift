import FluidAudio
import Foundation
import os

struct LatencySample: Codable, Sendable {
    var tSinceStartS: Double
    /// Time spent inside `process(samples:)` for this chunk (mel + encoder + decode).
    var procMs: Double
    /// Wall time from "last sample of the chunk arrived" to "chunk fully processed".
    var lagMs: Double
}

enum TranscriptEvent: Sendable {
    case partial(stream: String, text: String)
    case final(stream: String, text: String)
}

/// One Nemotron multilingual streaming manager per audio stream. Models are shared, per-stream state is not.
actor StreamTranscriber {
    let name: String
    let chunkMs: Int
    private let manager = StreamingNemotronMultilingualAsrManager()
    private let partialBox = OSAllocatedUnfairLock(initialState: "")
    private let onEvent: @Sendable (TranscriptEvent) -> Void
    private let chunkSamples: Int
    private let startedAt = Date()

    private var base = 0  // samples fed before the current segment started (reset by finish()+reset())
    private var fed = 0
    private var arrivals: [(cum: Int, at: Date)] = []
    private var processedChunks = 0
    private var silentSamples = 0
    private var lastEmitted = ""
    private(set) var finals: [String] = []
    private(set) var latencies: [LatencySample] = []
    private(set) var partialUpdates = 0
    private(set) var firstTextS: Double?

    init(name: String, chunkMs: Int, onEvent: @escaping @Sendable (TranscriptEvent) -> Void) {
        self.name = name
        self.chunkMs = chunkMs
        self.chunkSamples = chunkMs * 16
        self.onEvent = onEvent
    }

    func load(shared: SharedNemotronMultilingualModels, language: String) async throws {
        try await manager.loadFromShared(shared)
        await manager.setLanguage(language)
        let box = partialBox
        await manager.setPartialCallback { text in box.withLock { $0 = text } }
    }

    /// Feed 16 kHz mono samples. Audio is chunked internally by the manager (`chunkMs`).
    func feed(_ samples: [Float]) async {
        guard !samples.isEmpty else { return }
        fed += samples.count
        arrivals.append((fed - base, Date()))

        let rms = (samples.reduce(0) { $0 + Double($1 * $1) } / Double(samples.count)).squareRoot()
        silentSamples = rms < 0.004 ? silentSamples + samples.count : 0

        let t0 = ContinuousClock.now
        do { _ = try await manager.process(samples: samples) } catch {
            NSLog("[\(name)] process error: \(error)")
            return
        }
        let elapsed = ContinuousClock.now - t0
        let elapsedMs = Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15

        let chunksNow = (fed - base) / chunkSamples
        let newChunks = chunksNow - processedChunks
        if newChunks > 0 {
            let now = Date()
            for k in (processedChunks + 1)...chunksNow {
                let end = k * chunkSamples
                let arrived = arrivals.first { $0.cum >= end }?.at ?? now
                latencies.append(
                    LatencySample(
                        tSinceStartS: now.timeIntervalSince(startedAt),
                        procMs: elapsedMs / Double(newChunks),
                        lagMs: now.timeIntervalSince(arrived) * 1000))
            }
            processedChunks = chunksNow
            arrivals.removeAll { $0.cum < processedChunks * chunkSamples }
        }

        let partial = partialBox.withLock { $0 }
        if partial != lastEmitted {
            lastEmitted = partial
            partialUpdates += 1
            if firstTextS == nil, !partial.isEmpty { firstTextS = Date().timeIntervalSince(startedAt) }
            onEvent(.partial(stream: name, text: partial))
        }

        // Endpoint on ~1.2 s of silence: commit the segment and reset (also keeps Nemotron punctuation healthy, see FluidAudio #687).
        if silentSamples >= 19_200, !partial.isEmpty { await commitSegment() }
    }

    /// Flush remaining audio, commit the text as a final line, and reset the decoder for the next segment.
    func commitSegment() async {
        do {
            let text = try await manager.finish().trimmingCharacters(in: .whitespacesAndNewlines)
            await manager.reset()
            if !text.isEmpty {
                finals.append(text)
                onEvent(.final(stream: name, text: text))
            }
        } catch {
            NSLog("[\(name)] finish error: \(error)")
        }
        partialBox.withLock { $0 = "" }
        lastEmitted = ""
        base = fed
        processedChunks = 0
        arrivals.removeAll()
        onEvent(.partial(stream: name, text: ""))
    }

    var fullText: String { finals.joined(separator: " ") }
}
