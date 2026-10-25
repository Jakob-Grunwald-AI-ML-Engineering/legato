import Foundation
import Testing

@testable import legato_bench

private let rate = 16_000.0

private func silence(_ seconds: Double) -> [Float] { [Float](repeating: 0, count: Int(seconds * rate)) }
private func tone(_ seconds: Double, amp: Float = 0.1) -> [Float] {
    (0..<Int(seconds * rate)).map { amp * sin(Float($0) * 0.3) }
}

@Suite struct OnsetTests {
    @Test func onsetIsTheFirstLoudSample() {
        let samples = silence(1.0) + tone(0.5)
        let onset = Bench.speechOnset(samples: samples, sampleRate: rate, rmsThreshold: 0.004)
        #expect(onset != nil)
        // The first tone samples are tiny, so the first sample over the threshold is a few samples in.
        #expect(onset! >= 1.0 && onset! < 1.002)
    }

    @Test func pureSilenceHasNoOnset() {
        #expect(Bench.speechOnset(samples: silence(2), sampleRate: rate, rmsThreshold: 0.004) == nil)
        #expect(Bench.speechOnset(samples: [], sampleRate: rate, rmsThreshold: 0.004) == nil)
    }

    @Test func aLoneClickInSilenceIsNotSpeech() {
        var samples = silence(1.0)
        samples[8_000] = 0.05  // window RMS 0.05 / sqrt(320) = 0.0028, below 0.004
        #expect(Bench.speechOnset(samples: samples, sampleRate: rate, rmsThreshold: 0.004) == nil)
    }

    @Test func rmsOfConstantSignal() {
        #expect(abs(Bench.rms([Float](repeating: 0.5, count: 100)[...]) - 0.5) < 1e-6)
        #expect(Bench.rms([]) == 0)
    }
}

@Suite struct SegmentTests {
    @Test func pauseAtLeastSilenceSplitsSentences() {
        let samples = tone(1.0) + silence(1.5) + tone(2.0) + silence(1.5)
        let segs = Bench.speechSegments(samples: samples, sampleRate: rate, silenceMs: 1200, rmsThreshold: 0.004)
        #expect(segs.count == 2)
        #expect(abs(segs[0].upperBound - 1.0) < 0.01)
        #expect(abs(segs[1].lowerBound - 2.5) < 0.03)
        #expect(abs(segs[1].upperBound - 4.5) < 0.01)
    }

    @Test func shorterPauseDoesNotSplit() {
        let samples = tone(1.0) + silence(0.8) + tone(1.0)
        let segs = Bench.speechSegments(samples: samples, sampleRate: rate, silenceMs: 1200, rmsThreshold: 0.004)
        #expect(segs.count == 1)
        #expect(abs(segs[0].upperBound - 2.8) < 0.01)
    }

    @Test func sameClipSplitsWhenSilenceSettingIsShorter() {
        let samples = tone(1.0) + silence(0.8) + tone(1.0)
        #expect(Bench.speechSegments(samples: samples, sampleRate: rate, silenceMs: 500, rmsThreshold: 0.004).count == 2)
        #expect(Bench.speechSegments(samples: samples, sampleRate: rate, silenceMs: 800, rmsThreshold: 0.004).count == 2)
    }

    @Test func noSpeechNoSegments() {
        #expect(Bench.speechSegments(samples: silence(3), sampleRate: rate, silenceMs: 800, rmsThreshold: 0.004).isEmpty)
    }
}

@Suite struct TimingTests {
    // 20 ms chunks fed exactly on the clock.
    private let clock = Bench.FeedClock(chunkSeconds: 0.02, feedTimes: (0..<500).map { Double($0) * 0.02 })

    @Test func clockLookups() {
        #expect(clock.wall(ofOffset: 1.0) == 1.0)
        #expect(abs(clock.wall(ofOffset: 1.009)! - 1.0) < 1e-9)
        #expect(clock.wall(ofOffset: 999) == clock.feedTimes.last)
        #expect(clock.lastFed(atOrBefore: 1.03) == 1.02)
        #expect(clock.lastFed(atOrBefore: -1) == nil)
    }

    @Test func firstWordLatencyIsFirstNonEmptyEventAfterOnset() {
        let events = [
            Bench.Event(wall: 0.5, text: "", isFinal: false, rangeEnd: nil),
            Bench.Event(wall: 2.4, text: "hello", isFinal: false, rangeEnd: nil),
            Bench.Event(wall: 3.0, text: "hello world", isFinal: false, rangeEnd: nil),
        ]
        let latency = Bench.firstWordLatency(onset: 1.0, events: events, clock: clock)
        #expect(latency != nil && abs(latency! - 1.4) < 1e-9)
    }

    @Test func firstWordLatencyNilWithoutOnsetOrText() {
        #expect(Bench.firstWordLatency(onset: nil, events: [], clock: clock) == nil)
        #expect(Bench.firstWordLatency(onset: 1, events: [Bench.Event(wall: 2, text: " ", isFinal: false, rangeEnd: nil)], clock: clock) == nil)
    }

    @Test func emissionLagIsArrivalMinusLastFeed() {
        let events = [
            Bench.Event(wall: 1.03, text: "a", isFinal: false, rangeEnd: nil),  // last fed 1.02 -> 0.01
            Bench.Event(wall: 2.10, text: "a b", isFinal: false, rangeEnd: nil),  // last fed 2.10 -> 0
            Bench.Event(wall: 2.5, text: "a b.", isFinal: true, rangeEnd: 2.4),  // finals excluded
            Bench.Event(wall: 3.0, text: "", isFinal: false, rangeEnd: nil),  // empty excluded
        ]
        let lags = Bench.emissionLags(events: events, clock: clock)
        #expect(lags.count == 2)
        #expect(abs(lags[0] - 0.01) < 1e-9)
        #expect(abs(lags[1] - 0.0) < 1e-9)
    }

    @Test func finalizationLatencyUsesTheFinalThatCoversEachSentence() {
        // Sentences end at 2.0 s and 6.0 s. Finals cover up to 3.2 (end+silence) and 7.2.
        let events = [
            Bench.Event(wall: 1.0, text: "hel", isFinal: false, rangeEnd: nil),
            Bench.Event(wall: 3.3, text: "Hello there.", isFinal: true, rangeEnd: 3.2),
            Bench.Event(wall: 7.5, text: "Second one.", isFinal: true, rangeEnd: 7.2),
        ]
        let lat = Bench.finalizationLatencies(sentenceEnds: [2.0, 6.0], events: events, clock: clock)
        #expect(lat.count == 2)
        #expect(abs(lat[0]! - 1.3) < 1e-9)
        #expect(abs(lat[1]! - 1.5) < 1e-9)
    }

    @Test func finalizationAllowsRangesThatEndSlightlyBeforeTheSentenceEnd() {
        let events = [Bench.Event(wall: 2.4, text: "Hi.", isFinal: true, rangeEnd: 1.8)]
        let lat = Bench.finalizationLatencies(sentenceEnds: [2.0], events: events, clock: clock)
        #expect(lat.count == 1 && lat[0] != nil)
        #expect(abs(lat[0]! - 0.4) < 1e-9)
    }

    @Test func uncoveredSentenceIsNil() {
        let events = [Bench.Event(wall: 3.3, text: "Hello.", isFinal: true, rangeEnd: 3.2)]
        let lat = Bench.finalizationLatencies(sentenceEnds: [2.0, 9.0], events: events, clock: clock)
        #expect(lat.count == 2)
        #expect(lat[0] != nil)
        #expect(lat[1] == nil)
    }

    @Test func finalWithoutRangeCoversTheFirstSentenceFedBeforeIt() {
        let events = [Bench.Event(wall: 3.3, text: "Hello.", isFinal: true, rangeEnd: nil)]
        let lat = Bench.finalizationLatencies(sentenceEnds: [2.0], events: events, clock: clock)
        #expect(lat.count == 1 && lat[0] != nil)
        #expect(abs(lat[0]! - 1.3) < 1e-9)
    }
}

@Suite struct StatsTests {
    @Test func medianOddEvenEmpty() {
        #expect(Bench.median([5, 1, 3]) == 3)
        #expect(Bench.median([4, 1, 3, 2]) == 2.5)
        #expect(Bench.median([]) == nil)
    }

    @Test func percentileNearestRank() {
        let values = (1...100).map(Double.init)
        #expect(Bench.percentile(values, p: 95) == 95)
        #expect(Bench.percentile(values, p: 100) == 100)
        #expect(Bench.percentile([7], p: 95) == 7)
        #expect(Bench.percentile([3, 1, 2], p: 95) == 3)
        #expect(Bench.percentile([], p: 95) == nil)
    }

    @Test func punctuationCountsSentenceMarks() {
        #expect(Bench.punctuationCount("Hello there. How are you? Fine!") == 3)
        #expect(Bench.punctuationCount("no marks, just commas") == 0)
        #expect(Bench.punctuationCount("") == 0)
    }
}

@Suite struct ReportTests {
    private func run(_ clip: String, firstWord: Double?, lags: [Double], finals: [Double?], punct: Int, sentences: Int) -> Bench.RunResult {
        Bench.RunResult(
            clip: clip, firstWordMs: firstWord, emissionLagsMs: lags, finalizationMs: finals, sentences: sentences,
            transcript: "x", punctuation: punct, error: nil)
    }

    @Test func summaryPoolsRunsAndCountsMissingFinals() {
        let config = Bench.ConfigResult(
            engine: "nemotron-multilingual", model: "nemotron-multilingual-560", tierMs: 560, silenceMs: 800,
            runs: [
                run("de", firstWord: 900, lags: [10, 20, 30], finals: [1000, nil], punct: 1, sentences: 2),
                run("en", firstWord: 700, lags: [40], finals: [1200], punct: 2, sentences: 1),
            ])
        let summary = Bench.summarize(config)
        #expect(summary.firstWord == Bench.Stat(n: 2, medianMs: 800, p95Ms: 900))
        #expect(summary.emissionLag?.n == 4)
        #expect(summary.emissionLag?.medianMs == 25)
        #expect(summary.finalization == Bench.Stat(n: 2, medianMs: 1100, p95Ms: 1200))
        #expect(summary.missingFinals == 1)
        #expect(summary.punctuation == ["de": 1, "en": 2])
        #expect(summary.sentences == ["de": 2, "en": 1])
    }

    @Test func emptyConfigHasNoStats() {
        let summary = Bench.summarize(Bench.ConfigResult(engine: "apple-speech", model: nil, tierMs: nil, silenceMs: nil, runs: []))
        #expect(summary.firstWord == nil && summary.emissionLag == nil && summary.finalization == nil)
    }

    @Test func markdownHasOneRowPerConfig() {
        let config = Bench.ConfigResult(
            engine: "apple-speech", model: nil, tierMs: nil, silenceMs: nil,
            runs: [run("en", firstWord: 500, lags: [10], finals: [900], punct: 1, sentences: 1)])
        let table = Bench.markdown([config, config])
        let lines = table.split(separator: "\n")
        #expect(lines.count == 4)  // header, separator, two rows
        #expect(lines[0].contains("First word"))
        #expect(lines[2].contains("apple-speech"))
        #expect(lines[2].contains("500"))
    }
}

#if os(macOS)
/// A clip with two languages must not pin one of them: a session locale is a hard language hint for the
/// FluidAudio engines, and pinning en-US on the mixed clip made Nemotron drop or mangle the German sentences.
@Suite struct SessionLocaleTests {
    private let runner = BenchRunner(options: BenchCLI.Options())

    private func clip(_ name: String) -> Clip {
        Clip(name: name, languages: Clip.known[name] ?? [], samples: [])
    }

    @Test func mixedClipRunsWithoutALanguageHint() {
        let locale: Locale? = runner.locale(for: clip("mixed-long"))
        #expect(locale == nil)
    }

    @Test func singleLanguageClipsKeepTheirOwnLocale() {
        let german: Locale? = runner.locale(for: clip("de"))
        let english: Locale? = runner.locale(for: clip("en"))
        #expect(german?.identifier == "de-DE")
        #expect(english?.identifier == "en-US")
    }
}

/// Parakeet EOU is English only: German or mixed clips through it produce garbage that skews its pooled latencies
/// (a 6.7 s "first word" on the mixed clip made EOU-160 look like a 3.6 s engine).
@Suite struct ClipCompatibilityTests {
    private func clip(_ name: String) -> Clip { Clip(name: name, languages: Clip.known[name] ?? [], samples: []) }
    private let eou = BenchConfig(engine: "parakeet-eou", modelID: "parakeet-eou-160", tierMs: 160, silenceMs: 800)
    private let nemotron = BenchConfig(engine: "nemotron-multilingual", modelID: "nemotron-multilingual-560", tierMs: 560, silenceMs: 800)

    @Test func eouOnlyPlaysEnglishClips() {
        #expect(eou.accepts(clip("en")))
        #expect(!eou.accepts(clip("de")))
        #expect(!eou.accepts(clip("mixed-long")))
    }

    @Test func multilingualEnginesPlayEveryClip() {
        for name in ["en", "de", "mixed-long"] { #expect(nemotron.accepts(clip(name))) }
        #expect(BenchConfig(engine: "apple-speech").accepts(clip("mixed-long")))
    }
}
#endif
