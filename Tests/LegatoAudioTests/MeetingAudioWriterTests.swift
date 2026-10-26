import AVFAudio
import Foundation
import Testing
import LegatoCore
@testable import LegatoAudio

@Suite struct MeetingAudioWriterTests {
    private let spec = AudioFormatSpec(sampleRate: 16_000, channelCount: 1)

    private func tempFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("maw-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// One second of a 440 Hz tone with a little noise, so the encoder has something to chew on.
    private func tone(seconds: Double, from start: Int = 0) -> AudioChunk {
        let n = Int(seconds * 16_000)
        let s = (0..<n).map { i in
            0.3 * sinf(2 * .pi * 440 * Float(start + i) / 16_000) + Float.random(in: -0.02...0.02)
        }
        return AudioChunk(samples: s, format: spec)
    }

    private func fileSize(_ url: URL) throws -> Int {
        try #require(try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int)
    }

    @Test func sixtySecondsPlusSilenceBecomeSmallM4a() async throws {
        let folder = try tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let writer = MeetingAudioWriter(folder: folder)
        for s in 0..<60 { try await writer.write(tone(seconds: 1, from: s * 16_000), stream: .mic) }
        try await writer.writeSilence(seconds: 5, stream: .mic)
        try await writer.finish()

        // finish() closes the CAF only.
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("mic.caf").path))
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("mic.m4a").path))
        let cafDuration = try await writer.duration(of: .mic)
        #expect(abs(cafDuration - 65) < 0.01)

        try await writer.finalize()
        let m4a = folder.appendingPathComponent("mic.m4a")
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("mic.caf").path))
        let file = try AVAudioFile(forReading: m4a)
        #expect(file.fileFormat.sampleRate == 16_000)
        #expect(file.fileFormat.channelCount == 1)
        let duration = Double(file.length) / file.processingFormat.sampleRate
        #expect(abs(duration - 65) <= 0.2)
        let size = try fileSize(m4a)
        print("MEASURED m4a size=\(size) bytes duration=\(duration)s")
        #expect(size < 350_000)

        // The reader falls back to the m4a once the CAF is gone.
        let samples = try await writer.samples(of: .mic, in: 1..<2)
        #expect(abs(samples.count - 16_000) <= 1)
    }

    @Test func leftoverCafCopyIsRecoveredToPlayableM4a() async throws {
        let folder = try tempFolder()
        let copy = try tempFolder()
        defer { try? FileManager.default.removeItem(at: folder); try? FileManager.default.removeItem(at: copy) }
        let writer = MeetingAudioWriter(folder: folder)
        for s in 0..<10 { try await writer.write(tone(seconds: 1, from: s * 16_000), stream: .system) }
        // Snapshot while the writer is still open: a crash leaves exactly this.
        try FileManager.default.copyItem(at: folder.appendingPathComponent("system.caf"),
                                         to: copy.appendingPathComponent("system.caf"))
        try await writer.finish()

        let recovered = try await MeetingAudioWriter.recover(folder: copy)
        #expect(recovered == [.system])
        let m4a = copy.appendingPathComponent("system.m4a")
        let file = try AVAudioFile(forReading: m4a)
        #expect(file.length > 0)
        let duration = Double(file.length) / file.processingFormat.sampleRate
        #expect(duration > 5 && duration <= 10.2)
        #expect(!FileManager.default.fileExists(atPath: copy.appendingPathComponent("system.caf").path))
    }

    @Test func readerReturnsRequestedWindowsClamped() async throws {
        let folder = try tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let writer = MeetingAudioWriter(folder: folder)
        // 3 s: first second 0.5, second second -0.5, third second 0.25 (constant, Int16-exact enough).
        let levels: [Float] = [0.5, -0.5, 0.25]
        for l in levels {
            try await writer.write(AudioChunk(samples: Array(repeating: l, count: 16_000), format: spec), stream: .mic)
        }
        try await writer.finish()

        let mid = try await writer.samples(of: .mic, in: 1.25..<1.75)
        #expect(mid.count == 8_000)
        #expect(mid.allSatisfy { abs($0 - -0.5) < 0.001 })
        let tail = try await writer.samples(of: .mic, in: 2.5..<10)
        #expect(tail.count == 8_000)
        #expect(tail.allSatisfy { abs($0 - 0.25) < 0.001 })
        let none = try await writer.samples(of: .mic, in: 5..<6)
        #expect(none.isEmpty)
        #expect(abs(try await writer.duration(of: .mic) - 3) < 0.001)
    }

    @Test func convertsOtherFormatsTo16kMono() async throws {
        let folder = try tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let writer = MeetingAudioWriter(folder: folder)
        let stereo48 = AudioFormatSpec(sampleRate: 48_000, channelCount: 2)
        let frames = 48_000
        let s = (0..<frames).flatMap { i -> [Float] in
            let v = 0.3 * sinf(2 * .pi * 440 * Float(i) / 48_000); return [v, v]
        }
        try await writer.write(AudioChunk(samples: s, format: stereo48), stream: .mic)
        try await writer.finish()
        let d = try await writer.duration(of: .mic)
        #expect(abs(d - 1) < 0.05)
    }
}
