import Foundation

/// Pure metric functions of the latency bench. No audio, no models, no clock: everything is computed from
/// sample arrays and recorded timestamps, so it is unit-tested.
enum Bench {
    /// Seconds in the analysis windows that decide whether audio is speech (matches the 20 ms feed chunks).
    static let windowSeconds = 0.02

    struct Event: Codable, Equatable, Sendable {
        /// Seconds since the run started when the event arrived.
        var wall: Double
        var text: String
        var isFinal: Bool
        /// End of the event's audio range in seconds, when the engine reports one.
        var rangeEnd: Double?
    }

    /// When each fed chunk was handed to the engine, in seconds since the run started.
    struct FeedClock: Equatable, Sendable {
        var chunkSeconds: Double
        var feedTimes: [Double]

        /// When the chunk containing clip offset `offset` was fed; the last chunk for offsets past the end.
        func wall(ofOffset offset: Double) -> Double? {
            guard !feedTimes.isEmpty else { return nil }
            let index = Int((max(offset, 0) / chunkSeconds + 1e-9).rounded(.down))
            return feedTimes[min(index, feedTimes.count - 1)]
        }

        /// When the last chunk fed at or before `wall` was fed.
        func lastFed(atOrBefore wall: Double) -> Double? {
            // Feed times ascend; find the first one after `wall`.
            var low = 0
            var high = feedTimes.count
            while low < high {
                let mid = (low + high) / 2
                if feedTimes[mid] <= wall + 1e-9 { low = mid + 1 } else { high = mid }
            }
            return low == 0 ? nil : feedTimes[low - 1]
        }
    }

    // MARK: Speech detection

    /// Root mean square of `samples`; zero when empty.
    static func rms(_ samples: ArraySlice<Float>) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sum = 0.0
        for sample in samples { sum += Double(sample) * Double(sample) }
        return Float((sum / Double(samples.count)).squareRoot())
    }

    /// Indices of the first and last sample at or above `threshold` inside a window that qualifies as speech.
    private static func speechWindows(
        samples: [Float], sampleRate: Double, rmsThreshold: Float
    ) -> [(first: Int, last: Int)?] {
        let size = max(Int(sampleRate * windowSeconds), 1)
        var windows: [(first: Int, last: Int)?] = []
        var start = 0
        while start < samples.count {
            let end = min(start + size, samples.count)
            if rms(samples[start..<end]) >= rmsThreshold,
                let first = (start..<end).first(where: { abs(samples[$0]) >= rmsThreshold }),
                let last = (start..<end).last(where: { abs(samples[$0]) >= rmsThreshold })
            {
                windows.append((first, last))
            } else {
                windows.append(nil)
            }
            start = end
        }
        return windows
    }

    /// Seconds of the first sample at or above `rmsThreshold` inside the first window whose RMS reaches it.
    static func speechOnset(samples: [Float], sampleRate: Double, rmsThreshold: Float) -> Double? {
        speechWindows(samples: samples, sampleRate: sampleRate, rmsThreshold: rmsThreshold)
            .lazy.compactMap { $0 }.first.map { Double($0.first) / sampleRate }
    }

    /// Spoken stretches: runs of speech windows, split where silence lasts `silenceMs` or more. A segment
    /// ends just after its last sample at or above `rmsThreshold`.
    static func speechSegments(
        samples: [Float], sampleRate: Double, silenceMs: Int, rmsThreshold: Float
    ) -> [Range<Double>] {
        let size = max(Int(sampleRate * windowSeconds), 1)
        let silenceSamples = Int(sampleRate * Double(silenceMs) / 1000)
        var segments: [Range<Double>] = []
        var open: (start: Int, end: Int)?
        for (index, window) in speechWindows(samples: samples, sampleRate: sampleRate, rmsThreshold: rmsThreshold).enumerated() {
            let windowStart = index * size
            if let window {
                if open == nil { open = (window.first, window.last + 1) } else { open!.end = window.last + 1 }
            } else if let current = open, min(windowStart + size, samples.count) - current.end >= silenceSamples {
                segments.append((Double(current.start) / sampleRate)..<(Double(current.end) / sampleRate))
                open = nil
            }
        }
        if let current = open {
            segments.append((Double(current.start) / sampleRate)..<(Double(current.end) / sampleRate))
        }
        return segments
    }

    // MARK: Latencies

    /// First non-empty event's arrival minus when the onset audio was fed.
    static func firstWordLatency(onset: Double?, events: [Event], clock: FeedClock) -> Double? {
        guard let onset, let fed = clock.wall(ofOffset: onset),
            let first = events.first(where: { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
        else { return nil }
        return first.wall - fed
    }

    /// For each non-final, non-empty event: its arrival minus the last feed before it.
    static func emissionLags(events: [Event], clock: FeedClock) -> [Double] {
        events.compactMap { event in
            guard !event.isFinal, !event.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                let fed = clock.lastFed(atOrBefore: event.wall)
            else { return nil }
            return event.wall - fed
        }
    }

    /// For each sentence end: the arrival of the first final that covers it, minus when that audio was fed.
    /// A final covers a sentence when its range ends no earlier than `tolerance` before the sentence end;
    /// without a range, when it arrives after the sentence end was fed. `nil` where no final covers it.
    static func finalizationLatencies(
        sentenceEnds: [Double], events: [Event], clock: FeedClock, tolerance: Double = 0.3
    ) -> [Double?] {
        let finals = events.filter(\.isFinal)
        return sentenceEnds.map { end in
            guard let fed = clock.wall(ofOffset: end) else { return nil }
            let cover = finals.first { final in
                if let rangeEnd = final.rangeEnd { return rangeEnd >= end - tolerance && final.wall >= fed }
                return final.wall >= fed
            }
            return cover.map { $0.wall - fed }
        }
    }

    // MARK: Stats

    /// Count of `.`, `?` and `!`.
    static func punctuationCount(_ text: String) -> Int {
        text.reduce(0) { $0 + (".?!".contains($1) ? 1 : 0) }
    }

    static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
    }

    /// Nearest-rank percentile, `p` in `0...100`.
    static func percentile(_ values: [Double], p: Double) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let rank = Int((p / 100 * Double(sorted.count)).rounded(.up))
        return sorted[min(max(rank, 1), sorted.count) - 1]
    }

    // MARK: Results

    /// One clip played into one engine configuration. Times are milliseconds.
    struct RunResult: Codable, Equatable, Sendable {
        var clip: String
        var firstWordMs: Double?
        var emissionLagsMs: [Double]
        /// One entry per spoken sentence; `nil` where no final covered it.
        var finalizationMs: [Double?]
        /// Spoken sentences detected in the clip.
        var sentences: Int
        var transcript: String
        var punctuation: Int
        var error: String?
    }

    struct Stat: Codable, Equatable, Sendable {
        var n: Int
        var medianMs: Double
        var p95Ms: Double
    }

    struct ConfigSummary: Codable, Equatable, Sendable {
        var firstWord: Stat?
        var emissionLag: Stat?
        var finalization: Stat?
        var missingFinals: Int
        var errors: Int
        /// Sentence marks in the final transcripts, and spoken sentences, per clip.
        var punctuation: [String: Int]
        var sentences: [String: Int]
    }

    /// One engine configuration: engine, tier and endpoint silence, with its runs.
    struct ConfigResult: Codable, Equatable, Sendable {
        var engine: String
        var model: String?
        var tierMs: Int?
        var silenceMs: Int?
        var runs: [RunResult]
        var summary: ConfigSummary?
    }

    static func stat(_ values: [Double]) -> Stat? {
        guard let median = median(values), let p95 = percentile(values, p: 95) else { return nil }
        return Stat(n: values.count, medianMs: median, p95Ms: p95)
    }

    /// Median and p95 over every run of the configuration, pooled.
    static func summarize(_ config: ConfigResult) -> ConfigSummary {
        var punctuation: [String: Int] = [:]
        var sentences: [String: Int] = [:]
        for run in config.runs {
            punctuation[run.clip, default: 0] += run.punctuation
            sentences[run.clip, default: 0] += run.sentences
        }
        let finals = config.runs.flatMap(\.finalizationMs)
        return ConfigSummary(
            firstWord: stat(config.runs.compactMap(\.firstWordMs)),
            emissionLag: stat(config.runs.flatMap(\.emissionLagsMs)),
            finalization: stat(finals.compactMap { $0 }),
            missingFinals: finals.filter { $0 == nil }.count,
            errors: config.runs.filter { $0.error != nil }.count,
            punctuation: punctuation,
            sentences: sentences)
    }

    private static func cell(_ stat: Stat?) -> String {
        guard let stat else { return "n/a (n=0)" }
        return "\(Int(stat.medianMs.rounded())) / \(Int(stat.p95Ms.rounded())) (n=\(stat.n))"
    }

    /// A Markdown table, one row per configuration. Times are median / p95 in milliseconds, and `n` is how
    /// many measurements each cell rests on (runs for the first word, partial events for the emission lag,
    /// covered sentences for the finalization).
    static func markdown(_ configs: [ConfigResult]) -> String {
        var lines = [
            "| Engine | Tier (ms) | Silence (ms) | First word | Emission lag | Finalization | Punctuation / sentences | Notes |",
            "|---|---|---|---|---|---|---|---|",
        ]
        for config in configs {
            let summary = config.summary ?? summarize(config)
            let punct = summary.sentences.keys.sorted().map { "\($0) \(summary.punctuation[$0] ?? 0)/\(summary.sentences[$0] ?? 0)" }
            var notes: [String] = []
            if summary.missingFinals > 0 { notes.append("\(summary.missingFinals) sentences without final") }
            if summary.errors > 0 { notes.append("\(summary.errors) failed runs") }
            lines.append(
                "| \(config.model ?? config.engine) | \(config.tierMs.map(String.init) ?? "-") | "
                    + "\(config.silenceMs.map(String.init) ?? "-") | \(cell(summary.firstWord)) | "
                    + "\(cell(summary.emissionLag)) | \(cell(summary.finalization)) | "
                    + "\(punct.joined(separator: ", ")) | \(notes.joined(separator: "; ")) |")
        }
        return lines.joined(separator: "\n")
    }
}
