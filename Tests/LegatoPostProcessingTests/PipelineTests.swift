import Foundation
import LegatoCore
import Synchronization
import Testing
@testable import LegatoPostProcessing

private let en = Locale(identifier: "en-US")
private let de = Locale(identifier: "de-DE")

final class CallLog: Sendable {
    private let items = Mutex<[String]>([])
    func add(_ name: String) { items.withLock { $0.append(name) } }
    var names: [String] { items.withLock { $0 } }
}

final class FlagBox: Sendable {
    private let flag = Mutex(false)
    func set() { flag.withLock { $0 = true } }
    var isSet: Bool { flag.withLock { $0 } }
}

/// Records calls in a shared log, then applies `transform` (which may throw or hang).
private final class SpyStage: TranscriptPostProcessor {
    let id: String
    private let log: CallLog
    private let transform: @Sendable (String) async throws -> String

    init(_ id: String, log: CallLog, transform: @escaping @Sendable (String) async throws -> String) {
        self.id = id
        self.log = log
        self.transform = transform
    }

    func process(_ text: String, locale: Locale) async throws -> String {
        log.add(id)
        return try await transform(text)
    }
}

/// A sleeper that never fires, so a test only times out when it asks to.
private let neverFires: @Sendable (Duration) async throws -> Void = { _ in try await Task.sleep(for: .seconds(3600)) }
/// A sleeper that fires at once: every timeout expires immediately.
private let firesAtOnce: @Sendable (Duration) async throws -> Void = { _ in }

@Suite("PostProcessingPipeline")
struct PipelineTests {
    @Test func stagesRunInOrderEachSeeingThePreviousOutput() async {
        let log = CallLog()
        let pipeline = PostProcessingPipeline(
            stages: [
                SpyStage("a", log: log) { $0 + "A" },
                SpyStage("b", log: log) { $0 + "B" },
                SpyStage("c", log: log) { $0 + "C" },
            ],
            sleeper: neverFires)
        let out = await pipeline.process("x", locale: en)
        #expect(out == "xABC")
        #expect(log.names == ["a", "b", "c"])
    }

    @Test func aThrowingStagePassesItsInputThrough() async {
        let log = CallLog()
        let pipeline = PostProcessingPipeline(
            stages: [
                SpyStage("a", log: log) { $0 + "A" },
                SpyStage("boom", log: log) { _ in throw LLMError.failed("nope") },
                SpyStage("c", log: log) { $0 + "C" },
            ],
            sleeper: neverFires)
        #expect(await pipeline.process("x", locale: en) == "xAC")
        #expect(log.names == ["a", "boom", "c"])
    }

    @Test func aGuardrailErrorPassesItsInputThrough() async {
        let log = CallLog()
        let pipeline = PostProcessingPipeline(
            stages: [SpyStage("g", log: log) { _ in throw LLMError.guardrail }],
            sleeper: neverFires)
        #expect(await pipeline.process("Hallo Welt", locale: de) == "Hallo Welt")
    }

    @Test func aStageOverTheTimeoutPassesItsInputThrough() async {
        let log = CallLog()
        let pipeline = PostProcessingPipeline(
            stages: [
                SpyStage("slow", log: log) { _ in
                    try await Task.sleep(for: .seconds(3600))
                    return "too late"
                },
                SpyStage("after", log: log) { $0 + "!" },
            ],
            timeout: .seconds(4),
            sleeper: { duration in
                // Only the stage timeout is asked for here, and it is the configured 4 s.
                #expect(duration == .seconds(4))
                try await firesAtOnce(duration)
            })
        // The slow stage times out; the next stage still runs on the unchanged input.
        #expect(await pipeline.process("x", locale: en) == "x!")
    }

    @Test func aStageThatIgnoresCancellationStillCannotHoldThePipelineBeyondTheTimeout() async {
        let log = CallLog()
        let finished = FlagBox()
        let pipeline = PostProcessingPipeline(
            stages: [
                // A cold model load: nothing in it checks for cancellation, and it takes 2 s.
                SpyStage("stubborn", log: log) { _ in
                    await Task.detached { try? await Task.sleep(for: .seconds(2)) }.value
                    finished.set()
                    return "too late"
                },
                SpyStage("after", log: log) { $0 + "!" },
            ],
            timeout: .milliseconds(100),
            sleeper: { try await Task.sleep(for: $0) })

        let clock = ContinuousClock()
        let started = clock.now
        let out = await pipeline.process("x", locale: en)
        let elapsed = clock.now - started

        #expect(out == "x!", "the input goes on to the next stage")
        #expect(elapsed < .seconds(1), "returned at the deadline, not when the stage ended: \(elapsed)")
        #expect(!finished.isSet, "the stage was still running when the pipeline returned")
    }

    @Test func aTimedOutStageIsCancelled() async {
        let log = CallLog()
        let sawCancel = FlagBox()
        let pipeline = PostProcessingPipeline(
            stages: [
                SpyStage("slow", log: log) { text in
                    try? await Task.sleep(for: .seconds(3600))
                    if Task.isCancelled { sawCancel.set() }
                    return text + "?"
                },
            ],
            sleeper: firesAtOnce)
        #expect(await pipeline.process("x", locale: en) == "x")
        for _ in 0..<200 where !sawCancel.isSet { try? await Task.sleep(for: .milliseconds(5)) }
        #expect(sawCancel.isSet)
    }

    @Test func aStageThatBeatsTheTimeoutStopsTheTimer() async {
        let log = CallLog()
        let timerCancelled = FlagBox()
        let pipeline = PostProcessingPipeline(
            stages: [SpyStage("fast", log: log) { $0 + "A" }],
            sleeper: { _ in
                do { try await Task.sleep(for: .seconds(3600)) } catch { timerCancelled.set(); throw error }
            })
        #expect(await pipeline.process("x", locale: en) == "xA")
        for _ in 0..<200 where !timerCancelled.isSet { try? await Task.sleep(for: .milliseconds(5)) }
        #expect(timerCancelled.isSet)
    }

    @Test func cancellingTheCallerReturnsTheInputAtOnce() async {
        let log = CallLog()
        let pipeline = PostProcessingPipeline(
            stages: [SpyStage("stubborn", log: log) { _ in
                await Task.detached { try? await Task.sleep(for: .seconds(2)) }.value
                return "too late"
            }],
            sleeper: neverFires)
        let caller = Task { await pipeline.process("x", locale: en) }
        for _ in 0..<200 where log.names.isEmpty { try? await Task.sleep(for: .milliseconds(5)) }
        let clock = ContinuousClock()
        let started = clock.now
        caller.cancel()
        #expect(await caller.value == "x")
        #expect(clock.now - started < .seconds(1))
    }

    @Test func aStageThatReturnsNothingPassesItsInputThrough() async {
        let log = CallLog()
        let pipeline = PostProcessingPipeline(
            stages: [SpyStage("blank", log: log) { _ in "  " }],
            sleeper: neverFires)
        #expect(await pipeline.process("keep me", locale: en) == "keep me")
    }

    @Test(arguments: ["", "   ", "\n\t "])
    func emptyInputShortCircuits(_ input: String) async {
        let log = CallLog()
        let pipeline = PostProcessingPipeline(
            stages: [SpyStage("a", log: log) { $0 + "A" }], sleeper: neverFires)
        #expect(await pipeline.process(input, locale: en) == input)
        #expect(log.names.isEmpty)
    }

    @Test func noStagesReturnsTheInput() async {
        let pipeline = PostProcessingPipeline(stages: [], sleeper: neverFires)
        #expect(await pipeline.process("same", locale: en) == "same")
    }
}

@Suite("ITNStage")
struct ITNStageTests {
    @Test func englishNumbersBecomeDigits() async throws {
        let out = try await ITNStage().process("that costs twenty five euros", locale: en)
        #expect(out.contains("25"))
    }

    @Test func germanPassesThroughUnchanged() async throws {
        let input = "Das kostet fünfundzwanzig Euro"
        #expect(try await ITNStage().process(input, locale: de) == input)
    }

    @Test func englishFlavoursOfEnglishAreNormalizedToo() async throws {
        let out = try await ITNStage().process("twenty five euros", locale: Locale(identifier: "en-GB"))
        #expect(out.contains("25"))
    }
}
