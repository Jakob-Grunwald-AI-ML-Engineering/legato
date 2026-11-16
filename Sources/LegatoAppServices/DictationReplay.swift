#if DEBUG || LEGATO_INTERNAL
import Foundation

/// A recorded Soniox token timeline for the debug bridge (`dictation-debug-replay`): the responses of one
/// real-time stream with the time each arrived, replayed into the dictation route without a microphone or socket.
/// The file is JSON: an object with a `responses` array (the streaming spike's cache record), a bare array of
/// responses, or JSON lines. A response is `{"t": <seconds>, "tokens": [{"text", "is_final", "start_ms", "end_ms",
/// "confidence", "language"}]}`; a response without `t` follows the previous one at once. The stream's own end
/// (`<fin>` tokens, `finished`) is dropped: the replay ends the take itself.
public struct DictationReplayTimeline: Sendable, Equatable {
    public struct Frame: Sendable, Equatable {
        /// Seconds since the stream started.
        public var at: Double
        /// The response as the provider socket would deliver it.
        public var json: String
    }
    public enum ReplayError: Error, CustomStringConvertible, Sendable, Equatable {
        case unreadable, empty, routeClosed, invalidFile, invalidPCM
        public var description: String {
            switch self {
            case .unreadable: "The replay file is not a Soniox token timeline (JSON with a responses array, or JSON lines)."
            case .empty: "The replay file holds no tokens."
            case .routeClosed: "The dictation route is not open: open the keyboard on the ABC typing surface first."
            case .invalidFile: "Replay inputs must be regular files in the bridge directory, named without paths or a leading dot, within the replay size limit."
            case .invalidPCM: "Replay audio must be nonempty 16 kHz mono signed little-endian PCM16, at most 10 minutes (19,200,000 bytes)."
            }
        }
    }

    public var frames: [Frame]
    /// Operational test-file limits, not measured speech/admission thresholds.
    public static let maximumTimelineBytes = 16_000_000

    public static func readFile(_ name: String, in root: URL, maximumBytes: Int) throws -> Data {
        guard !name.isEmpty, !name.hasPrefix("."), !name.contains("/"), !name.contains("\\"), !name.contains("\0") else { throw ReplayError.invalidFile }
        let url = root.appendingPathComponent(name)
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, size > 0, size <= maximumBytes else { throw ReplayError.invalidFile }
        let data = try Data(contentsOf: url)
        guard data.count <= maximumBytes else { throw ReplayError.invalidFile }
        return data
    }
    public var duration: Double { frames.last?.at ?? 0 }
    public var tokenCount: Int {
        frames.reduce(0) { sum, frame in
            sum + ((try? JSONSerialization.jsonObject(with: Data(frame.json.utf8)) as? [String: Any])?["tokens"] as? [Any] ?? []).count
        }
    }

    public static func parse(_ data: Data) throws -> DictationReplayTimeline {
        var responses: [[String: Any]] = []
        if let object = try? JSONSerialization.jsonObject(with: data) {
            if let record = object as? [String: Any] {
                if let list = record["responses"] as? [[String: Any]] { responses = list }
                else if record["tokens"] != nil { responses = [record] }
            } else if let list = object as? [[String: Any]] { responses = list }
        } else {
            for line in String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline) {
                guard let value = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { throw ReplayError.unreadable }
                responses.append(value)
            }
        }
        guard !responses.isEmpty else { throw ReplayError.unreadable }
        var frames: [Frame] = []
        var time = 0.0
        for response in responses {
            if let t = (response["t"] as? Double) ?? (response["t"] as? Int).map(Double.init) { time = max(time, t) }
            guard response["error_code"] == nil, var tokens = response["tokens"] as? [[String: Any]] else { continue }
            tokens.removeAll { ($0["text"] as? String) == "<fin>" }
            guard !tokens.isEmpty,
                  let json = try? JSONSerialization.data(withJSONObject: ["tokens": tokens], options: [.sortedKeys]) else { continue }
            frames.append(.init(at: time, json: String(decoding: json, as: UTF8.self)))
        }
        guard !frames.isEmpty else { throw ReplayError.empty }
        return DictationReplayTimeline(frames: frames)
    }
}

/// Original capture PCM, sharing the live activity classifier; no microphone or provider socket is opened.
public struct DictationReplayPCM: Sendable, Equatable {
    public static let maximumBytes = 19_200_000 // Ten minutes at 16 kHz mono PCM16; operational safety bound.
    static let frameBytes = 640 // 20 ms, the capture/activity contract.
    public let data: Data
    public var duration: Double { Double(data.count) / 32_000 }

    public init(_ data: Data) throws {
        guard !data.isEmpty, data.count.isMultiple(of: 2), data.count <= Self.maximumBytes else { throw DictationReplayTimeline.ReplayError.invalidPCM }
        self.data = data
    }
}

/// One ordered clock domain. A PCM frame completes at its original sample time; all PCM through a response's
/// arrival is consumed before that response can deliver an endpoint. The final short frame is retained.
struct DictationReplayCursor {
    enum Event: Equatable {
        case pcm(at: Double, Data)
        case response(DictationReplayTimeline.Frame)
        var at: Double {
            switch self { case .pcm(let at, _): at; case .response(let frame): frame.at }
        }
    }
    let timeline: DictationReplayTimeline
    let pcm: DictationReplayPCM?
    private var responseIndex = 0
    private var audioOffset = 0

    init(timeline: DictationReplayTimeline, pcm: DictationReplayPCM?) { self.timeline = timeline; self.pcm = pcm }

    mutating func next() -> Event? {
        let response = timeline.frames.indices.contains(responseIndex) ? timeline.frames[responseIndex] : nil
        if let pcm, audioOffset < pcm.data.count {
            let end = min(audioOffset + DictationReplayPCM.frameBytes, pcm.data.count)
            let at = Double(end) / 32_000
            if response == nil || at <= response!.at {
                let chunk = pcm.data.subdata(in: audioOffset..<end)
                audioOffset = end
                return .pcm(at: at, chunk)
            }
        }
        guard let response else { return nil }
        responseIndex += 1
        return .response(response)
    }
}
#endif
