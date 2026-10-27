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
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("mic.caf").path), "the CAF stays for the heavy steps")
        await writer.discardLossless()
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
        #expect(recovered.converted == [.system])
        #expect(recovered.failed.isEmpty)
        let m4a = copy.appendingPathComponent("system.m4a")
        let file = try AVAudioFile(forReading: m4a)
        #expect(file.length > 0)
        let duration = Double(file.length) / file.processingFormat.sampleRate
        #expect(duration > 5 && duration <= 10.2)
        #expect(FileManager.default.fileExists(atPath: copy.appendingPathComponent("system.caf").path), "recovery keeps the CAF too")
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

    @Test func aStreamThatCannotBeConvertedIsReportedAndItsCafKept() async throws {
        let folder = try tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let writer = MeetingAudioWriter(folder: folder)
        for s in 0..<3 { try await writer.write(tone(seconds: 1, from: s * 16_000), stream: .mic) }
        // The system recording is damaged (not a CAF at all).
        try Data("garbage".utf8).write(to: folder.appendingPathComponent("system.caf"))

        let report = try await writer.finalize()

        #expect(report.converted == [.mic])
        #expect(Set(report.failed.keys) == [.system])
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("mic.m4a").path))
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("system.caf").path))
    }

    #if os(macOS)
    @Test func recordingsAreOwnerOnly() async throws {
        let parent = try tempFolder()
        defer { try? FileManager.default.removeItem(at: parent) }
        let folder = parent.appendingPathComponent("meeting")
        let writer = MeetingAudioWriter(folder: folder)
        try await writer.write(tone(seconds: 1), stream: .mic)
        func mode(_ url: URL) throws -> Int? { try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int }
        #expect(try mode(folder) == 0o700)
        #expect(try mode(folder.appendingPathComponent("mic.caf")) == 0o600)
        try await writer.finalize()
        #expect(try mode(folder.appendingPathComponent("mic.m4a")) == 0o600)
    }
    #endif
}

@Suite struct MeetingAudioWriterMixTests {
    private let spec = AudioFormatSpec(sampleRate: 16_000, channelCount: 1)

    private func tempFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("maw-mix-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func chunk(seconds: Double, level: Float) -> AudioChunk {
        AudioChunk(samples: [Float](repeating: level, count: Int(seconds * 16_000)), format: spec)
    }

    private func tone(seconds: Double, from start: Int = 0) -> AudioChunk {
        let n = Int(seconds * 16_000)
        let s = (0..<n).map { i in 0.3 * sinf(2 * .pi * 440 * Float(start + i) / 16_000) + 0.1 * sinf(Float(start + i) * 0.37) }
        return AudioChunk(samples: s, format: spec)
    }

    private func exists(_ folder: URL, _ name: String) -> Bool {
        FileManager.default.fileExists(atPath: folder.appendingPathComponent(name).path)
    }

    private func seconds(_ url: URL) throws -> Double {
        let file = try AVAudioFile(forReading: url)
        return Double(file.length) / file.processingFormat.sampleRate
    }

    @Test func theMixIsATrackOfItsOwnAndBecomesMixM4aWithTheMeetingsLength() async throws {
        let folder = try tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let writer = MeetingAudioWriter(folder: folder)
        // A 12 s meeting: each track covers all of it, in pieces and silence, as the session writes them.
        try await writer.write(chunk(seconds: 7, level: 0.2), stream: .mic)
        try await writer.writeSilence(seconds: 5, stream: .mic)
        try await writer.writeSilence(seconds: 3, stream: .system)
        try await writer.write(chunk(seconds: 9, level: 0.1), stream: .system)
        for _ in 0..<12 { try await writer.write(chunk(seconds: 1, level: 0.3), stream: .mixed) }
        try await writer.finish()

        #expect(exists(folder, "mix.caf"))
        #expect(abs(try await writer.duration(of: .mixed) - 12) < 0.001)

        let report = try await writer.finalize()
        #expect(Set(report.converted) == [.mic, .system, .mixed])
        #expect(report.failed.isEmpty)
        #expect(exists(folder, "mix.m4a") && exists(folder, "mix.caf"))
        for name in ["mic.m4a", "system.m4a", "mix.m4a"] {
            #expect(abs(try seconds(folder.appendingPathComponent(name)) - 12) < 0.2, "\(name)")
        }
        #expect(abs(try await writer.duration(of: .mixed) - 12) < 0.2)
        let window = try await writer.samples(of: .mixed, in: 2..<3)
        #expect(abs(window.count - 16_000) <= 1)
    }

    @Test func afterFinalizeTheReaderStillReadsTheLosslessCafUntilItIsDiscarded() async throws {
        let folder = try tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let writer = MeetingAudioWriter(folder: folder)
        for s in 0..<4 { try await writer.write(tone(seconds: 1, from: s * 16_000), stream: .mixed) }
        try await writer.finish()
        let lossless = try await writer.samples(of: .mixed, in: 1..<3)

        let report = await writer.finalize()
        #expect(report.failed.isEmpty && exists(folder, "mix.m4a"))
        #expect(try await writer.samples(of: .mixed, in: 1..<3) == lossless, "samples come from the CAF, not the AAC")

        await writer.discardLossless()
        #expect(!exists(folder, "mix.caf") && exists(folder, "mix.m4a"))
        let lossy = try await writer.samples(of: .mixed, in: 1..<3)
        #expect(lossy != lossless && abs(lossy.count - lossless.count) <= 1, "then the m4a answers")
    }

    @Test func discardingKeepsTheCafOfAStreamWithoutAnM4a() async throws {
        let folder = try tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let writer = MeetingAudioWriter(folder: folder)
        for s in 0..<3 { try await writer.write(tone(seconds: 1, from: s * 16_000), stream: .mic) }
        try Data("garbage".utf8).write(to: folder.appendingPathComponent("system.caf"))
        await writer.finalize()
        await writer.discardLossless()
        #expect(exists(folder, "mic.m4a") && !exists(folder, "mic.caf"))
        #expect(exists(folder, "system.caf"), "no m4a, so the CAF is the only copy")
    }

    @Test func aLeftoverMixCafIsRecoveredToo() async throws {
        let folder = try tempFolder()
        let copy = try tempFolder()
        defer { try? FileManager.default.removeItem(at: folder); try? FileManager.default.removeItem(at: copy) }
        let writer = MeetingAudioWriter(folder: folder)
        for _ in 0..<5 { try await writer.write(chunk(seconds: 1, level: 0.3), stream: .mixed) }
        try FileManager.default.copyItem(
            at: folder.appendingPathComponent("mix.caf"), to: copy.appendingPathComponent("mix.caf"))
        try await writer.finish()

        let report = MeetingAudioWriter.recover(folder: copy)
        #expect(report.converted == [.mixed])
        #expect(exists(copy, "mix.m4a"))
    }

    @Test func withOneSourceTheMicRecordingAnswersForTheMix() async throws {
        let folder = try tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let writer = MeetingAudioWriter(folder: folder)
        try await writer.write(chunk(seconds: 3, level: 0.5), stream: .mic)
        try await writer.finish()
        #expect(!exists(folder, "mix.caf"))
        #expect(abs(try await writer.duration(of: .mixed) - 3) < 0.001)
        let viaMix = try await writer.samples(of: .mixed, in: 0.5..<1.5)
        let viaMic = try await writer.samples(of: .mic, in: 0.5..<1.5)
        #expect(viaMix == viaMic && viaMix.count == 16_000)

        try await writer.finalize()
        #expect(abs(try await writer.duration(of: .mixed) - 3) < 0.2, "after the m4a conversion too")
    }

    @Test func aMeetingWithTwoSourcesButNoMixHasNoMix() async throws {
        let folder = try tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let writer = MeetingAudioWriter(folder: folder)
        try await writer.write(chunk(seconds: 3, level: 0.5), stream: .mic)
        try await writer.write(chunk(seconds: 3, level: 0.5), stream: .system)
        try await writer.finish()
        // The post-pass then falls back to the two streams, as it did before the mix existed.
        await #expect(throws: MeetingAudioWriter.WriterError.noRecording(.mixed)) { try await writer.duration(of: .mixed) }
    }

    @Test func aRealMixWinsOverTheMicAlias() async throws {
        let folder = try tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let writer = MeetingAudioWriter(folder: folder)
        try await writer.write(chunk(seconds: 2, level: 0.5), stream: .mic)
        try await writer.write(chunk(seconds: 4, level: 0.1), stream: .mixed)
        try await writer.finish()
        #expect(abs(try await writer.duration(of: .mixed) - 4) < 0.001)
    }
}
