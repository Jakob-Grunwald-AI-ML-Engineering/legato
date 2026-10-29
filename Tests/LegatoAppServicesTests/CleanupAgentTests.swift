import Foundation
import LegatoCore
import LegatoFieldEdit
import LegatoPostProcessing
import Testing
@testable import LegatoAppServices

/// A scripted rolling session: replies come from a list (`[]` once it runs out), usage is characters / 4.
private actor FakeSession: LLMSession {
    enum Script {
        case json(String)
        case slow(Duration, String)
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
        case .slow(let delay, let text):
            try await Task.sleep(for: delay)
            return try LLMStructuredDecoding.decode(Output.self, from: text)
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
private final class Rig: @unchecked Sendable {
    var queue: FieldEditQueue
    var field: String
    let session: FakeSession
    let agent: CleanupAgent
    private var seq: Int?

    init(
        existing: String = "", scripts: [FakeSession.Script] = [], budget: Int = 4_000, timeout: Duration = .seconds(5),
        style: CleanupStyle = .verbatim, emoji: MessageEmojiStyle = .off, itn: Bool = false
    ) async {
        field = existing
        queue = FieldEditQueue(FieldSnapshot(window: existing, caret: existing.utf16.count, windowBase: 0))
        session = FakeSession(budget: budget, scripts: scripts)
        agent = CleanupAgent(
            session: session, options: .init(
                owner: "run", locale: Locale(identifier: "en"), timeout: timeout, style: style, emoji: emoji, itn: itn))
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

    func reset(_ reason: ResetReason = .unaligned) {
        queue.reset(FieldSnapshot(window: field, caret: field.utf16.count, windowBase: 0), reason: reason)
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

    @Test func tentativeTextAtTheEndOfTheRunIsNotOfferedUntilItIsFinal() async throws {
        let rig = await Rig(scripts: [edits((1, "Teh cat sat.")), edits((2, "The dog ran."))])
        rig.write("Teh cat sat. Teh dog ran.")
        await rig.agent.setTentative(length: " Teh dog ran.".utf16.count)
        let first = await rig.feed()
        let request = try #require(await rig.session.requests.first)
        #expect(request.contains("1. Teh cat sat."))
        #expect(!request.contains("dog"))
        #expect(first.allSatisfy { $0.steps.allSatisfy { $0.span.end <= "Teh cat sat.".utf16.count } })

        // Once it is final, the sentence is the model's to review.
        await rig.agent.setTentative(length: 0)
        let second = await rig.agent.replan()
        #expect(await rig.session.requests.last?.contains("2. Teh dog ran.") == true)
        let step = try #require(second.first?.steps.first)
        #expect(step.span.location >= "Teh cat sat. ".utf16.count)
    }

    @Test func aRunOfOnlyTentativeTextAsksNothing() async throws {
        let rig = await Rig(scripts: [edits((1, "The cat sat."))])
        rig.write("Teh cat sat.")
        await rig.agent.setTentative(length: "Teh cat sat.".utf16.count)
        #expect(await rig.feed().isEmpty)
        #expect(await rig.session.requests.isEmpty)
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
        let rig = await Rig(scripts: [.json("not an answer"), edits((1, "The one."))])
        _ = await rig.dictate("Teh one. Two.")
        let session = rig.queue.session  // A resync of the same queue; another queue's window drops the run.
        // The run's text, found once in the new window; the text before it is not the run's.
        let batch = FeedBatch(
            entries: [], version: FieldVersion(5), session: session, resync: true, window: "Fix teh text. Teh one. Two.")
        #expect(await rig.agent.consume(batch).isEmpty)
        let transactions = await rig.agent.finish()

        let transaction = try #require(transactions.first)
        #expect(transaction.base == FieldVersion(5))
        #expect(transaction.session == session)
        #expect(transaction.steps == [EditStep(span: Span(location: 15, length: 2), text: "he", expect: "eh")])
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

    // MARK: Run ownership across a reset or resync

    @Test func aResetKeepsTheTextBeforeTheRunOutOfReach() async throws {
        let rig = await Rig(existing: "Mine teh text. ", scripts: [.json("[]"), edits((1, "Mine the text."))])
        #expect(await rig.dictate("Hello world.").isEmpty)
        rig.reset(.unaligned)
        let transactions = await rig.feed()
        #expect(transactions.isEmpty)
        #expect(await rig.session.requests.count == 1)  // The text before the run was never offered to the model.
    }

    @Test func afterAResetNewRecognizedTextIsStillCleanedAndOnlyThat() async throws {
        let rig = await Rig(existing: "Mine teh text. ", scripts: [.json("[]"), edits((1, "Mine the text."), (2, "Next the one."))])
        _ = await rig.dictate("Hello world.")
        rig.reset(.unaligned)
        _ = await rig.feed()
        let transactions = await rig.dictate(" Next teh one.")
        let request = try #require(await rig.session.requests.last)
        #expect(request.contains("Review: 2."))
        #expect(request.contains("1. Hello world.\n2. Next teh one."))
        let location = try #require(transactions.first?.steps.first?.span.location)
        #expect(location >= "Mine teh text. Hello world.".utf16.count)
        #expect(transactions.count == 1)
    }

    @Test func aResyncThatFindsTheRunTextOnceKeepsEditingOnlyTheRun() async throws {
        let rig = await Rig(existing: "Mine teh text. ", scripts: [.json("[]"), edits((1, "Mine the text."), (2, "Next the one."))])
        _ = await rig.dictate("Hello world. Teh end")
        let batch = FeedBatch(
            entries: [], version: FieldVersion(9), session: UUID(), resync: true, window: "Mine teh text. Hello world. Teh end.")
        let transactions = await rig.agent.consume(batch)
        let request = try #require(await rig.session.requests.last)
        #expect(!request.contains("Mine"))
        // The run's last sentence got its full stop outside the run text we knew: the run is not found, so nothing is the run's.
        #expect(transactions.isEmpty)
    }

    @Test func aRunTextFoundTwiceIsNotTheRunsUntilNewRecognizedTextArrives() async throws {
        let rig = await Rig(existing: "Hello world. ", scripts: [.json("[]"), edits((1, "Hello world!"))])
        _ = await rig.dictate("Hello world.")
        rig.reset(.unaligned)  // "Hello world." now occurs twice: which one is the run's is unknown.
        #expect(await rig.feed().isEmpty)
        #expect(await rig.session.requests.count == 1)
        #expect(await rig.agent.finish().isEmpty)
        #expect(await rig.session.requests.count == 1)
    }

    @Test func aClearedFieldLeavesNoRun() async throws {
        let rig = await Rig(scripts: [.json("[]")])
        _ = await rig.dictate("Hello world.")
        rig.user("")
        _ = await rig.feed()
        #expect(await rig.agent.finish().isEmpty)
    }

    // MARK: finish, rejected edits, offsets

    @Test func finishDuringARollingPassWaitsAndThenRunsTheFinalPass() async throws {
        let rig = await Rig(scripts: [.slow(.milliseconds(300), "[]"), edits((2, "Bye bye."))])
        rig.write("Hello world. Bye bye")
        async let rolling = rig.feed()
        try await Task.sleep(for: .milliseconds(100))
        let final = await rig.agent.finish()
        #expect(await rolling.isEmpty)
        let step = try #require(final.first?.steps.first)
        #expect(step == EditStep(span: .at("Hello world. Bye bye".utf16.count), text: ".", expect: ""))
    }

    @Test func anEditForASentenceTheModelWasNotToReviewIsRejected() async throws {
        let rig = await Rig(scripts: [edits((2, "Bye bye."))])
        let transactions = await rig.dictate("Hello world. Bye bye")  // Sentence 2 is unfinished: context only.
        #expect(transactions.isEmpty)
        #expect(rig.field == "Hello world. Bye bye")
    }

    @Test func severalLengthChangingEditsInOnePassAllLand() async throws {
        let rig = await Rig(scripts: [edits((1, "We saw it."), (2, "There was a cat."), (3, "Fine."))])
        let transactions = await rig.dictate("Wee saw it. Ther wass a catt. Finee.")
        #expect(transactions.count == 3)
        rig.submit(transactions)
        rig.drain()
        #expect(rig.field == "We saw it. There was a cat. Fine.")
    }

    @Test func anEmojiBeforeAnEditDoesNotShiftIt() async throws {
        let rig = await Rig(existing: "\u{1F600} ", scripts: [edits((1, "I saw the dog."))])
        let transactions = await rig.dictate("I saw teh \u{1F44D}dog. Done.")
        _ = transactions
        let rig2 = await Rig(existing: "\u{1F600} ", scripts: [edits((1, "I saw the \u{1F44D}dog."))])
        let second = await rig2.dictate("I saw teh \u{1F44D}dog. Done.")
        rig2.submit(second)
        rig2.drain()
        #expect(rig2.field == "\u{1F600} I saw the \u{1F44D}dog. Done.")
    }

    // MARK: Re-planning, frozen options, session notes

    @Test func supersededAndWithdrawnEditsAreReplannedWithoutLimit() async throws {
        let rig = await Rig(scripts: Array(repeating: edits((1, "I saw the dog.")), count: 5))
        var transactions = await rig.dictate("I saw teh dog. It ran away.")
        for _ in 0..<4 {
            let id = try #require(transactions.first?.id)
            if transactions.count == 1 { await rig.agent.superseded(id, by: UUID()) }
            transactions = await rig.agent.replan()
            #expect(transactions.count == 1)
        }
        #expect(await rig.session.requests.count == 5)
    }

    @Test func conflictsStillGiveUpAfterTwoTries() async throws {
        let rig = await Rig(scripts: Array(repeating: edits((1, "I saw the dog.")), count: 5))
        var transactions = await rig.dictate("I saw teh dog. It ran away.")
        await rig.agent.conflicted(Conflict(.expectMismatch), for: try #require(transactions.first?.id))
        transactions = await rig.agent.replan()
        #expect(transactions.count == 1)
        await rig.agent.conflicted(Conflict(.expectMismatch), for: try #require(transactions.first?.id))
        #expect(await rig.agent.replan().isEmpty)
    }

    /// An edit the queue could not map from its base (`outOfWindow`: the field moved on under a long pass) is no
    /// user conflict: it is planned again however often it happens, never given up.
    @Test func outOfWindowHandBacksAreReplannedWithoutGivingUp() async throws {
        let rig = await Rig(scripts: Array(repeating: edits((1, "I saw the dog.")), count: 5))
        var transactions = await rig.dictate("I saw teh dog. It ran away.")
        for _ in 0..<3 {
            await rig.agent.conflicted(Conflict(.outOfWindow), for: try #require(transactions.first?.id))
            transactions = await rig.agent.replan()
            #expect(transactions.count == 1)
        }
    }

    @Test func theRunsStyleEmojiAndNumberSettingsReachTheRequest() async throws {
        let rig = await Rig(scripts: [.json("[]")], style: .markdown, emoji: .subtle, itn: true)
        _ = await rig.dictate("I saw teh dog. It ran away.")
        let request = try #require(await rig.session.requests.first)
        #expect(request.contains("Markdown"))
        let messageRig = await Rig(scripts: [.json("[]")], style: .message, emoji: .subtle)
        _ = await messageRig.dictate("I saw teh dog. It ran away.")
        #expect(try #require(await messageRig.session.requests.first).contains("apt emoji"))
        let verbatimRig = await Rig(scripts: [.json("[]")], itn: true)
        _ = await verbatimRig.dictate("I saw teh dog. It ran away.")
        #expect(try #require(await verbatimRig.session.requests.first).contains("as digits"))
    }

    @Test func aRunStartsWithABoundaryMarkerInTheSession() async throws {
        let rig = await Rig()
        #expect(await rig.session.appended.joined().contains("[new dictation run]"))
    }

    @Test func aTurnThatTimedOutIsMarkedDiscardedInTheSession() async throws {
        let rig = await Rig(scripts: [.hang], timeout: .milliseconds(100))
        _ = await rig.dictate("I saw teh dog. It ran away.")
        #expect(await rig.session.appended.joined().contains("[discarded]"))
    }

    @Test func aNewRecognizedSpanAfterAReanchorDoesNotSwallowTheTextBetween() async throws {
        let rig = await Rig(existing: "Mine teh text. ", scripts: [.json("[]"), edits((2, "Next the one."))])
        _ = await rig.dictate("Hello world.")
        rig.field = "Hello world. Mine teh text."  // The host reordered the field; the queue lost alignment.
        rig.reset(.unaligned)
        _ = await rig.feed()
        let transactions = await rig.dictate(" Next teh one.")
        let request = try #require(await rig.session.requests.last)
        #expect(!request.contains("Mine"))
        #expect(request.contains("Review: 2."))
        let step = try #require(transactions.first?.steps.first)
        #expect(step.span.location > "Hello world. Mine teh text.".utf16.count)
    }

    @Test func aResyncFromAnotherQueueDropsTheRun() async throws {
        let rig = await Rig(scripts: [.json("not an answer"), edits((1, "Okay."))])
        _ = await rig.dictate("OK.")
        let batch = FeedBatch(entries: [], version: FieldVersion(3), session: UUID(), resync: true, window: "Dear Bob, OK. Thanks.")
        #expect(await rig.agent.consume(batch).isEmpty)
        #expect(await rig.agent.finish().isEmpty)
        #expect(await rig.session.requests.count == 1)
    }

    @Test func aUserDeletionJustBeforeTheRunDoesNotLockItsFirstSentence() async throws {
        let rig = await Rig(existing: "Mine teh text. ", scripts: [.json("not an answer"), edits((1, "The one."))])
        _ = await rig.dictate("Teh one.")
        rig.user("Mine teh text.Teh one.")  // The user deleted the space right before the run.
        _ = await rig.feed()
        rig.reset(.unaligned)
        _ = await rig.feed()
        let final = await rig.agent.finish()
        #expect(final.count == 1)
    }

    /// A rolling pass whose answer leaves a sentence out ("needs no change") does not settle it for good: a small
    /// model may skip one it should have fixed, so the final pass reviews it again. Answered sentences are done.
    @Test func aSentenceTheModelLeftOutIsReviewedAgainByTheFinalPass() async throws {
        let rig = await Rig(scripts: [edits((2, "It ran away.")), edits((1, "I saw the dog."))])
        let rolling = await rig.dictate("I saw teh dog. It rann away.")
        #expect(rolling.count == 1)
        rig.submit(rolling)
        rig.drain()
        _ = await rig.feed()
        #expect(await rig.session.requests.count == 1)  // not asked again while listening
        let final = await rig.agent.finish()
        let request = try #require(await rig.session.requests.last)
        #expect(await rig.session.requests.count == 2)
        #expect(request.contains("Review: 1."))  // the left-out sentence, not the answered one
        rig.submit(final)
        rig.drain()
        #expect(rig.field == "I saw the dog. It ran away.")
    }
}
