import AVFAudio
import Foundation
import LegatoCore

/// Resolves the session locale: the request, else the device locale, mapped to a supported equivalent.
enum LocaleResolver {
    static func resolve(
        requested: Locale?,
        current: Locale = .current,
        supported: (Locale) async -> Locale?
    ) async throws -> Locale {
        let wanted = requested ?? current
        guard let match = await supported(wanted) else {
            throw AppleSpeechError.unsupportedLocale(wanted.identifier)
        }
        return match
    }
}

/// Reserves a locale in the asset inventory, which holds at most `maximum` reservations; at the cap the
/// oldest (first) reservation is released to make room. The inventory is injected, so the decision logic is testable without the Speech framework.
enum LocaleReservation {
    static func reserve(
        _ locale: Locale,
        maximum: Int,
        reserved: () async -> [Locale],
        attempt: (Locale) async throws -> Bool,
        release: (Locale) async -> Bool
    ) async throws {
        let current = await reserved()
        // The inventory answers `false` for a locale it already holds.
        if current.contains(where: { $0.identifier == locale.identifier }) { return }
        // Evict only at the cap; any other failure of `attempt` is the caller's to see.
        if current.count >= maximum, let oldest = current.first {
            _ = await release(oldest)
        }
        guard try await attempt(locale) else { throw AppleSpeechError.reservationFailed(locale.identifier) }
    }
}

/// One asset download: its progress object and the call that performs it.
struct AssetInstall: Sendable {
    var progress: Progress
    var run: @Sendable () async throws -> Void
}

/// Turns an asset installation into a progress stream: fractions while it runs, then exactly
/// one final `1.0` if (and only if) the assets are installed.
enum AssetInstallProgress {
    /// `prepare` returns the download to perform, or nil when the assets are already installed.
    static func stream(
        pollInterval: Duration = .milliseconds(250),
        prepare: @escaping @Sendable () async throws -> AssetInstall?
    ) -> AsyncStream<Double> {
        AsyncStream { continuation in
            let task = Task {
                var installed = false
                do {
                    if let install = try await prepare() {
                        let poll = Task {
                            while !Task.isCancelled {
                                continuation.yield(install.progress.fractionCompleted)
                                try? await Task.sleep(for: pollInterval)
                            }
                        }
                        defer { poll.cancel() }
                        try await install.run()
                    }
                    installed = true // downloaded, or nothing to download
                } catch {
                    // A failed install is visible to the caller as a stream that ends below 1.0
                    // and a following `prepare` error.
                }
                if installed, !Task.isCancelled { continuation.yield(1.0) }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// `TranscriptAssembler` appends final text verbatim, so the engine supplies the separator
/// between phrases. Volatile text is separated the same way but never counts as committed.
struct PhraseSpacer: Sendable {
    private var committedEndsWithSpace = true  // true while nothing is committed

    mutating func apply(_ text: String, isFinal: Bool) -> String {
        guard !text.isEmpty else { return "" }
        let needsSpace = !committedEndsWithSpace && !(text.first?.isWhitespace ?? false)
        let out = needsSpace ? " " + text : text
        if isFinal { committedEndsWithSpace = out.last?.isWhitespace ?? true }
        return out
    }
}

/// Packs a stream of chunks into PCM buffers in the analyzer's format. Single-consumer: it keeps
/// one stateful converter for the whole stream, so resampling is continuous across chunks.
final class PCMStreamPacker {
    private let format: AVAudioFormat
    private var converter: AVAudioConverter?
    private var converterSource: AVAudioFormat?

    init(format: AVAudioFormat) { self.format = format }

    func buffer(from chunk: AudioChunk) -> AVAudioPCMBuffer? {
        let channels = max(chunk.format.channelCount, 1)
        let frames = chunk.samples.count / channels
        guard frames > 0 else { return nil }
        if format.channelCount == AVAudioChannelCount(channels), format.sampleRate == chunk.format.sampleRate, channels == 1,
            let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))
        {
            switch format.commonFormat {
            case .pcmFormatFloat32:
                guard let dst = out.floatChannelData?[0] else { return nil }
                chunk.samples.withUnsafeBufferPointer { dst.update(from: $0.baseAddress!, count: frames) }
            case .pcmFormatInt16:
                guard let dst = out.int16ChannelData?[0] else { return nil }
                for i in 0..<frames {
                    let v = max(-1, min(1, chunk.samples[i])) * Float(Int16.max)
                    dst[i] = Int16(v.rounded())
                }
            default:
                return convert(chunk, channels: channels)
            }
            out.frameLength = AVAudioFrameCount(frames)
            return out
        }
        return convert(chunk, channels: channels)
    }

    /// Slow path for rate/channel/sample-type mismatches.
    private func convert(_ chunk: AudioChunk, channels: Int) -> AVAudioPCMBuffer? {
        guard
            let src = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: chunk.format.sampleRate,
                channels: AVAudioChannelCount(channels), interleaved: true),
            let converter = converter(from: src)
        else { return nil }
        let frames = chunk.samples.count / channels
        let ratio = format.sampleRate / src.sampleRate
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(Double(frames) * ratio) + 1024) else { return nil }
        let feed = SampleFeeder(samples: chunk.samples, channels: channels, format: src)
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { wanted, outStatus in feed.next(wanted, outStatus) }
        return status == .error ? nil : out
    }

    private func converter(from src: AVAudioFormat) -> AVAudioConverter? {
        if let converter, converterSource == src { return converter }
        guard let c = AVAudioConverter(from: src, to: format) else { return nil }
        // No priming: the default pre-roll drops frames at the start of the stream.
        c.primeMethod = .none
        converter = c
        converterSource = src
        return c
    }
}

/// Packs Float32 chunks into PCM buffers in the analyzer's format (one-shot; streams use `PCMStreamPacker`).
enum PCMPacker {
    static func buffer(from chunk: AudioChunk, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        PCMStreamPacker(format: format).buffer(from: chunk)
    }
}

/// Feeds interleaved samples to the converter's input block in the slices it asks for, then reports
/// "no data now". Handing over more than it asked for makes it drop the surplus.
/// Used on a single thread within one `convert` call, so the unchecked conformance is safe.
private final class SampleFeeder: @unchecked Sendable {
    private let samples: [Float]
    private let channels: Int
    private let format: AVAudioFormat
    private var offset = 0 // in frames

    init(samples: [Float], channels: Int, format: AVAudioFormat) {
        self.samples = samples
        self.channels = channels
        self.format = format
    }

    func next(_ wanted: AVAudioPacketCount, _ status: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
        let remaining = samples.count / channels - offset
        let n = min(Int(wanted), remaining)
        guard n > 0, let slice = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(n)),
            let dst = slice.floatChannelData?[0]
        else {
            status.pointee = .noDataNow
            return nil
        }
        samples.withUnsafeBufferPointer { dst.update(from: $0.baseAddress! + offset * channels, count: n * channels) }
        slice.frameLength = AVAudioFrameCount(n)
        offset += n
        status.pointee = .haveData
        return slice
    }
}
