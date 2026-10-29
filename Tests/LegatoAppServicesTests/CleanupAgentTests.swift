import Foundation
import LegatoCore
import LegatoFieldEdit
import Testing
@testable import LegatoAppServices

/// A scripted rolling session: replies come from a list (`[]` once it runs out), usage is characters / 4.
private actor FakeSession: LLMSession {
    enum Script {
        case json(String)
        case hang
    }

    nonisolated let tokenBudget: Int
    private var scripts: [Script]
    private var historyChars = 0
    private(set) var requests: [String] = []
    private(set) var appended: [String] = []
    private(set) var trims: [Int] = []
    private(set) var usageAtRespond: [Int] = []

    init(budget: Int, scripts: [Script]) {
        tokenBudget = budget
        self.scripts = scripts
    }

    func usage() async throws -> LLMTokenUsage { LLMTokenUsage(head: 0, history: (historyChars + 3) / 4) }

    func append(_ chunk: LLMSessionChunk) async throws {
        if case .text(let text) = chunk {
            appended.append(text)
            historyChars += text.count
        }
    }

    func respond(to request: String) async throws -> String { "" }

    func respondStructured<Output: LLMStructuredOutput>(_ type: Output.Type, to request: String) async throws -> Output {
        requests.append(request)
        historyChars += request.count
        usageAtRespond.append((historyChars + 3) / 4)
        let script = scripts.isEmpty ? Script.json("[]") : scripts.removeFirst()
        switch script {
        case .json(let text): return try LLMStructuredDecoding.decode(Output.self, from: text)
        case .hang:
            try await Task.sleep(for: .seconds(60))
            return try LLMStructuredDecoding.decode(Output.self, from: "[]")
        }
    }

    func trim(keepingSuffix tokens: Int) async throws {
        trims.append(tokens)
        historyChars = min(historyChars, tokens * 4)
    }

    func warm() async throws {}
    func close() async {}
}

private func edits(_ pairs: (Int, String)...) -> FakeSession.Script {
    let items = pairs.map { #"{"sentence":\#($0.0),"text":"\#($0.1)"}"# }
    return .json("[" + items.joined(separator: ",") + "]")
}

/// An in-memory Mac-style field edit queue driven the way the integration does: feed batches to the agent,
/// submit what it returns, run the writes.
private final class Rig {
    var queue: FieldEditQueue
    var field: String
    let session: FakeSession
    let agent: CleanupAgent
    private var seq: Int?

    init(existing: String = "", scripts: [FakeSession.Script] = [], budget: Int = 4_000, timeout: Duration = .seconds(5)) async {
        field = existing
        queue = FieldEditQueue(FieldSnapshot(window: existing, caret: existing.utf16.count, windowBase: 0))
        session = FakeSession(budget: budget, scripts: scripts)
        agent = CleanupAgent(
            session: session, options: .init(owner: "run", locale: Locale(identifier: "en"), timeout: timeout))
        _ = await feed()  // The first batch is a resync of the empty run.
    }

    func feed() async -> [EditTransaction] {
        let batch = queue.feed.since(seq)
        seq = batch.lastSeq
        return await agent.consume(batch)
    }

    func submit(_ transactions: [EditTransaction]) { for transaction in transactions { queue.submit(transaction) } }

    func drain() {
        while let write = queue.next() {
            for step in write.steps { field = step.apply(to: field)! }
            queue.settle(FieldSnapshot(window: field, caret: write.caret, windowBase: 0))
        }
    }

    /// ASR text lands at the end of the field.
    func write(_ text: String) {
        queue.submit(EditTransaction(
            origin: .asr, owner: "run", base: queue.document.version, steps: [.insert(text, at: field.utf16.count)]))
        drain()
    }

    func dictate(_ text: String) async -> [EditTransaction] {
        write(text)
        return await feed()
    }

    func user(_ text: String) {
        field = text
        queue.observe(FieldSnapshot(window: text, caret: text.utf16.count, windowBase: 0))
    }
}

@Suite(.timeLimit(.minutes(1)))
struct CleanupAgentTests {
    @Test func aTypoBecomesTheSmallestPatch() async throws {
        let rig = await Rig(scripts: [edits((1, "I saw the dog."))])
        let transactions = await rig.dictate("I saw teh dog. It ran away.")

        let transaction = try #require(transactions.first)
        #expect(transactions.count == 1)
        #expect(transaction.origin == .agent)
        #expect(transaction.owner == "run")
        #expect(transaction.session == rig.queue.session)
        #expect(transaction.base == rig.queue.feed.version)
        // P01-style: two characters out, two in, not a rewrite of the sentence or its suffix.
        #expect(transaction.steps == [EditStep(span: Span(location: 7, length: 2), text: "he", expect: "eh")])

        rig.submit(transactions)
        rig.drain()
        #expect(rig.field == "I saw the dog. It ran away.")
        #expect(await rig.feed().isEmpty)
        #expect(await rig.session.requests.count == 1)  // Checked sentences, and the agent's own result, are not asked again.
        #expect(await rig.session.trims.isEmpty)
    }

    @Test func theModelSeesNumberedSentencesAndTheTextTheRunDidNotWriteStaysOut() async throws {
        let rig = await Rig(existing: "Old teh text. ", scripts: [edits((1, "New the one."))])
        let transactions = await rig.dictate("New teh one. Next.")
        let request = try #require(await rig.session.requests.first)
        #expect(request.contains("1. New teh one.\n2. Next."))
        #expect(!request.contains("Old"))
        let step = try #require(transactions.first?.steps.first)
        #expect(step.span.location >= "Old teh text. ".utf16.count)
        rig.submit(transactions)
        rig.drain()
        #expect(rig.field == "Old teh text. New the one. Next.")
    }

    @Test func aUserEditIsFinalAndTheAgentReplansWithoutTouchingIt() async throws {
        let rig = await Rig(scripts: [
            edits((1, "The cat sat."), (2, "The dog ran.")),
            edits((1, "The cat sat."), (4, "The sun set.")),
        ])
        let first = await rig.dictate("Teh cat sat. Teh dog ran. The end.")
        #expect(first.count == 2)  // One transaction per sentence: one conflict never blocks the others.
        rig.submit(first)
        rig.user("Tea cat sat. Teh dog ran. The end.")  // The user types inside the first edit's range.
        rig.drain()
        #expect(rig.field == "Tea cat sat. The dog ran. The end.")

        rig.write(" Teh sun set. Fine.")
        let second = await rig.feed()

        let request = try #require(await rig.session.requests.last)
        #expect(request.contains("Locked: 1."))
        #expect(request.contains("Review: 4, 5."))
        #expect(await rig.session.appended.joined().contains("user changed"))
        // The model asked for sentence 1 again; the locked sentence is not touched, sentence 4 is.
        let step = try #require(second.first?.steps.first)
        #expect(second.count == 1)
        let sunStart = (rig.field as NSString).range(of: "Teh sun").location
        #expect(step.span.location >= sunStart)
        rig.submit(second)
        rig.drain()
        #expect(rig.field == "Tea cat sat. The dog ran. The end. The sun set. Fine.")
    }

    @Test(arguments: [
        FakeSession.Script.json("I think the first sentence is fine."),
        .json(#"[{"sentence":9,"text":"x"}]"#),
        .json(#"[{"sentence":1,"text":"A."},{"sentence":1,"text":"B."}]"#),
    ])
    private func invalidOutputMakesNoEdit(script: FakeSession.Script) async throws {
        let rig = await Rig(scripts: [script])
        let transactions = await rig.dictate("I saw teh dog. It ran away.")
        #expect(transactions.isEmpty)
        #expect(rig.field == "I saw teh dog. It ran away.")
        #expect(await rig.feed().isEmpty)
        #expect(await rig.session.requests.count == 1)  // A failed pass is not retried in a loop.
    }

    @Test func aTimeoutKeepsTheRawTextAndTheFinalPassTriesOnce() async throws {
        let rig = await Rig(scripts: [.hang, edits((1, "I saw the dog."))], timeout: .milliseconds(100))
        let clock = ContinuousClock()
        let start = clock.now
        let transactions = await rig.dictate("I saw teh dog. It ran away.")
        #expect(transactions.isEmpty)
        #expect(start.duration(to: clock.now) < .seconds(10))
        #expect(await rig.feed().isEmpty)
        #expect(await rig.session.requests.count == 1)

        let final = await rig.agent.finish()
        #expect(final.count == 1)
        #expect(await rig.session.requests.count == 2)
    }

    @Test func aTimeoutAtStopKeepsTheRawText() async throws {
        let rig = await Rig(scripts: [.hang, .hang], timeout: .milliseconds(100))
        _ = await rig.dictate("I saw teh dog. It ran away")
        #expect(await rig.agent.finish().isEmpty)
        #expect(rig.field == "I saw teh dog. It ran away")
    }

    @Test func contextIsTrimmedWithinTheBudgetKeepingTheSuffix() async throws {
        let rig = await Rig(scripts: [edits((1, "I saw the dog."))], budget: 600)
        for _ in 0..<10 { await rig.agent.hear(String(repeating: "word ", count: 80)) }  // ~1000 tokens streamed in.
        let transactions = await rig.dictate("I saw teh dog. It ran away.")

        #expect(transactions.count == 1)
        let trims = await rig.session.trims
        #expect(trims.count == 1)
        #expect(try #require(trims.first) < 600)
        let usage = try #require(await rig.session.usageAtRespond.first)
        #expect(usage <= 600)
    }

    @Test func aResyncBatchRestartsFromItsWindowAndVersion() async throws {
        let rig = await Rig(scripts: [.json("[]"), edits((1, "Fix the text."))])
        _ = await rig.dictate("Teh one. Two.")
        let session = UUID()
        let batch = FeedBatch(
            entries: [], version: FieldVersion(5), session: session, resync: true, window: "Fix teh text. More.")
        let transactions = await rig.agent.consume(batch)

        let transaction = try #require(transactions.first)
        #expect(transaction.base == FieldVersion(5))
        #expect(transaction.session == session)
        #expect(transaction.steps == [EditStep(span: Span(location: 5, length: 2), text: "he", expect: "eh")])
    }

    @Test func aSupersededEditIsPlannedAgainFromTheFeed() async throws {
        let rig = await Rig(scripts: [edits((1, "I saw the dog.")), edits((1, "I saw the dog."))])
        let first = await rig.dictate("I saw teh dog. It ran away.")
        let id = try #require(first.first?.id)
        #expect(await rig.agent.replan().isEmpty)  // Nothing changed: nothing to ask.

        await rig.agent.superseded(id, by: UUID())
        let second = await rig.agent.replan()
        #expect(second.count == 1)
        #expect(second.first?.id != id)
        #expect(await rig.session.requests.count == 2)
    }

    @Test func aHandedBackEditWithoutAUserIsPlannedAgainOnce() async throws {
        let rig = await Rig(scripts: [edits((1, "I saw the dog.")), edits((1, "I saw the dog."))])
        let first = await rig.dictate("I saw teh dog. It ran away.")
        await rig.agent.conflicted(Conflict(.expectMismatch), for: try #require(first.first?.id))
        #expect(await rig.agent.replan().count == 1)
        #expect(await rig.session.appended.joined().contains("user changed") == false)
    }

    @Test func aUnfinishedLastSentenceWaitsForTheFinalPass() async throws {
        let rig = await Rig(scripts: [edits((1, "Hello world.")), edits((2, "Bye bye."))])
        let transactions = await rig.dictate("Hello wrold. Bye bye")
        #expect(transactions.count == 1)
        let request = try #require(await rig.session.requests.first)
        #expect(request.contains("Review: 1."))

        let final = await rig.agent.finish()
        let step = try #require(final.first?.steps.first)
        #expect(step == EditStep(span: .at("Hello wrold. Bye bye".utf16.count), text: ".", expect: ""))
    }
}
