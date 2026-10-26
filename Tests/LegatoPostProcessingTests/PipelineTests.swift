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
