import AVFAudio
import Foundation
import LegatoCore

/// Records a meeting's two streams into one folder: `mic.caf` / `system.caf` (Int16 PCM, 16 kHz mono)
/// while recording, then `mic.m4a` / `system.m4a` (AAC, ~32 kbps) after ``finalize()``.
///
/// CAF is written first because it survives a crash; ``finish()`` only closes it so the post-pass can
/// read full quality. The reader prefers a CAF and falls back to the m4a. Being an actor, writes happen
/// off the audio thread and in order.
public actor MeetingAudioWriter: MeetingAudioSink, AudioSampleReader {
    public enum WriterError: Error, Equatable {
        case finished
        case unreadable(String)
        case noRecording(TranscriptEvent.Stream)
    }

    /// What converting the leftover CAFs to m4a achieved, per stream.
    public struct ConversionReport: Sendable, Equatable {
        /// Streams now available as m4a.
        public var converted: [TranscriptEvent.Stream] = []
        /// Streams that could not be converted, with why; their CAF is kept.
        public var failed: [TranscriptEvent.Stream: String] = [:]
    }

    public static let recordingSpec = AudioFormatSpec(sampleRate: 16_000, channelCount: 1)
    private static let allStreams: [TranscriptEvent.Stream] = [.mic, .system]

    private let folder: URL
    private var files: [TranscriptEvent.Stream: AVAudioFile] = [:]
    private var converters: [AudioFormatSpec: BufferConverter] = [:]
    private var isFinished = false

    public init(folder: URL) {
        self.folder = folder
    }

    // MARK: Paths

    nonisolated private static func cafURL(_ folder: URL, _ s: TranscriptEvent.Stream) -> URL {
        folder.appendingPathComponent("\(s.rawValue).caf")
    }

    nonisolated private static func m4aURL(_ folder: URL, _ s: TranscriptEvent.Stream) -> URL {
        folder.appendingPathComponent("\(s.rawValue).m4a")
    }

    // MARK: MeetingAudioSink

    public func write(_ chunk: AudioChunk, stream: TranscriptEvent.Stream) throws {
        guard !isFinished else { throw WriterError.finished }
        let samples = try recordingSamples(chunk)
        try append(samples, to: stream)
    }

    public func writeSilence(seconds: TimeInterval, stream: TranscriptEvent.Stream) throws {
        guard !isFinished else { throw WriterError.finished }
        var remaining = Int((seconds * Self.recordingSpec.sampleRate).rounded())
        let block = 16_000
        while remaining > 0 {
            let n = min(block, remaining)
            try append([Float](repeating: 0, count: n), to: stream)
            remaining -= n
        }
    }

    /// Closes the CAFs. Conversion to m4a is the separate ``finalize()`` step.
    public func finish() {
        files.removeAll() // releasing the AVAudioFile closes and flushes it
        isFinished = true
    }

    // MARK: Conversion

    /// Converts each stream's CAF in this folder to m4a, removing the CAF once the m4a reads back.
    /// A stream that fails keeps its CAF and is listed in the report, whatever the other streams did.
    @discardableResult
    public func finalize() -> ConversionReport {
        finish()
        return Self.convertLeftovers(in: folder)
    }

    /// Converts CAFs left in `folder` (after a crash) to m4a.
    @discardableResult
    public static func recover(folder: URL) -> ConversionReport {
        convertLeftovers(in: folder)
    }

    private static func convertLeftovers(in folder: URL) -> ConversionReport {
        var report = ConversionReport()
        for stream in allStreams where FileManager.default.fileExists(atPath: cafURL(folder, stream).path) {
            do {
                try convert(caf: cafURL(folder, stream), to: m4aURL(folder, stream))
                report.converted.append(stream)
            } catch {
                report.failed[stream] = "\(error)"
            }
        }
        return report
    }

    private static func convert(caf: URL, to m4a: URL) throws {
        let input = try AVAudioFile(forReading: caf)
        let expected = input.length
        try? FileManager.default.removeItem(at: m4a)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: recordingSpec.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 32_000,
        ]
        do {
            var output: AVAudioFile? = try AVAudioFile(
                forWriting: m4a, settings: settings,
                commonFormat: input.processingFormat.commonFormat, interleaved: input.processingFormat.isInterleaved)
            let capacity: AVAudioFrameCount = 16_384
            guard let buffer = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: capacity) else {
                throw WriterError.unreadable(caf.lastPathComponent)
            }
            while input.framePosition < expected {
                try input.read(into: buffer, frameCount: capacity)
                if buffer.frameLength == 0 { break }
                try output?.write(from: buffer)
            }
            output = nil // close: finalizes the AAC stream
        } catch {
            try? FileManager.default.removeItem(at: m4a)
            throw error
        }
        PrivateFiles.protect(fileAt: m4a)
        // Verify before deleting the CAF: the m4a must open and be about as long as the source.
        let check = try AVAudioFile(forReading: m4a)
        guard check.length > 0 || expected == 0, abs(check.length - expected) <= 4_096 else {
            try? FileManager.default.removeItem(at: m4a)
            throw WriterError.unreadable(m4a.lastPathComponent)
        }
        try FileManager.default.removeItem(at: caf)
    }

    // MARK: AudioSampleReader

    public func duration(of stream: TranscriptEvent.Stream) throws -> TimeInterval {
        let file = try openForReading(stream)
        return Double(file.length) / file.processingFormat.sampleRate
    }

    public func samples(of stream: TranscriptEvent.Stream, in range: Range<TimeInterval>) throws -> [Float] {
        let file = try openForReading(stream)
        let rate = file.processingFormat.sampleRate
        let total = file.length
        let start = min(max(AVAudioFramePosition((range.lowerBound * rate).rounded()), 0), total)
        let end = min(max(AVAudioFramePosition((range.upperBound * rate).rounded()), start), total)
        let count = AVAudioFrameCount(end - start)
        guard count > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: count)
        else { return [] }
        file.framePosition = start
        try file.read(into: buffer, frameCount: count)
        guard let data = buffer.floatChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: data, count: Int(buffer.frameLength)))
    }

    private func openForReading(_ stream: TranscriptEvent.Stream) throws -> AVAudioFile {
        let fm = FileManager.default
        for url in [Self.cafURL(folder, stream), Self.m4aURL(folder, stream)] where fm.fileExists(atPath: url.path) {
            return try AVAudioFile(forReading: url)
        }
        throw WriterError.noRecording(stream)
    }

    // MARK: Writing

    private func append(_ samples: [Float], to stream: TranscriptEvent.Stream) throws {
        guard !samples.isEmpty else { return }
        let file = try openForWriting(stream)
        let format = file.processingFormat
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let dst = buffer.floatChannelData?[0]
        else { throw WriterError.unreadable(stream.rawValue) }
        samples.withUnsafeBufferPointer { dst.update(from: $0.baseAddress!, count: samples.count) }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        try file.write(from: buffer)
    }

    private func openForWriting(_ stream: TranscriptEvent.Stream) throws -> AVAudioFile {
        if let f = files[stream] { return f }
        try PrivateFiles.createDirectory(folder)
        let url = Self.cafURL(folder, stream)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: Self.recordingSpec.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        // A new writer on an existing folder truncates its CAFs: one writer per meeting run.
        let file = try AVAudioFile(forWriting: url, settings: settings,
                                   commonFormat: .pcmFormatFloat32, interleaved: false)
        PrivateFiles.protect(fileAt: url)
        files[stream] = file
        return file
    }

    /// The chunk's samples as 16 kHz mono Float32, converting when its format differs.
    private func recordingSamples(_ chunk: AudioChunk) throws -> [Float] {
        let target = Self.recordingSpec
        if chunk.format == target { return chunk.samples }
        guard let inFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: chunk.format.sampleRate,
            channels: AVAudioChannelCount(chunk.format.channelCount), interleaved: true),
            chunk.format.channelCount > 0
        else { throw WriterError.unreadable("chunk format") }
        let frames = chunk.samples.count / chunk.format.channelCount
        guard frames > 0,
              let input = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: AVAudioFrameCount(frames)),
              let dst = input.floatChannelData?[0]
        else { return [] }
        chunk.samples.withUnsafeBufferPointer { dst.update(from: $0.baseAddress!, count: frames * chunk.format.channelCount) }
        input.frameLength = AVAudioFrameCount(frames)

        let converter: BufferConverter
        if let c = converters[chunk.format] {
            converter = c
        } else if let c = BufferConverter(from: inFormat, to: target) {
            converters[chunk.format] = c
            converter = c
        } else {
            throw WriterError.unreadable("chunk format")
        }
        guard let out = converter.convert(input) else { throw WriterError.unreadable("conversion") }
        return out.samples
    }
}
