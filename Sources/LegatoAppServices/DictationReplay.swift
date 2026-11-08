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
        case unreadable, empty, routeClosed
        public var description: String {
            switch self {
            case .unreadable: "The replay file is not a Soniox token timeline (JSON with a responses array, or JSON lines)."
            case .empty: "The replay file holds no tokens."
            case .routeClosed: "The dictation route is not open: open the keyboard on the ABC typing surface first."
            }
        }
    }

    public var frames: [Frame]
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
#endif
