import Foundation
import LegatoCore
import LegatoModels
import Synchronization
import Testing
@testable import LegatoFluidAudio

@Suite("Seams") enum SeamTests {}

func tok(_ text: String, _ start: TimeInterval, _ end: TimeInterval) -> TimedToken {
    TimedToken(text: text, start: start, end: end)
}


/// A scripted model: text grows with fed samples; `commit` returns what was said and starts over.
final class ScriptedBackend: StreamingBackend, @unchecked Sendable {
    private let state = Mutex(State())
    struct State {
        var fedInSegment = 0
        var words: [String] = []
        var spoken: [String] = []
        var applied: [String] = []
        var detected: String?
        var processCalls = 0
        var commits = 0
    }
    let wordsAt: [Int: String]  // samples fed in segment -> word recognised at that point

    init(wordsAt: [Int: String] = [:], detected: String? = nil) {
        self.wordsAt = wordsAt
        state.withLock { $0.detected = detected }
    }

    func process(_ samples: [Float]) async throws {
        state.withLock {
            $0.processCalls += 1
            $0.fedInSegment += samples.count
            if let word = wordsAt[$0.fedInSegment] { $0.words.append(word) }
        }
    }
    func partial() async -> String { state.withLock { $0.words.joined(separator: " ") } }
    func commit() async throws -> String {
        state.withLock {
            let text = $0.words.joined(separator: " ")
            $0.spoken.append(text)
            $0.words = []
            $0.fedInSegment = 0
            $0.commits += 1
            return text
        }
    }
    func detectedLanguage() async -> String? { state.withLock { $0.detected } }
    func applyLanguage(_ hint: String) async { state.withLock { $0.applied.append(hint) } }
    var snapshot: State { state.withLock { $0 } }
}

func chunks(_ pattern: [(samples: Int, level: Float)]) -> AsyncStream<AudioChunk> {
    let spec = AudioFormatSpec(sampleRate: 16_000, channelCount: 1)
    return AsyncStream { continuation in
        for part in pattern {
            continuation.yield(AudioChunk(samples: [Float](repeating: part.level, count: part.samples), format: spec))
        }
        continuation.finish()
    }
}


/// An installer that never touches the network: "installed" is a flag.
final class FakeInstaller: ModelInstaller, @unchecked Sendable {
    private let installed = Mutex(false)
    let folderName: String
    init(folderName: String = "fake", installed: Bool = false) {
        self.folderName = folderName
        self.installed.withLock { $0 = installed }
    }
    func installFolder(root: URL) -> URL { root.appendingPathComponent(folderName) }
    var isInstalledNow: Bool { installed.withLock { $0 } }
    func isInstalled(root: URL) async -> Bool { isInstalledNow }
    func install(root: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        progress(0.5)
        progress(1)
        installed.withLock { $0 = true }
    }
    func warm(root: URL) async throws {}
}

func makeManager(id: String, installer: FakeInstaller) -> ModelManager {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("legato-seam-\(UUID().uuidString)")
    let descriptor = ModelDescriptor(
        id: id, kind: .speechStreaming, displayName: "Fake", approxBytes: 1, licence: "test", family: "fake")
    let defaults = UserDefaults(suiteName: "legato-seam-\(UUID().uuidString)")!
    // A model staged as installed carries the marker an earlier install would have left.
    if installer.isInstalledNow {
        try? InstallMarker.write(in: installer.installFolder(root: root), id: id, stage: .installed)
    }
    return ModelManager(root: root, catalog: [descriptor], installers: [id: installer], selection: SelectionStore(defaults: defaults))
}


extension SeamTests {

// MARK: Silence endpointer

@Suite("Silence endpointer")
struct SilenceEndpointerTests {
    private let silence = [Float](repeating: 0, count: 1_600)  // 100 ms at 16 kHz
    private let speech = [Float](repeating: 0.1, count: 1_600)

    @Test func defaultsAreTwelveHundredMsAtSixteenKilohertz() {
        let endpointer = SilenceEndpointer()
        #expect(endpointer.silenceSamples == 19_200)
    }

    @Test func commitsAtNMsOfSilenceAndNotBefore() {
        var endpointer = SilenceEndpointer(silenceMs: 1200)
        // 11 x 100 ms = 1100 ms of silence: not yet.
        for _ in 0..<11 { #expect(endpointer.feed(silence, hasText: true) == false) }
        // The 12th reaches exactly 19,200 samples.
        let r1 = endpointer.feed(silence, hasText: true)
        #expect(r1)
    }

    @Test func oneSampleShortOfTheLimitDoesNotCommit() {
        var endpointer = SilenceEndpointer(silenceMs: 1200)
        let r2 = endpointer.feed([Float](repeating: 0, count: 19_199), hasText: true)
        #expect(r2 == false)
        let r3 = endpointer.feed([0], hasText: true)
        #expect(r3)
    }

    @Test func speechResetsTheSilenceRun() {
        var endpointer = SilenceEndpointer(silenceMs: 1200)
        for _ in 0..<11 { _ = endpointer.feed(silence, hasText: true) }
        let r4 = endpointer.feed(speech, hasText: true)
        #expect(r4 == false)
        for _ in 0..<11 { #expect(endpointer.feed(silence, hasText: true) == false) }
        let r5 = endpointer.feed(silence, hasText: true)
        #expect(r5)
    }

    @Test func nothingToCommitWithoutText() {
        var endpointer = SilenceEndpointer(silenceMs: 1200)
        for _ in 0..<30 { #expect(endpointer.feed(silence, hasText: false) == false) }
        // Text appearing after a long silence commits on the next silent chunk: the run is already long enough.
        let r6 = endpointer.feed(silence, hasText: true)
        #expect(r6)
    }

    @Test func aCommitStartsANewSilenceRun() {
        var endpointer = SilenceEndpointer(silenceMs: 1200)
        for _ in 0..<11 { _ = endpointer.feed(silence, hasText: true) }
        let r7 = endpointer.feed(silence, hasText: true)
        #expect(r7)
        let r8 = endpointer.feed(silence, hasText: true)
        #expect(r8 == false)
    }

    @Test func thresholdIsRMSNotPeak() {
        var endpointer = SilenceEndpointer(silenceMs: 100, rmsThreshold: 0.004)
        // One spike in an otherwise silent chunk: RMS = 0.5/sqrt(1600) = 0.0125 > 0.004 -> speech.
        var chunk = silence
        chunk[0] = 0.5
        let r9 = endpointer.feed(chunk, hasText: true)
        #expect(r9 == false)
        // Quiet noise below the threshold counts as silence.
        let hiss = [Float](repeating: 0.003, count: 1_600)
        let r10 = endpointer.feed(hiss, hasText: true)
        #expect(r10)
    }

    @Test func resetForgetsTheRun() {
        var endpointer = SilenceEndpointer(silenceMs: 1200)
        for _ in 0..<11 { _ = endpointer.feed(silence, hasText: true) }
        endpointer.reset()
        let r11 = endpointer.feed(silence, hasText: true)
        #expect(r11 == false)
    }

    @Test func heardSpeechTracksNonSilentChunksUntilReset() {
        var endpointer = SilenceEndpointer(silenceMs: 1200)
        #expect(endpointer.heardSpeech == false)
        _ = endpointer.feed(silence, hasText: false)
        #expect(endpointer.heardSpeech == false)
        _ = endpointer.feed(speech, hasText: false)
        #expect(endpointer.heardSpeech)
        endpointer.reset()
        #expect(endpointer.heardSpeech == false)
    }

    @Test func emptyChunkChangesNothing() {
        var endpointer = SilenceEndpointer(silenceMs: 1200)
        let r12 = endpointer.feed([], hasText: true)
        #expect(r12 == false)
    }
}

// MARK: Event mapper

@Suite("Partial event mapper")
struct PartialEventMapperTests {
    @Test func partialBecomesAVolatileEvent() {
        var mapper = PartialEventMapper()
        let event = mapper.partial("hello wor")
        #expect(event == TranscriptEvent(stream: .mic, text: "hello wor", isFinal: false))
    }

    @Test func unchangedPartialEmitsNothing() {
        var mapper = PartialEventMapper()
        _ = mapper.partial("hello")
        let r13 = mapper.partial("hello")
        #expect(r13 == nil)
        let r14 = mapper.partial("  hello ")
        #expect(r14 == nil)
    }

    @Test func partialsAreTrimmed() {
        var mapper = PartialEventMapper()
        let r15 = mapper.partial("  hello  ")?.text
        #expect(r15 == "hello")
    }

    @Test func emptyPartialBeforeAnythingEmitsNothing() {
        var mapper = PartialEventMapper()
        let r16 = mapper.partial("")
        #expect(r16 == nil)
    }

    @Test func finishTextBecomesAFinalEventWithRange() {
        var mapper = PartialEventMapper()
        let events = mapper.commit("Hello world.", range: 0.5..<2.5)
        #expect(events == [TranscriptEvent(stream: .mic, text: "Hello world.", isFinal: true, range: 0.5..<2.5)])
    }

    @Test func commitClearsTheShownPartial() {
        var mapper = PartialEventMapper()
        _ = mapper.partial("Hello wor")
        let events = mapper.commit("Hello world.", range: 0..<1)
        #expect(events.map(\.isFinal) == [true, false])
        #expect(events.last?.text == "")
    }

    @Test func emptyPartialAfterCommitEmitsNothingMore() {
        var mapper = PartialEventMapper()
        _ = mapper.partial("Hello")
        _ = mapper.commit("Hello.", range: 0..<1)
        let r17 = mapper.partial("")
        #expect(r17 == nil)
    }

    @Test func emptyFinishTextOnlyClearsAShownPartial() {
        var mapper = PartialEventMapper()
        let r18 = mapper.commit("  ", range: 0..<1).isEmpty
        #expect(r18)
        _ = mapper.partial("uh")
        let events = mapper.commit("", range: 0..<1)
        #expect(events == [TranscriptEvent(stream: .mic, text: "", isFinal: false)])
    }

    @Test func laterSegmentsAreSeparatedByASpace() {
        var mapper = PartialEventMapper()
        let r19 = mapper.commit("One.", range: 0..<1).first?.text
        #expect(r19 == "One.")
        let r20 = mapper.partial("tw")?.text
        #expect(r20 == " tw")
        let r21 = mapper.commit("Two.", range: 1..<2).first?.text
        #expect(r21 == " Two.")
    }

    @Test func assemblerCommitsReadableText() {
        var mapper = PartialEventMapper()
        var assembler = TranscriptAssembler()
        for event in [mapper.partial("hel"), mapper.partial("hello")].compactMap({ $0 })
            + mapper.commit("Hello.", range: 0..<1)
            + [mapper.partial("how")].compactMap({ $0 })
            + mapper.commit("How are you?", range: 1..<2)
        {
            _ = assembler.apply(event)
        }
        #expect(assembler.committedText == "Hello. How are you?")
        #expect(assembler.volatileText == "")
    }

    @Test func streamIsPassedThrough() {
        var mapper = PartialEventMapper(stream: .system)
        let r22 = mapper.partial("x")?.stream
        #expect(r22 == .system)
        let r23 = mapper.commit("y", range: nil).first?.stream
        #expect(r23 == .system)
    }
}

// MARK: Language clamp

@Suite("Language clamp")
struct LanguageClampTests {
    private let de = Locale(identifier: "de_DE")
    private let en = Locale(identifier: "en_US")
    private let ja = Locale(identifier: "ja_JP")

    @Test func aSingleLocaleIsThatHint() {
        let clamp = LanguageClamp(preferred: [de])
        #expect(clamp.hint == "de-DE")
    }

    @Test func aSetOfLocalesIsAuto() {
        #expect(LanguageClamp(preferred: [de, en]).hint == "auto")
    }

    @Test func noLocalesIsAuto() {
        #expect(LanguageClamp(preferred: []).hint == "auto")
    }

    @Test func configuredLocalesWinOverTheSessionLocale() {
        #expect(LanguageClamp.preferred(configured: [de, en], session: en) == [de, en])
        #expect(LanguageClamp.preferred(configured: [de], session: en) == [de])
    }

    @Test func theSessionLocaleIsTheHintWhenNothingIsConfigured() {
        #expect(LanguageClamp.preferred(configured: [], session: de) == [de])
        #expect(LanguageClamp.preferred(configured: [], session: nil) == [])
    }

    @Test func aBareLanguageLocaleUsesTheBareCode() {
        #expect(LanguageClamp(preferred: [Locale(identifier: "de")]).hint == "de")
    }

    @Test func tagMapsToALocale() {
        #expect(LanguageClamp.locale(fromTag: "en-US").language.languageCode?.identifier == "en")
        #expect(LanguageClamp.locale(fromTag: "en-US").region?.identifier == "US")
        #expect(LanguageClamp.locale(fromTag: "zh-CN").language.languageCode?.identifier == "zh")
        #expect(LanguageClamp.locale(fromTag: "es_419").language.languageCode?.identifier == "es")
        #expect(LanguageClamp.locale(fromTag: "de").language.languageCode?.identifier == "de")
    }

    @Test func detectionInsideTheSetNeverPins() {
        var clamp = LanguageClamp(preferred: [de, en])
        clamp.observe(detected: "en-GB")  // same language as en_US
        let r24 = clamp.segmentBoundary()
        #expect(r24 == nil)
        #expect(clamp.hint == "auto")
    }

    @Test func detectionOutsideTheSetPinsTheFirstPreferredAtTheNextBoundary() {
        var clamp = LanguageClamp(preferred: [de, en])
        clamp.observe(detected: "fr-FR")
        #expect(clamp.hint == "auto", "nothing changes mid-segment")
        let r25 = clamp.segmentBoundary()
        #expect(r25 == "de-DE")
        #expect(clamp.hint == "de-DE")
        let r26 = clamp.segmentBoundary()
        #expect(r26 == nil, "the pin applies once")
    }

    @Test func aPinnedClampIgnoresFurtherDetections() {
        var clamp = LanguageClamp(preferred: [de, en])
        clamp.observe(detected: "fr-FR")
        _ = clamp.segmentBoundary()
        clamp.observe(detected: "ja-JP")
        let r27 = clamp.segmentBoundary()
        #expect(r27 == nil)
        #expect(clamp.hint == "de-DE")
    }

    @Test func nextSessionStartsOnAutoAgain() {
        var clamp = LanguageClamp(preferred: [de, en])
        clamp.observe(detected: "fr-FR")
        _ = clamp.segmentBoundary()
        clamp.beginSession()
        #expect(clamp.hint == "auto")
        clamp.observe(detected: "en-US")
        let r28 = clamp.segmentBoundary()
        #expect(r28 == nil)
    }

    @Test func aPendingPinDoesNotSurviveASessionReset() {
        var clamp = LanguageClamp(preferred: [de, en])
        clamp.observe(detected: "fr-FR")
        clamp.beginSession()
        let r29 = clamp.segmentBoundary()
        #expect(r29 == nil)
    }

    @Test func aSingleHintIsNeverRepinned() {
        var clamp = LanguageClamp(preferred: [de])
        clamp.observe(detected: "en-US")
        let r30 = clamp.segmentBoundary()
        #expect(r30 == nil)
        #expect(clamp.hint == "de-DE")
        clamp.beginSession()
        #expect(clamp.hint == "de-DE")
    }

    @Test func missingDetectionChangesNothing() {
        var clamp = LanguageClamp(preferred: [de, en])
        clamp.observe(detected: nil)
        let r31 = clamp.segmentBoundary()
        #expect(r31 == nil)
        _ = ja
    }
}

// MARK: Segment driver

    @Suite("Segment driver")
    struct SegmentDriverTests {
        private func driver(preferred: [Locale] = []) -> SegmentDriver {
            SegmentDriver(
                endpointer: SilenceEndpointer(silenceMs: 1200), mapper: PartialEventMapper(), clamp: LanguageClamp(preferred: preferred))
        }

        @Test func speechThenSilenceCommitsOneSegmentWithItsRange() async throws {
            // 1 s of speech (words land at 0.5 s and 1 s), then 1.3 s of silence in 100 ms chunks (the commit lands at 1.2 s of it).
            let backend = ScriptedBackend(wordsAt: [8_000: "hello", 16_000: "world"])
            var pattern: [(samples: Int, level: Float)] = Array(repeating: (1_600, 0.1), count: 10)
            pattern += Array(repeating: (1_600, 0), count: 13)
            var events: [TranscriptEvent] = []
            var d = driver()
            try await d.run(chunks(pattern), backend: backend) { events.append($0) }

            let finals = events.filter(\.isFinal)
            #expect(finals.count == 1)
            #expect(finals.first?.text == "hello world")
            // Commit happens when 19,200 silent samples have arrived: 16,000 + 19,200 = 35,200 samples = 2.2 s.
            #expect(finals.first?.range == 0..<2.2)
            #expect(backend.snapshot.commits == 1)
            #expect(events.contains { !$0.isFinal && $0.text == "hello" })
            #expect(events.contains { !$0.isFinal && $0.text == "hello world" })
        }

        @Test func noCommitBeforeTheSilenceIsLongEnough() async throws {
            let backend = ScriptedBackend(wordsAt: [1_600: "hi"])
            var pattern: [(samples: Int, level: Float)] = [(1_600, 0.1)]
            pattern += Array(repeating: (1_600, 0), count: 11)  // 1100 ms
            var events: [TranscriptEvent] = []
            var d = driver()
            // Input ends here, so the flush at the end commits exactly once and no earlier.
            try await d.run(chunks(pattern), backend: backend) { events.append($0) }
            #expect(backend.snapshot.commits == 1)
            #expect(events.filter(\.isFinal).count == 1)
            #expect(events.filter(\.isFinal).first?.range == 0..<1.2)
        }

        @Test func endOfInputFlushesTheOpenSegment() async throws {
            let backend = ScriptedBackend(wordsAt: [3_200: "tail"])
            var events: [TranscriptEvent] = []
            var d = driver()
            try await d.run(chunks([(1_600, 0.1), (1_600, 0.1)]), backend: backend) { events.append($0) }
            #expect(events.filter(\.isFinal).map(\.text) == ["tail"])
        }

        @Test func segmentRangesAreMonotonicAndNeverOverlap() async throws {
            let backend = ScriptedBackend(wordsAt: [1_600: "one", 4_000: "two"])
            var pattern: [(samples: Int, level: Float)] = [(1_600, 0.1)]
            pattern += Array(repeating: (1_600, 0), count: 12)  // commits segment 1
            pattern += [(1_600, 0.1)]
            pattern += Array(repeating: (1_600, 0), count: 12)  // commits segment 2 (word lands at 4,000 of the segment)
            var events: [TranscriptEvent] = []
            var d = driver()
            try await d.run(chunks(pattern), backend: backend) { events.append($0) }
            let ranges = events.filter(\.isFinal).compactMap(\.range)
            #expect(ranges.count == 2)
            guard ranges.count == 2 else { return }
            #expect(ranges[0].upperBound <= ranges[1].lowerBound)
            #expect(ranges.allSatisfy { $0.lowerBound <= $0.upperBound })
        }

        @Test func silenceWithNoTextCommitsNothing() async throws {
            let backend = ScriptedBackend()
            var events: [TranscriptEvent] = []
            var d = driver()
            try await d.run(chunks(Array(repeating: (1_600, 0), count: 40)), backend: backend) { events.append($0) }
            #expect(events.isEmpty)
        }

        @Test func aDetectedForeignLanguagePinsAtTheSegmentBoundary() async throws {
            let backend = ScriptedBackend(wordsAt: [1_600: "bonjour"], detected: "fr-FR")
            var pattern: [(samples: Int, level: Float)] = [(1_600, 0.1)]
            pattern += Array(repeating: (1_600, 0), count: 13)
            var events: [TranscriptEvent] = []
            var d = driver(preferred: [Locale(identifier: "de_DE"), Locale(identifier: "en_US")])
            try await d.run(chunks(pattern), backend: backend) { events.append($0) }
            #expect(backend.snapshot.applied == ["de-DE"])
        }

        @Test func aDetectedPreferredLanguageNeverPins() async throws {
            let backend = ScriptedBackend(wordsAt: [1_600: "hallo"], detected: "de-DE")
            var pattern: [(samples: Int, level: Float)] = [(1_600, 0.1)]
            pattern += Array(repeating: (1_600, 0), count: 13)
            var events: [TranscriptEvent] = []
            var d = driver(preferred: [Locale(identifier: "de_DE"), Locale(identifier: "en_US")])
            try await d.run(chunks(pattern), backend: backend) { events.append($0) }
            #expect(backend.snapshot.applied.isEmpty)
        }

        @Test func aNon16kMonoChunkFailsTyped() async {
            let backend = ScriptedBackend()
            let bad = AsyncStream<AudioChunk> { c in
                c.yield(AudioChunk(samples: [0, 0], format: AudioFormatSpec(sampleRate: 48_000, channelCount: 1)))
                c.finish()
            }
            var d = driver()
            await #expect(throws: FluidAudioEngineError.unsupportedFormat) {
                try await d.run(bad, backend: backend) { _ in }
            }
        }
    }

// MARK: Segment grouping

@Suite("Segment grouping")
struct SegmentGroupingTests {
    @Test func splitsAtSentencePunctuation() {
        let tokens = [
            tok("▁Hello", 0, 0.5), tok("▁world", 0.5, 0.75), tok(".", 0.75, 0.875),
            tok("▁How", 1, 1.125), tok("▁are", 1.125, 1.25), tok("▁you", 1.25, 1.5), tok("?", 1.5, 1.625),
            tok("▁Fine", 1.75, 2), tok("!", 2, 2.125),
        ]
        let events = SegmentGrouper.group(tokens)
        #expect(events.map(\.text) == ["Hello world.", "How are you?", "Fine!"])
        #expect(events.map(\.range) == [0..<0.875, 1..<1.625, 1.75..<2.125])
        #expect(events.allSatisfy { $0.isFinal && $0.stream == .mic })
    }

    @Test func splitsAtAGapOverTheLimitButNotAtOrBelowIt() {
        let apart = [tok("▁one", 0, 0.5), tok("▁two", 1.3125, 1.5)]  // gap 0.8125 s
        #expect(SegmentGrouper.group(apart).map(\.text) == ["one", "two"])
        let near = [tok("▁one", 0, 0.5), tok("▁two", 1.25, 1.5)]  // gap 0.75 s
        #expect(SegmentGrouper.group(near).map(\.text) == ["one two"])
        // The limit itself is not a split: a gap equal to maxGap stays in one segment.
        #expect(SegmentGrouper.group(near, maxGap: 0.75).map(\.text) == ["one two"])
        #expect(SegmentGrouper.group(near, maxGap: 0.5).map(\.text) == ["one", "two"])
    }

    @Test func theDefaultGapIsEightTenthsOfASecond() {
        #expect(SegmentGrouper.maxGap == 0.8)
    }

    @Test func aDecimalPointInsideANumberDoesNotSplit() {
        let tokens = [
            tok("▁It", 0, 0.25), tok("▁costs", 0.25, 0.5), tok("▁3", 0.5, 0.625), tok(".", 0.625, 0.6875),
            tok("5", 0.6875, 0.75), tok("▁euros", 0.75, 1), tok(".", 1, 1.0625),
        ]
        #expect(SegmentGrouper.group(tokens).map(\.text) == ["It costs 3.5 euros."])
    }

    @Test func leadingSpaceTokensWork() {
        let tokens = [tok(" Hello", 0, 0.5), tok(" there", 0.5, 1), tok(".", 1, 1.0625), tok(" Bye", 1.125, 1.5)]
        #expect(SegmentGrouper.group(tokens).map(\.text) == ["Hello there.", "Bye"])
    }

    @Test func trailingTextWithoutPunctuationIsKept() {
        let tokens = [tok("▁no", 0, 0.5), tok("▁stop", 0.5, 1)]
        let events = SegmentGrouper.group(tokens)
        #expect(events.map(\.text) == ["no stop"])
        #expect(events.first?.range == 0..<1)
    }

    @Test func rangesAreMonotonicAndNeverOverlap() {
        // The second sentence starts (0.75) before the first one ended (1.0).
        let tokens = [
            tok("▁One", 0, 0.5), tok(".", 0.5, 1),
            tok("▁Two", 0.75, 1.25), tok(".", 1.25, 1.5),
            tok("▁Three", 1.25, 1.75),
        ]
        let ranges = SegmentGrouper.group(tokens).compactMap(\.range)
        #expect(ranges.count == 3)
        for (a, b) in zip(ranges, ranges.dropFirst()) { #expect(a.upperBound <= b.lowerBound) }
        #expect(ranges.allSatisfy { $0.lowerBound <= $0.upperBound })
    }

    @Test func blankPadAndEmptyTokensAreSkipped() {
        let tokens = [tok("<blank>", 0, 0.25), tok("▁hi", 0.25, 0.5), tok("", 0.5, 0.5), tok("<pad>", 0.5, 0.75), tok(".", 0.5, 0.625)]
        #expect(SegmentGrouper.group(tokens).map(\.text) == ["hi."])
    }

    @Test func emptyInputGivesNoEvents() {
        #expect(SegmentGrouper.group([]).isEmpty)
        #expect(SegmentGrouper.group([tok("▁", 0, 0.5)]).isEmpty)
    }

    @Test func streamIsPassedThrough() {
        #expect(SegmentGrouper.group([tok("▁a", 0, 1)], stream: .system).first?.stream == .system)
    }

    @Test func aSingleTokenSegmentKeepsItsOwnRange() {
        let events = SegmentGrouper.group([tok("▁Yes", 2, 2.5), tok(".", 2.5, 2.625)])
        #expect(events.first?.range == 2..<2.625)
    }
}

@Suite("Batch transcriber contract without models")
struct BatchContractTests {
    @Test func idsNameTheModel() {
        let manager = makeManager(id: "fake", installer: FakeInstaller())
        #expect(ParakeetTranscriber(model: .v3, models: manager).id == "parakeet-v3")
        #expect(ParakeetTranscriber(model: .ultra, models: manager).id == "parakeet-ultra")
    }

    @Test func transcribeThrowsWhenTheModelIsMissing() async {
        let manager = makeManager(id: "fake", installer: FakeInstaller())
        let transcriber = ParakeetTranscriber(model: .v3, models: manager, modelID: "fake")
        await #expect(throws: DictationError.assetsNotInstalled) {
            _ = try await transcriber.transcribe(samples: [0, 0, 0], stream: .mic)
        }
    }

    @Test func emptySamplesGiveNoEventsWithoutNeedingTheModel() async throws {
        let manager = makeManager(id: "fake", installer: FakeInstaller())
        let transcriber = ParakeetTranscriber(model: .v3, models: manager, modelID: "fake")
        let events = try await transcriber.transcribe(samples: [], stream: .mic)
        #expect(events.isEmpty)
    }
}

// MARK: Install progress

@Suite("Install progress mapping")
struct InstallProgressTests {
    @Test func downloadFillsMostOfTheBarThenWarmingThenDone() {
        #expect(InstallProgress.fraction(for: .downloading(0)) == 0)
        #expect(InstallProgress.fraction(for: .downloading(1))! < InstallProgress.fraction(for: .warming)!)
        #expect(InstallProgress.fraction(for: .warming)! < 1)
        #expect(InstallProgress.fraction(for: .installed(bytes: 5)) == 1)
    }

    @Test func downloadingIsMonotonicAndInRange() {
        var last = -1.0
        for step in 0...10 {
            let value = InstallProgress.fraction(for: .downloading(Double(step) / 10))!
            #expect(value >= last && (0...1).contains(value))
            last = value
        }
    }

    @Test func failureAndNotInstalledHaveNoFraction() {
        #expect(InstallProgress.fraction(for: .failed("x")) == nil)
        #expect(InstallProgress.fraction(for: .notInstalled) == nil)
    }
}

// MARK: Engine contract without models

@Suite("Engine contract without models")
struct EngineContractTests {
    @Test func nemotronPrepareThrowsWhenTheModelIsMissing() async {
        let manager = makeManager(id: "fake", installer: FakeInstaller())
        let engine = NemotronEngine(models: manager, modelID: "fake")
        await #expect(throws: DictationError.assetsNotInstalled) { _ = try await engine.prepare(locale: nil) }
    }

    @Test func eouPrepareThrowsWhenTheModelIsMissing() async {
        let manager = makeManager(id: "fake", installer: FakeInstaller())
        let engine = ParakeetEouEngine(models: manager, modelID: "fake")
        await #expect(throws: DictationError.assetsNotInstalled) { _ = try await engine.prepare(locale: nil) }
    }

    @Test func nemotronInstallAssetsDelegatesToTheManagerAndEndsAtOne() async {
        let installer = FakeInstaller()
        let manager = makeManager(id: "fake", installer: installer)
        let engine = NemotronEngine(models: manager, modelID: "fake")
        var values: [Double] = []
        for await value in engine.installAssets(locale: nil) { values.append(value) }
        #expect(values.last == 1)
        #expect(values == values.sorted())
        #expect(values.allSatisfy { (0...1).contains($0) })
        #expect(await manager.state(of: "fake") != .notInstalled)
    }

    @Test func eouInstallAssetsDelegatesToTheManagerAndEndsAtOne() async {
        let manager = makeManager(id: "fake", installer: FakeInstaller())
        let engine = ParakeetEouEngine(models: manager, modelID: "fake")
        var values: [Double] = []
        for await value in engine.installAssets(locale: nil) { values.append(value) }
        #expect(values.last == 1)
    }

    @Test func installAssetsOfAnInstalledModelFinishesAtOne() async {
        let manager = makeManager(id: "fake", installer: FakeInstaller(installed: true))
        let engine = NemotronEngine(models: manager, modelID: "fake")
        var values: [Double] = []
        for await value in engine.installAssets(locale: nil) { values.append(value) }
        #expect(values == [1])
    }

    @Test func installAssetsForAnUnknownModelFinishesWithoutOne() async {
        let manager = makeManager(id: "fake", installer: FakeInstaller())
        let engine = NemotronEngine(models: manager, modelID: "nope")
        var values: [Double] = []
        for await value in engine.installAssets(locale: nil) { values.append(value) }
        #expect(!values.contains(1))
    }

    @Test func engineIDsNameTheModel() {
        let manager = makeManager(id: "fake", installer: FakeInstaller())
        #expect(NemotronEngine(variant: .latin, chunkMs: 560, models: manager).id == "nemotron-latin-560")
        #expect(NemotronEngine(models: manager).id == "nemotron-multilingual-1120")
        #expect(ParakeetEouEngine(chunk: .ms320, models: manager).id == "parakeet-eou-320")
    }

    @Test func prepareDemandsAnInstalledModelNotOneStillWarming() async {
        let manager = makeManager(id: "fake", installer: FakeInstaller())
        let engine = NemotronEngine(models: manager, modelID: "fake")
        // Not installed -> throws before touching CoreML.
        await #expect(throws: DictationError.assetsNotInstalled) { _ = try await engine.prepare(locale: Locale(identifier: "de_DE")) }
    }

    @Test func transcribeWithoutPrepareFailsTyped() async {
        let manager = makeManager(id: "fake", installer: FakeInstaller())
        let engine = NemotronEngine(models: manager, modelID: "fake")
        let (input, feed) = AsyncStream.makeStream(of: AudioChunk.self)
        feed.finish()
        await #expect(throws: FluidAudioEngineError.notPrepared) {
            for try await _ in engine.transcribe(input) {}
        }
    }
}
}
