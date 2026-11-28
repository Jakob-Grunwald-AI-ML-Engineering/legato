import AVFAudio
import Foundation

/// Reads one recorded track of a meeting (16 kHz mono, CAF or m4a) as float samples: in order, block by block, or a range
/// at a time. Keeps nothing of the audio beyond what the caller holds.
final class MeetingTrackReader {
    enum ReaderError: Error, LocalizedError {
        case unsupportedFormat(String)
        var errorDescription: String? {
            switch self {
            case .unsupportedFormat(let name): "The recording \(name) is not 16 kHz mono."
            }
        }
    }

    static let sampleRate: Double = 16_000
    private let file: AVAudioFile
    private let buffer: AVAudioPCMBuffer
    let url: URL

    init(url: URL, blockSize: AVAudioFrameCount = 16_000 * 5) throws {
        self.url = url
        file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        guard format.sampleRate == Self.sampleRate, format.channelCount == 1, format.commonFormat == .pcmFormatFloat32,
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: blockSize)
        else { throw ReaderError.unsupportedFormat(url.lastPathComponent) }
        self.buffer = buffer
    }

    var duration: TimeInterval { Double(file.length) / Self.sampleRate }

    /// The next block; empty at the end.
    func next() throws -> [Float] {
        guard file.framePosition < file.length else { return [] }
        try file.read(into: buffer, frameCount: buffer.frameCapacity)
        guard let data = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return [] }
        return Array(UnsafeBufferPointer(start: data, count: Int(buffer.frameLength)))
    }

    /// The samples from `range` (seconds), clipped to the track. Moves the read position.
    func samples(in range: Range<TimeInterval>) throws -> [Float] {
        let start = min(max(AVAudioFramePosition((range.lowerBound * Self.sampleRate).rounded()), 0), file.length)
        let end = min(max(AVAudioFramePosition((range.upperBound * Self.sampleRate).rounded()), start), file.length)
        var remaining = Int(end - start)
        file.framePosition = start
        var samples: [Float] = []
        samples.reserveCapacity(remaining)
        while remaining > 0 {
            try file.read(into: buffer, frameCount: min(buffer.frameCapacity, AVAudioFrameCount(remaining)))
            guard let data = buffer.floatChannelData?[0], buffer.frameLength > 0 else { break }
            samples.append(contentsOf: UnsafeBufferPointer(start: data, count: Int(buffer.frameLength)))
            remaining -= Int(buffer.frameLength)
        }
        return samples
    }
}
