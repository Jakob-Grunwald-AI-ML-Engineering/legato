import Foundation
import Synchronization
import Testing
import LegatoCore
@testable import LegatoMeetings

/// A backend with a hard size limit that records every call. `reply` decides each answer.
private final class LimitedBackend: LLMBackend {
    struct Call: Sendable { var instructions: String; var prompt: String; var size: Int { instructions.count + prompt.count } }

    let id = "fake"
    let maxPromptCharacters: Int?
    /// Hard limit the backend enforces by throwing `.contextTooLong`, whatever it advertises.
    let hardLimit: Int?
    private let calls = Mutex<[Call]>([])
    private let replyFor: @Sendable (Call, Int) throws -> String

    init(limit: Int?, hardLimit: Int? = nil, reply: @escaping @Sendable (Call, Int) throws -> String) {
        maxPromptCharacters = limit
        self.hardLimit = hardLimit ?? limit
        replyFor = reply
    }

    var all: [Call] { calls.withLock { $0 } }
    var availability: LLMAvailability { get async { .available } }

    func respond(instructions: String, prompt: String) async throws -> String {
        let call = Call(instructions: instructions, prompt: prompt)
        let index = calls.withLock { $0.append(call); return $0.count }
        if let hardLimit, call.size > hardLimit { throw LLMError.contextTooLong }
        return try replyFor(call, index)
    }
}

private func isChunk(_ call: LimitedBackend.Call) -> Bool { call.prompt.contains("Me [") || call.prompt.contains("Them [") }

private func seg(_ stream: TranscriptEvent.Stream, _ text: String, _ start: TimeInterval, echo: Bool = false) -> MeetingSegment {
    MeetingSegment(stream: stream, text: text, start: start, end: start + 1, echo: echo)
}

/// `count` alternating segments of `length` characters each, ten seconds apart.
private func transcript(count: Int, length: Int = 80) -> [MeetingSegment] {
    (0..<count).map { i in
        let body = "s\(i) " + String(repeating: "x", count: max(0, length - "s\(i) ".count))
        return seg(i.isMultiple(of: 2) ? .mic : .system, body, TimeInterval(i * 10))
    }
}

@Suite struct MeetingSummarizerTests {
    @Test func oneCallWithLabelledTimestampedLinesAndNoEchoes() async throws {
        let backend = LimitedBackend(limit: 100_000) { _, _ in "SUMMARY" }
        let result = try await MeetingSummarizer(backend: backend).summarize(segments: [
            seg(.mic, "Hello there", 5),
            seg(.mic, "echoed words", 7, echo: true),
            seg(.system, "Hi, ready?", 70),
            seg(.mic, "Late one", 3_725),
        ])
        #expect(result == "SUMMARY")
        let call = try #require(backend.all.first)
        #expect(backend.all.count == 1)
        #expect(call.prompt == "Me [00:05]: Hello there\nThem [01:10]: Hi, ready?\nMe [62:05]: Late one")
        #expect(call.instructions == MeetingSummarizer.defaultPrompt)
    }

    @Test func defaultPromptAsksForTheThreeSectionsInTheTranscriptsLanguage() {
        let p = MeetingSummarizer.defaultPrompt
        #expect(p.contains("## Summary") && p.contains("## Decisions") && p.contains("## Action items"))
        #expect(p.contains("Me") && p.contains("Them"))
        #expect(p.localizedCaseInsensitiveContains("same language"))
    }

    @Test func aCustomPromptReplacesTheDefaultAndBlankFallsBack() async throws {
        let backend = LimitedBackend(limit: nil) { _, _ in "ok" }
        _ = try await MeetingSummarizer(backend: backend, prompt: "Write haiku.").summarize(segments: transcript(count: 2))
        _ = try await MeetingSummarizer(backend: backend, prompt: "  \n").summarize(segments: transcript(count: 2))
        #expect(backend.all[0].instructions == "Write haiku.")
        #expect(backend.all[1].instructions == MeetingSummarizer.defaultPrompt)
    }

    @Test func nothingSpokenIsAnEmptyResponse() async {
        let backend = LimitedBackend(limit: nil) { _, _ in "never" }
        await #expect(throws: LLMError.emptyResponse) {
            try await MeetingSummarizer(backend: backend).summarize(segments: [seg(.mic, "echo", 1, echo: true)])
        }
        #expect(backend.all.isEmpty)
    }

    @Test func everyPromptStaysUnderTheLimitEvenWithALongCustomPrompt() async throws {
        let custom = String(repeating: "Be thorough about money. ", count: 12)  // 300 characters
        let backend = LimitedBackend(limit: 1_000) { call, i in isChunk(call) ? "chunk \(i) " + String(repeating: "y", count: 150) : "merged \(i) " + String(repeating: "z", count: 150) }
        _ = try await MeetingSummarizer(backend: backend, prompt: custom).summarize(segments: transcript(count: 60))
        #expect(backend.all.count > 5)
        for call in backend.all { #expect(call.size <= 1_000, "a \(call.size)-character request") }
        #expect(backend.all.contains { $0.instructions.contains(custom) && !isChunk($0) }, "the merge step keeps the custom prompt")
    }

    @Test func chunksSplitOnSegmentBoundariesAndCoverEverySegment() async throws {
        let segments = transcript(count: 40)
        let backend = LimitedBackend(limit: 3_000) { call, i in isChunk(call) ? "c\(i)" : "m\(i)" }
        _ = try await MeetingSummarizer(backend: backend).summarize(segments: segments)
        let chunks = backend.all.filter(isChunk)
        #expect(chunks.count > 1)
        let lines = chunks.flatMap { $0.prompt.split(separator: "\n").map(String.init) }
        #expect(lines.count == 40)
        for (i, line) in lines.enumerated() {
            #expect(line.hasSuffix(segments[i].text), "line \(i) is a whole segment, in order")
        }
    }

    @Test func theMergeStepRecursesUntilItFits() async throws {
        let backend = LimitedBackend(limit: 3_000) { call, i in
            isChunk(call) ? "chunk-summary-\(i) " + String(repeating: "a", count: 120) : "merged-\(i) " + String(repeating: "b", count: 120)
        }
        let result = try await MeetingSummarizer(backend: backend).summarize(segments: transcript(count: 600))
        let chunkCount = backend.all.filter(isChunk).count
        let merges = backend.all.filter { !isChunk($0) }
        #expect(chunkCount > 20)
        #expect(merges.count > 2, "more than one merge call")
        #expect(merges.contains { $0.prompt.contains("merged-") }, "a merge consumed the output of an earlier merge")
        #expect(!merges.isEmpty && result.hasPrefix("merged-"))
        for call in backend.all { #expect(call.size <= 3_000) }
    }

    @Test func contextTooLongHalvesTheChunkAndRetries() async throws {
        // The backend claims 100 000 characters but takes only 700.
        let segments = transcript(count: 20, length: 100)
        let backend = LimitedBackend(limit: 100_000, hardLimit: 700) { call, i in isChunk(call) ? "c\(i)" : "m\(i)" }
        let result = try await MeetingSummarizer(backend: backend).summarize(segments: segments)
        #expect(!result.isEmpty)
        let accepted = backend.all.filter { $0.size <= 700 && isChunk($0) }
        #expect(backend.all.contains { $0.size > 700 }, "the first, whole attempt was refused")
        let lines = accepted.flatMap { $0.prompt.split(separator: "\n").map(String.init) }
        #expect(lines.count == 20, "every segment was summarised exactly once after halving")
    }

    @Test func guardrailSkipsTheChunkAndSaysSo() async throws {
        let segments = transcript(count: 30)
        let backend = LimitedBackend(limit: 3_000) { call, i in
            if call.prompt.contains("s3 ") { throw LLMError.guardrail }
            return isChunk(call) ? "c\(i)" : "m\(i)"
        }
        let result = try await MeetingSummarizer(backend: backend).summarize(segments: segments)
        // The note says what was left out and why, once, for the one chunk the model declined.
        #expect(result.contains("> Note: 1 part of the transcript was skipped because the model declined to summarize it."))
        #expect(!backend.all.filter { !isChunk($0) }.contains { $0.prompt.contains("s3 ") })
    }

    @Test func aGuardrailOnEveryChunkIsAGuardrail() async {
        let backend = LimitedBackend(limit: 3_000) { _, _ in throw LLMError.guardrail }
        await #expect(throws: LLMError.guardrail) {
            try await MeetingSummarizer(backend: backend).summarize(segments: transcript(count: 30))
        }
    }

    @Test func aPromptTooBigForTheBackendFailsInsteadOfLooping() async {
        let backend = LimitedBackend(limit: 100) { _, _ in "x" }
        await #expect(throws: LLMError.self) {
            try await MeetingSummarizer(backend: backend).summarize(segments: transcript(count: 4))
        }
    }

    @Test func anOverlongSingleSegmentIsSplit() async throws {
        let backend = LimitedBackend(limit: 3_000) { call, i in isChunk(call) ? "c\(i)" : "m\(i)" }
        let long = (0..<400).map { "word\($0)" }.joined(separator: " ")
        _ = try await MeetingSummarizer(backend: backend).summarize(segments: [seg(.mic, long, 0)])
        #expect(backend.all.count > 1)
        for call in backend.all { #expect(call.size <= 3_000) }
    }
}

@Suite struct MeetingSummaryStoreTests {
    @Test func summariesAreListedNewestFirstPerBackend() async throws {
        let store = MeetingStore(root: tempRoot())
        let id = UUID()
        try await store.create(Meeting(id: id, title: "T", date: Date(), engineID: "e", state: .processing))
        try await store.saveSummary("older", backendID: "foundation-models", for: id)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -100)],
            ofItemAtPath: await store.summaryURL(for: id, backendID: "foundation-models").path)
        try await store.saveSummary("newer", backendID: "mlx/qwen 3", for: id)
        let list = try await store.summaries(for: id)
        #expect(list.map(\.text) == ["newer", "older"])
        #expect(list.map(\.backendID) == ["mlx-qwen-3", "foundation-models"])

        try await store.saveSummary("redone", backendID: "foundation-models", for: id)
        #expect(try await store.summaries(for: id).first?.text == "redone", "rewriting a backend's summary makes it the newest")
        #expect(try await store.summaries(for: id).count == 2)
    }

    @Test func aMeetingWithoutSummariesHasNone() async throws {
        let store = MeetingStore(root: tempRoot())
        #expect(try await store.summaries(for: UUID()).isEmpty)
    }

    @Test func meetingsSavedBeforeProgressWasRecordedDecodeWithNoStepsDone() async throws {
        let store = MeetingStore(root: tempRoot())
        let id = UUID()
        try await store.create(Meeting(id: id, title: "T", date: Date(), engineID: "e", state: .processing, completedSteps: [.postPass]))
        let url = await store.folder(for: id).appendingPathComponent("meeting.json")
        var json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        #expect(json["completedSteps"] != nil)
        json["completedSteps"] = nil
        try JSONSerialization.data(withJSONObject: json).write(to: url)
        #expect(try await store.meeting(id: id)?.completedSteps == [])
    }
}
