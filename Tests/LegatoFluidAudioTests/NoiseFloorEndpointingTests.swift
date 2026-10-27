import Foundation
import LegatoCore
import Synchronization
import Testing
@testable import LegatoFluidAudio

/// A model that recognizes the next word every few chunks of speech (a chunk louder than `speechLevel`).
private final class SpeakingBackend: StreamingBackend, @unchecked Sendable {
    private let state = Mutex((words: [String](), loudChunks: 0, next: 0, commits: 0))
    let script: [String]
    let speechLevel: Float
    let chunksPerWord: Int

    init(script: [String], speechLevel: Float = 0.03, chunksPerWord: Int = 4) {
        self.script = script
        self.speechLevel = speechLevel
        self.chunksPerWord = chunksPerWord
    }

    func process(_ samples: [Float]) async throws {
        let rms = (samples.reduce(0) { $0 + $1 * $1 } / Float(max(samples.count, 1))).squareRoot()
        state.withLock {
            guard rms >= speechLevel else { return }
            $0.loudChunks += 1
            if $0.loudChunks % chunksPerWord == 0, $0.next < script.count {
                $0.words.append(script[$0.next])
                $0.next += 1
            }
        }
    }
    func partial() async -> String { state.withLock { $0.words.joined(separator: " ") } }
    func commit() async throws -> String {
        state.withLock {
            let text = $0.words.joined(separator: " ")
            $0.words = []
            $0.commits += 1
            return text
        }
    }
    func detectedLanguage() async -> String? { nil }
    func applyLanguage(_ hint: String) async {}
}

/// Room noise as an iPhone mic hears it: around `level` RMS, not flat (100 ms chunks).
private func noise(_ chunks: Int, level: Float = 0.009) -> [(samples: Int, level: Float)] {
    (0..<chunks).map { (1_600, $0 % 3 == 0 ? level * 1.25 : level * 0.9) }
}

private func speech(_ chunks: Int, level: Float = 0.06) -> [(samples: Int, level: Float)] {
    (0..<chunks).map { (1_600, $0 % 2 == 0 ? level : level * 0.7) }
}

extension SeamTests {
    /// The mic's noise floor in a room is often above the fixed silence threshold (the phone measured
    /// 0.003 to 0.0126 RMS before speech). A pause is silence relative to that floor.
    @Suite("Endpointing above a noise floor")
    struct NoiseFloorEndpointingTests {
        @Test func eachPausedPhraseIsCommittedWhileTheDictationGoesOnInARoomWithNoise() async throws {
            let backend = SpeakingBackend(script: ["hallo", "wie", "gehts", "ich", "wollte", "fragen", "ob", "du", "zeit", "hast"])
            // Noise before speaking, three phrases with 1.5 s pauses in between, then the stop.
            var pattern = noise(5)
            pattern += speech(12) + noise(15)
            pattern += speech(12) + noise(15)
            pattern += speech(8)
            var events: [TranscriptEvent] = []
            var driver = SegmentDriver(
                endpointer: SilenceEndpointer(silenceMs: 1200), mapper: PartialEventMapper(), clamp: LanguageClamp(preferred: []))
            try await driver.run(chunks(pattern), backend: backend) { events.append($0) }

            let finals = events.filter(\.isFinal).map { $0.text.trimmingCharacters(in: .whitespaces) }
            #expect(finals == ["hallo wie gehts", "ich wollte fragen", "ob du"])
        }

        @Test func aPauseInNoiseAboveTheFixedThresholdIsSilence() {
            var endpointer = SilenceEndpointer(silenceMs: 1200)
            for chunk in noise(5) + speech(10) { _ = endpointer.feed([Float](repeating: chunk.level, count: chunk.samples), hasText: true) }
            let pause = noise(12).map { endpointer.feed([Float](repeating: $0.level, count: $0.samples), hasText: true) }
            #expect(pause.dropLast().allSatisfy { !$0 }, "not before 1200 ms")
            #expect(pause.last == true)
        }

        @Test func speechWellAboveTheNoiseFloorIsNotSilence() {
            var endpointer = SilenceEndpointer(silenceMs: 1200)
            var committed = false
            for chunk in noise(5) + speech(200, level: 0.04) {
                committed = committed || endpointer.feed([Float](repeating: chunk.level, count: chunk.samples), hasText: true)
            }
            #expect(!committed)
            #expect(endpointer.heardSpeech)
        }

        @Test func talkingFromTheFirstChunkIsNotTakenForTheNoiseFloor() {
            var endpointer = SilenceEndpointer(silenceMs: 1200)
            var committed = false
            for chunk in speech(40, level: 0.05) {
                committed = committed || endpointer.feed([Float](repeating: chunk.level, count: chunk.samples), hasText: true)
            }
            #expect(!committed)
        }

        @Test func theNoiseFloorOutlivesACommit() {
            var endpointer = SilenceEndpointer(silenceMs: 1200)
            for chunk in noise(5) + speech(10) + noise(12) { _ = endpointer.feed([Float](repeating: chunk.level, count: chunk.samples), hasText: true) }
            for chunk in speech(10) { _ = endpointer.feed([Float](repeating: chunk.level, count: chunk.samples), hasText: true) }
            let pause = noise(12).map { endpointer.feed([Float](repeating: $0.level, count: $0.samples), hasText: true) }
            #expect(pause.last == true)
        }
    }
}
