import Foundation
import LegatoCore
import LegatoFieldEdit
import LegatoPostProcessing
import Synchronization
import Testing
@testable import LegatoAppServices

/// A scripted rolling session: each turn's reply comes from a list (the request echoed once it runs out: "no
/// change"), usage is the head plus characters / 4 of the turns.
private actor FakeSession: LLMSession {
    enum Script: Sendable {
        case reply(String)
        case slow(Duration, String)
        case hang
        case fail
    }

    nonisolated let tokenBudget: Int
    private let head: Int
    private var scripts: [Script]
    private var historyChars = 0
    private(set) var requests: [String] = []
    private(set) var appended: [LLMSessionChunk] = []
    private(set) var trims: [Int] = []
    /// Tokens the session held when each turn was sent, the request included.
    private(set) var usageAtRespond: [Int] = []

    init(budget: Int, head: Int = 0, scripts: [Script]) {
        tokenBudget = budget
        self.head = head
        self.scripts = scripts
    }

    func usage() async throws -> LLMTokenUsage { LLMTokenUsage(head: head, history: (historyChars + 3) / 4) }

    func append(_ chunk: LLMSessionChunk) async throws { appended.append(chunk) }

    func respond(to request: String) async throws -> String {
        requests.append(request)
        historyChars += request.count
        usageAtRespond.append(head + (historyChars + 3) / 4)
        let script = scripts.isEmpty ? Script.reply(request) : scripts.removeFirst()
        let reply: String
        switch script {
        case .reply(let text): reply = text
        case .slow(let delay, let text):
            try await Task.sleep(for: delay)
            reply = text
        case .hang:
            try await Task.sleep(for: .seconds(60))
            reply = request
        case .fail: throw LLMSessionError.closed
        }
        historyChars += reply.count
        return reply
    }

    func respondStructured<Output: LLMStructuredOutput>(_ type: Output.Type, to request: String) async throws -> Output {
        throw LLMSessionError.invalidStructuredOutput("the agent asks for plain text")
    }

    func trim(keepingSuffix tokens: Int) async throws {
        trims.append(tokens)
        historyChars = min(historyChars, tokens * 4)
    }

    func warm() async throws {}
    func close() async {}
}

/// A clock the test moves by hand.
private final class ManualClock: Sendable {
    private let instant = Mutex(ContinuousClock.now)
    func now() -> ContinuousClock.Instant { instant.withLock { $0 } }
    func advance(_ duration: Duration) { instant.withLock { $0 = $0.advanced(by: duration) } }
}

/// Counts the agent's pause wakes.
private final class WakeCounter: Sendable {
    private let count = Mutex(0)
    func add() { count.withLock { $0 += 1 } }
    var value: Int { count.withLock { $0 } }
}

/// An in-memory Mac-style field edit queue driven the way the integration does: feed batches to the agent,
/// submit what it returns, run the writes.
private final class Rig: @unchecked Sendable {
    var queue: FieldEditQueue
    var field: String
    let session: FakeSession
    let agent: CleanupAgent
    let clock = ManualClock()
    let wakes = WakeCounter()
    private var seq: Int?

    init(
        existing: String = "", scripts: [FakeSession.Script] = [], budget: Int = 4_000, head: Int = 0,
        timeout: Duration = .seconds(5), style: CleanupStyle = .verbatim, mode: CleanupAgent.Mode = .live,
        endpoint: SentenceEndpointer.Config = .init()
    ) async {
        field = existing
        queue = FieldEditQueue(FieldSnapshot(window: existing, caret: existing.utf16.count, windowBase: 0))
        session = FakeSession(budget: budget, head: head, scripts: scripts)
        let clock = clock, wakes = wakes
        agent = CleanupAgent(
            session: session,
            options: .init(owner: "run", locale: Locale(identifier: "en"), timeout: timeout, style: style, mode: mode, endpoint: endpoint),
            now: { clock.now() }, wake: { wakes.add() })
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

    func land(_ transactions: [EditTransaction]) {
        submit(transactions)
        drain()
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
    // MARK: Turns and patches

    @Test func aFinishedSentenceIsOneTurnAndItsTypoTheSmallestPatch() async throws {
        let rig = await Rig(scripts: [.reply("I saw the dog.")])
        let transactions = await rig.dictate("I saw teh dog. It ran away.")

        let transaction = try #require(transactions.first)
        #expect(transactions.count == 1)
        #expect(transaction.origin == .agent)
        #expect(transaction.owner == "run")
        #expect(transaction.session == rig.queue.session)
        #expect(transaction.base == rig.queue.feed.version)
        #expect(transaction.steps == [EditStep(span: Span(location: 7, length: 2), text: "he", expect: "eh")])
        // The user turn is the sentence, nothing else.
        #expect(await rig.session.requests == ["I saw teh dog."])

        rig.land(transactions)
        #expect(rig.field == "I saw the dog. It ran away.")
        #expect(await rig.feed().isEmpty)  // the second sentence: asked, needs nothing
        #expect(await rig.session.requests == ["I saw teh dog.", "It ran away."])
        #expect(await rig.feed().isEmpty)
        #expect(await rig.session.requests.count == 2)  // Checked sentences, and the agent's own result, are not asked again.
        #expect(await rig.session.trims.isEmpty)
    }

    @Test func aRewriteWithSeveralChangesLandsAsOneTransactionOfMinimalSteps() async throws {
        let rig = await Rig(scripts: [.reply("We fly to Paris on Monday.")])
        let transactions = await rig.dictate("um we fly to paris on monday.")
        let transaction = try #require(transactions.first)
        #expect(transactions.count == 1)
        #expect(transaction.steps.count == 3)
        #expect(transaction.steps.allSatisfy { $0.expect.count <= 4 })  // never the whole sentence
        rig.land(transactions)
        #expect(rig.field == "We fly to Paris on Monday.")
    }

    @Test func theSessionKeepsNoNotesOnlyTheTurns() async throws {
        let rig = await Rig(scripts: [.reply("I saw the dog.")])
        rig.land(await rig.dictate("I saw teh dog. It ran away."))
        _ = await rig.feed()
        #expect(await rig.session.appended.isEmpty)
    }

    @Test func aModelThatSplitsASentenceIsNotAskedAboutEitherHalfAgain() async throws {
        let rig = await Rig(scripts: [.reply("I went home. I slept.")])
        rig.land(await rig.dictate("I went home I slept."))
        #expect(rig.field == "I went home. I slept.")
        #expect(await rig.feed().isEmpty)
        #expect(await rig.session.requests.count == 1)
    }

    @Test func eachSentenceOfASeveralSentenceWriteIsItsOwnTurnUntilOneEdits() async throws {
        let rig = await Rig(scripts: [.reply("One."), .reply("We saw the cat.")])
        let transactions = await rig.dictate("One. We saw teh cat. Three.")
        #expect(await rig.session.requests == ["One.", "We saw teh cat."])
        #expect(transactions.count == 1)  // an edit goes out as soon as there is one
        rig.land(transactions)
        _ = await rig.feed()
        #expect(await rig.session.requests == ["One.", "We saw teh cat.", "Three."])
        #expect(rig.field == "One. We saw the cat. Three.")
    }

    // MARK: Endpointing

    @Test func anUnfinishedLastSentenceWaitsForTheStop() async throws {
        let rig = await Rig(scripts: [.reply("Hello world."), .reply("Bye bye.")])
        let transactions = await rig.dictate("Hello wrold. Bye bye")
        #expect(transactions.count == 1)
        #expect(await rig.session.requests == ["Hello wrold."])

        let final = await rig.agent.finish()
        #expect(await rig.session.requests.last == "Bye bye")
        let step = try #require(final.first?.steps.first)
        #expect(step == EditStep(span: .at("Hello wrold. Bye bye".utf16.count), text: ".", expect: ""))
    }

    @Test func aPauseEndsAnUnpunctuatedSentenceAndWakesTheRun() async throws {
        let rig = await Rig(scripts: [.reply("We fly on Monday.")], endpoint: .init(pause: .milliseconds(50), maxWords: 30))
        #expect(await rig.dictate("we fly on monday").isEmpty)
        #expect(await rig.session.requests.isEmpty)
        // The agent asks its run to come back once the pause has passed.
        try await Task.sleep(for: .milliseconds(300))
        #expect(rig.wakes.value == 1)

        rig.clock.advance(.milliseconds(60))
        let transactions = await rig.agent.replan()
        #expect(await rig.session.requests == ["we fly on monday"])
        rig.land(transactions)
        #expect(rig.field == "We fly on Monday.")
    }

    @Test func textAfterAPauseCutIsTheNextSentence() async throws {
        let rig = await Rig(scripts: [.reply("We fly")], endpoint: .init(pause: .milliseconds(50), maxWords: 30))
        _ = await rig.dictate("we fly")
        rig.clock.advance(.milliseconds(60))
        rig.land(await rig.agent.replan())
        _ = await rig.dictate(" and then home.")
        #expect(await rig.session.requests == ["we fly", "and then home."])
        #expect(rig.field == "We fly and then home.")
    }

    @Test func aRunOnIsSentAtTheWordLimit() async throws {
        let rig = await Rig(endpoint: .init(pause: .seconds(60), maxWords: 5))
        _ = await rig.dictate("one two three four")
        #expect(await rig.session.requests.isEmpty)
        _ = await rig.dictate(" five six")
        #expect(await rig.session.requests == ["one two three four five six"])
        _ = await rig.dictate(" seven eight")  // after the cut: a new sentence, not finished yet
        #expect(await rig.session.requests.count == 1)
        _ = await rig.agent.finish()
        #expect(await rig.session.requests.last == "seven eight")
    }

    @Test func tentativeTextAtTheEndOfTheRunIsNotOfferedUntilItIsFinal() async throws {
        let rig = await Rig(scripts: [.reply("The cat sat."), .reply("The dog ran.")])
        rig.write("Teh cat sat. Teh dog ran.")
        await rig.agent.setTentative(length: " Teh dog ran.".utf16.count)
        let first = await rig.feed()
        #expect(await rig.session.requests == ["Teh cat sat."])
        #expect(first.allSatisfy { $0.steps.allSatisfy { $0.span.end <= "Teh cat sat.".utf16.count } })

        await rig.agent.setTentative(length: 0)
        let second = await rig.agent.replan()
        #expect(await rig.session.requests.last == "Teh dog ran.")
        let step = try #require(second.first?.steps.first)
        #expect(step.span.location >= "Teh cat sat. ".utf16.count)
    }

    @Test func aRunOfOnlyTentativeTextAsksNothing() async throws {
        let rig = await Rig()
        rig.write("Teh cat sat.")
        await rig.agent.setTentative(length: "Teh cat sat.".utf16.count)
        #expect(await rig.feed().isEmpty)
        #expect(await rig.session.requests.isEmpty)
    }

    // MARK: Guard and failures

    @Test(arguments: [
        FakeSession.Script.reply(""),
        .reply("Dogs are loyal animals that have lived alongside humans for thousands of years."),
        .reply("Ich habe den Hund gesehen."),
        .fail,
    ])
    private func aBadReplyChangesNothing(script: FakeSession.Script) async throws {
        let rig = await Rig(scripts: [script])
        let transactions = await rig.dictate("I saw teh dog.")
        #expect(transactions.isEmpty)
        #expect(rig.field == "I saw teh dog.")
        #expect(await rig.feed().isEmpty)
        #expect(await rig.session.requests.count == 1)  // not retried in a loop while listening
    }

    @Test func aTimeoutKeepsTheRawTextAndTheStopTriesOnce() async throws {
        let rig = await Rig(scripts: [.hang, .reply("It ran away."), .reply("I saw the dog.")], timeout: .milliseconds(100))
        let clock = ContinuousClock()
        let start = clock.now
        #expect(await rig.dictate("I saw teh dog. It ran away.").isEmpty)
        #expect(start.duration(to: clock.now) < .seconds(10))
        _ = await rig.feed()
        #expect(await rig.session.requests.filter { $0 == "I saw teh dog." }.count == 1)

        let final = await rig.agent.finish()
        #expect(final.count == 1)
        #expect(await rig.session.requests.filter { $0 == "I saw teh dog." }.count == 2)
    }

    @Test func aTimeoutAtStopKeepsTheRawText() async throws {
        let rig = await Rig(scripts: [.hang, .hang], timeout: .milliseconds(100))
        _ = await rig.dictate("I saw teh dog. It ran away")
        #expect(await rig.agent.finish().isEmpty)
        #expect(rig.field == "I saw teh dog. It ran away")
    }

    // MARK: Context share

    @Test func everyTurnStaysWithinHalfTheBudgetKeepingTheHead() async throws {
        let rig = await Rig(budget: 1_000, head: 200)
        for n in 0..<20 {
            rig.land(await rig.dictate("Sentence number \(n) has quite a few words in it to fill the context. "))
        }
        let trims = await rig.session.trims
        #expect(!trims.isEmpty)  // trimmed well before the backend's budget
        let usage = await rig.session.usageAtRespond
        #expect(usage.count == 20)
        #expect(usage.allSatisfy { $0 <= 500 })
        // The head is never what is trimmed.
        #expect(trims.allSatisfy { $0 <= 500 - 200 })
    }

    // MARK: The user's text and hand-backs

    @Test func aSentenceTheUserTouchedIsNeverEditedAgain() async throws {
        let rig = await Rig(scripts: [.reply("The cat sat."), .reply("The dog ran.")])
        let first = await rig.dictate("Teh cat sat. Teh dog ran. The end.")
        #expect(first.count == 1)
        rig.submit(first)
        rig.user("Tea cat sat. Teh dog ran. The end.")  // The user types inside the first edit's range.
        rig.drain()
        #expect(rig.field == "Tea cat sat. Teh dog ran. The end.")

        let second = await rig.feed()
        #expect(await rig.session.requests.contains { $0.contains("Tea") } == false)
        rig.land(second)
        _ = await rig.agent.finish()
        #expect(rig.field == "Tea cat sat. The dog ran. The end.")
        #expect(await rig.session.requests.contains { $0.contains("Tea") } == false)
    }

    @Test func theTextTheRunDidNotWriteStaysOut() async throws {
        let rig = await Rig(existing: "Old teh text. ", scripts: [.reply("New the one.")])
        let transactions = await rig.dictate("New teh one. Next.")
        #expect(await rig.session.requests == ["New teh one."])
        rig.land(transactions)
        _ = await rig.agent.finish()
        #expect(await rig.session.requests.allSatisfy { !$0.contains("Old") })
        #expect(rig.field == "Old teh text. New the one. Next.")
    }

    @Test func aSupersededEditIsPlannedAgain() async throws {
        let rig = await Rig(scripts: [.reply("I saw the dog."), .reply("I saw the dog.")])
        let first = await rig.dictate("I saw teh dog.")
        let id = try #require(first.first?.id)
        #expect(await rig.agent.replan().isEmpty)  // Nothing changed: nothing to ask.

        await rig.agent.superseded(id, by: UUID())
        let second = await rig.agent.replan()
        #expect(second.count == 1)
        #expect(second.first?.id != id)
        #expect(await rig.session.requests.count == 2)
    }

    @Test func conflictsGiveUpAfterTwoTries() async throws {
        let rig = await Rig(scripts: Array(repeating: .reply("I saw the dog."), count: 5))
        var transactions = await rig.dictate("I saw teh dog.")
        await rig.agent.conflicted(Conflict(.expectMismatch), for: try #require(transactions.first?.id))
        transactions = await rig.agent.replan()
        #expect(transactions.count == 1)
        await rig.agent.conflicted(Conflict(.expectMismatch), for: try #require(transactions.first?.id))
        #expect(await rig.agent.replan().isEmpty)
        #expect(await rig.agent.finish().isEmpty)
    }

    @Test func outOfWindowHandBacksAreReplannedWithoutGivingUp() async throws {
        let rig = await Rig(scripts: Array(repeating: .reply("I saw the dog."), count: 5))
        var transactions = await rig.dictate("I saw teh dog.")
        for _ in 0..<3 {
            await rig.agent.conflicted(Conflict(.outOfWindow), for: try #require(transactions.first?.id))
            transactions = await rig.agent.replan()
            #expect(transactions.count == 1)
        }
    }

    // MARK: Run ownership across a reset or resync

    @Test func aResyncBatchRestartsFromItsWindowAndVersion() async throws {
        let rig = await Rig(scripts: [.fail, .reply("The one.")])
        _ = await rig.dictate("Teh one.")
        let session = rig.queue.session
        let batch = FeedBatch(entries: [], version: FieldVersion(5), session: session, resync: true, window: "Fix teh text. Teh one.")
        #expect(await rig.agent.consume(batch).isEmpty)
        let transactions = await rig.agent.finish()

        let transaction = try #require(transactions.first)
        #expect(transaction.base == FieldVersion(5))
        #expect(transaction.session == session)
        #expect(transaction.steps == [EditStep(span: Span(location: 15, length: 2), text: "he", expect: "eh")])
    }

    @Test func aResetKeepsTheTextBeforeTheRunOutOfReach() async throws {
        let rig = await Rig(existing: "Mine teh text. ")
        #expect(await rig.dictate("Hello world.").isEmpty)
        rig.reset(.unaligned)
        #expect(await rig.feed().isEmpty)
        _ = await rig.agent.finish()
        #expect(await rig.session.requests == ["Hello world."])
    }

    @Test func aRunTextFoundTwiceIsNotTheRunsUntilNewRecognizedTextArrives() async throws {
        let rig = await Rig(existing: "Hello world. ", scripts: [.fail])
        _ = await rig.dictate("Hello world.")
        rig.reset(.unaligned)  // "Hello world." now occurs twice: which one is the run's is unknown.
        #expect(await rig.feed().isEmpty)
        #expect(await rig.agent.finish().isEmpty)
        #expect(await rig.session.requests.count == 1)
    }

    @Test func aResyncFromAnotherQueueDropsTheRun() async throws {
        let rig = await Rig(scripts: [.fail])
        _ = await rig.dictate("OK.")
        let batch = FeedBatch(entries: [], version: FieldVersion(3), session: UUID(), resync: true, window: "Dear Bob, OK. Thanks.")
        #expect(await rig.agent.consume(batch).isEmpty)
        #expect(await rig.agent.finish().isEmpty)
        #expect(await rig.session.requests.count == 1)
    }

    @Test func aClearedFieldLeavesNoRun() async throws {
        let rig = await Rig(scripts: [.fail])
        _ = await rig.dictate("Hello world.")
        rig.user("")
        _ = await rig.feed()
        #expect(await rig.agent.finish().isEmpty)
    }

    // MARK: Stop

    @Test func finishDuringATurnWaitsAndThenTakesTheRest() async throws {
        let rig = await Rig(scripts: [.slow(.milliseconds(300), "Hello world."), .reply("Bye bye.")])
        rig.write("Hello world. Bye bye")
        async let rolling = rig.feed()
        try await Task.sleep(for: .milliseconds(100))
        let final = await rig.agent.finish()
        #expect(await rolling.isEmpty)
        let step = try #require(final.first?.steps.first)
        #expect(step == EditStep(span: .at("Hello world. Bye bye".utf16.count), text: ".", expect: ""))
    }

    @Test func anEmojiBeforeAnEditDoesNotShiftIt() async throws {
        let rig = await Rig(existing: "\u{1F600} ", scripts: [.reply("I saw the \u{1F44D}dog.")])
        rig.land(await rig.dictate("I saw teh \u{1F44D}dog. Done."))
        #expect(rig.field == "\u{1F600} I saw the \u{1F44D}dog. Done.")
    }

    // MARK: Replace

    @Test func replaceAsksNothingWhileListeningAndRewritesTheWholeTextAtStop() async throws {
        let rig = await Rig(scripts: [.reply("I saw the dog. It ran away.")], mode: .replace)
        #expect(await rig.dictate("I saw teh dog. It rann away").isEmpty)
        #expect(await rig.session.requests.isEmpty)

        let final = await rig.agent.finish()
        #expect(await rig.session.requests == [CleanupPrompt.Agent.finalRequest("I saw teh dog. It rann away")])
        #expect(final.count == 2)  // one transaction per sentence
        #expect(final.allSatisfy { $0.origin == .agent && $0.owner == "run" })
        rig.land(final)
        #expect(rig.field == "I saw the dog. It ran away.")
    }

    @Test func replaceKeepsTheSentencesWhoseRewriteDrifted() async throws {
        let rig = await Rig(scripts: [.reply("I saw the dog. Completely different words now appear here instead.")], mode: .replace)
        _ = await rig.dictate("I saw teh dog. It ran away quickly.")
        rig.land(await rig.agent.finish())
        #expect(rig.field == "I saw the dog. It ran away quickly.")
    }

    @Test func replaceLeavesASentenceTheUserTouchedAlone() async throws {
        let rig = await Rig(scripts: [.reply("I saw the dog. It ran away.")], mode: .replace)
        _ = await rig.dictate("I saw teh dog. It rann away.")
        rig.user("I saw teh dog. It rann off.")
        _ = await rig.feed()
        rig.land(await rig.agent.finish())
        #expect(rig.field == "I saw the dog. It rann off.")
    }

    @Test func aLongReplaceTextIsRewrittenInChunksOfWholeSentences() async throws {
        let sentence = "This sentence has a number of plain words in it to make the text long enough."
        let text = Array(repeating: sentence, count: 20).joined(separator: " ")
        let rig = await Rig(mode: .replace)
        _ = await rig.dictate(text)
        _ = await rig.agent.finish()
        let requests = await rig.session.requests
        #expect(requests.count > 1)
        #expect(requests.allSatisfy { $0.hasSuffix(CleanupPrompt.Agent.finalRequestLine) })
        #expect(requests.allSatisfy { RewriteContext.estimatedTokens($0) < PassageRewriter.chunkTokens + 60 })
    }

    @Test func thePassageRewriterCleansAWholeText() async throws {
        let session = FakeSession(budget: 4_000, scripts: [.reply("I saw the dog. It ran away.")])
        let rewriter = PassageRewriter(session: session, options: .init(owner: "run"))
        #expect(await rewriter.cleaned("i saw teh dog. it ran away") == "I saw the dog. It ran away.")
        let unchanged = FakeSession(budget: 4_000, scripts: [])
        #expect(await PassageRewriter(session: unchanged, options: .init(owner: "run")).cleaned("Fine.") == nil)
    }

    // MARK: Options

    @Test func theRunsCleanupSettingsPickTheModeAndTheHead() {
        let replace = CleanupOptions(enabled: true, delivery: .replace, style: .markdown, backend: .coreML, itn: false, timeoutSeconds: 4)
        let options = CleanupAgent.Options(replace, owner: "run", locale: Locale(identifier: "en"))
        #expect(options.mode == .replace)
        #expect(options.timeout == .seconds(4))
        #expect(options.contextShare == 50)
        let live = CleanupOptions(enabled: true, delivery: .live, style: .message, backend: .coreML, itn: false, timeoutSeconds: 4)
        #expect(CleanupAgent.Options(live, owner: "run", locale: Locale(identifier: "en")).mode == .live)
        guard case .instructions(let head) = CleanupAgent.sessionHead(for: options).first else {
            Issue.record("no instructions")
            return
        }
        #expect(head.contains("Markdown"))
    }
}
