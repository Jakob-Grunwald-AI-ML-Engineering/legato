import Foundation
import LegatoCore
import LegatoFieldEdit
import LegatoPostProcessing
import Testing
@testable import LegatoAppServices

/// A rolling session whose turns can be watched: whether a turn holds the model right now (a single-worker
/// runtime such as Core ML refuses a second caller then), replies in order (`[]` once they run out).
private actor WatchedSession: LLMSession {
    nonisolated let tokenBudget = 4_000
    private var replies: [(delay: Duration, json: String)]
    private(set) var requests: [String] = []
    private(set) var turnInFlight = false

    init(_ replies: [(Duration, String)]) { self.replies = replies.map { (delay: $0.0, json: $0.1) } }

    func usage() async throws -> LLMTokenUsage { LLMTokenUsage(head: 0, history: 0) }
    func append(_ chunk: LLMSessionChunk) async throws {}
    func respond(to request: String) async throws -> String { "" }
    func respondStructured<Output: LLMStructuredOutput>(_ type: Output.Type, to request: String) async throws -> Output {
        requests.append(request)
        let reply = replies.isEmpty ? (delay: Duration.zero, json: "[]") : replies.removeFirst()
        turnInFlight = true
        defer { turnInFlight = false }
        if reply.delay > .zero { try await Task.sleep(for: reply.delay) }
        return try LLMStructuredDecoding.decode(Output.self, from: reply.json)
    }
    func trim(keepingSuffix tokens: Int) async throws {}
    func warm() async throws {}
    func close() async {}
}

/// The keyboard of an iOS run over a host whose before-context can lose its head (iOS hosts return only part of
/// the text before the caret, e.g. WhatsApp): the queue sees the caret-relative window, the field is the whole
/// text. Edits it takes from the link land after `delay`.
@MainActor
private final class WindowedKeyboard {
    var queue: FieldEditQueue
    /// The whole field.
    var field: String
    /// UTF-16 units at the field's start the host no longer reports.
    var hidden = 0
    var delay: Duration = .zero
    private var published: Int?

    init(_ text: String = "") {
        field = text
        queue = FieldEditQueue(FieldSnapshot(window: text, caret: text.utf16.count))
    }

    var window: String { String(decoding: Array(field.utf16).dropFirst(hidden), as: UTF16.self) }
    var caret: Int { field.utf16.count - hidden }

    var transport: LinkedCleanupRun.Transport {
        LinkedCleanupRun.Transport(
            read: { @MainActor [unowned self] in self.publish() },
            send: { @MainActor [unowned self] transactions in self.receive(transactions) })
    }

    func publish() -> [FeedBatch] {
        let batch = queue.feed.since(published)
        guard batch.resync || !batch.entries.isEmpty else { return [] }
        published = batch.lastSeq
        return [batch]
    }

    func receive(_ transactions: [EditTransaction]) {
        for transaction in transactions { queue.submit(transaction) }
        if delay == .zero { return drain() }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: self?.delay ?? .zero)
            self?.drain()
        }
    }

    func drain() {
        while let write = queue.next() {
            var units = Array(field.utf16)
            for step in write.steps {
                let start = step.span.location + hidden
                units.replaceSubrange(start..<(start + step.span.length), with: Array(step.text.utf16))
            }
            field = String(decoding: units, as: UTF16.self)
            queue.settle(FieldSnapshot(window: window, caret: write.caret))
        }
    }

    func asr(_ text: String) {
        queue.submit(EditTransaction(origin: .asr, owner: "run", base: queue.document.version, steps: [.insert(text, at: caret)]))
        drain()
    }

    /// The host stops reporting the field's first `count` UTF-16 units (its before-context got shorter).
    func hideHead(_ count: Int) {
        hidden += count
        queue.observe(FieldSnapshot(window: window, caret: caret))
    }
}

private func edit(_ sentence: Int, _ text: String) -> String { #"[{"sentence":\#(sentence),"text":"\#(text)"}]"# }

@Suite(.timeLimit(.minutes(1)))
@MainActor
struct LinkedCleanupStopTests {
    // MARK: Replace on the device (iPhone, WhatsApp): the run's head scrolled out of the window

    /// The device's Replace run: the host's before-context lost the run's head mid-run, so the field cannot show
    /// that the run's text is still there. The patches are not written (a step outside the window is never
    /// written), the session's cleaned text goes to the clipboard, and the stop says why.
    @Test func replaceWithTheRunsHeadOutOfTheWindowFallsBackAndSaysWhy() async {
        let keyboard = WindowedKeyboard()
        let run = LinkedCleanupRun(owner: "run", agent: nil, transport: keyboard.transport, finalWait: .milliseconds(300))
        run.feedChanged()
        keyboard.asr("teh cat sat on the mat. ")
        run.feedChanged()
        keyboard.hideHead(13)  // "teh cat sat o" is no longer reported
        keyboard.asr("a dgo ran.")
        let raw = "teh cat sat on the mat. a dgo ran."
        let stop = await run.stop(
            .replace, committed: raw, text: "The cat sat on the mat. A dog ran.", finalText: "The cat sat on the mat. A dog ran.",
            applied: { true }, statelessPass: { _ in Issue.record("Replace makes no second pass"); return nil },
            copy: { _ in true })
        #expect(stop.landed == false)  // the session copies its cleaned text, with today's notice
        #expect(keyboard.field == raw)
        #expect(run.stopReport?.branch == .notShown)
        #expect(run.stopReport?.reason == "outOfWindow")
        #expect(run.stopReport?.line.hasPrefix("linked.stop mode=replace branch=notShown reason=outOfWindow") == true)
    }

    /// Replace with the run's text in the window: the patches land, and the stop says they were sent and acked.
    @Test func replaceThatLandsReportsItsEditsAndTheirOutcomes() async {
        let keyboard = WindowedKeyboard("Hi")
        let run = LinkedCleanupRun(owner: "run", agent: nil, transport: keyboard.transport, finalWait: .milliseconds(300))
        run.feedChanged()
        keyboard.asr(" teh cat sat. a dgo ran.")
        var passes = 0
        let stop = await run.stop(
            .replace, committed: "teh cat sat. a dgo ran.", text: "the cat sat. a dog ran.", finalText: "the cat sat. a dog ran.",
            applied: { true }, statelessPass: { _ in passes += 1; return nil }, copy: { _ in true })
        #expect(stop.landed)
        #expect(passes == 0)  // the session's own pass is the run's one cleanup call
        #expect(keyboard.field == "Hi the cat sat. a dog ran.")
        let report = run.stopReport
        #expect(report?.branch == .applied && report?.sent == 1 && report?.acked == 1)
        #expect(report?.steps == 2)  // two small patches, not one whole-text replace
    }

    /// The keyboard takes longer than the old fixed 2 s to land the stop's edit (its queue still verifies the
    /// stream's last writes, a slow extension): the wait is the pass timeout plus a margin, so it still lands.
    @Test func theStopsWaitIsThePassTimeoutPlusAMargin() async {
        #expect(LinkedCleanupRun.stopWait(passTimeout: .seconds(8)) == .seconds(10))
        let keyboard = WindowedKeyboard()
        keyboard.delay = .milliseconds(1_500)
        let run = LinkedCleanupRun(
            owner: "run", agent: nil, transport: keyboard.transport,
            finalWait: LinkedCleanupRun.stopWait(passTimeout: .milliseconds(100)))
        run.feedChanged()
        keyboard.asr("teh cat")
        let delivered = await run.deliver(raw: "teh cat", cleaned: "the cat")
        #expect(delivered == .applied)
        #expect(keyboard.field == "the cat")
    }

    // MARK: Live

    /// The keyboard is gone at the stop while the agent's turn still holds the model: the turn is cancelled and
    /// settled before the stateless pass runs, so the pass never meets a busy single-worker runtime (Core ML
    /// refuses a second caller: the pass would fail and the run keep its raw text).
    @Test func theStatelessPassNeverRunsWhileAnAgentTurnHoldsTheModel() async {
        let keyboard = WindowedKeyboard()
        let session = WatchedSession([(.seconds(5), edit(1, "I saw the dog."))])
        let run = LinkedCleanupRun(
            owner: "run", agent: { CleanupAgent(session: session, options: .init(owner: "run", timeout: .seconds(10))) },
            transport: keyboard.transport, agentWait: .milliseconds(300), finalWait: .milliseconds(300))
        run.feedChanged()
        keyboard.asr("I saw teh dog.")
        run.heard(committed: "I saw teh dog. ", volatile: "")
        var asked = false
        for _ in 0..<200 where !asked {
            asked = await session.turnInFlight
            if !asked { try? await Task.sleep(for: .milliseconds(10)) }
        }
        #expect(asked)
        var busyAtPass: Bool?
        let stop = await run.stop(
            .live, committed: "I saw teh dog. ", text: "I saw teh dog.", finalText: nil, applied: nil,
            statelessPass: { _ in busyAtPass = await session.turnInFlight; return "I saw the dog." },
            copy: { _ in true })
        #expect(busyAtPass == false)
        #expect(stop == .init(landed: true, cleaned: "I saw the dog."))
        #expect(run.stopReport?.branch == .noKeyboard)
    }

    /// History follows what the user got: the clipboard refused the cleaned text (the keyboard was gone), so the
    /// run's entry does not claim it; the session's own text is what the caller copies then.
    @Test func aRefusedClipboardDoesNotPutTheCleanedTextInTheHistory() async {
        let keyboard = WindowedKeyboard()
        let session = WatchedSession([])
        let run = LinkedCleanupRun(
            owner: "run", agent: { CleanupAgent(session: session, options: .init(owner: "run", timeout: .seconds(5))) },
            transport: keyboard.transport, agentWait: .milliseconds(300), finalWait: .milliseconds(300))
        run.feedChanged()
        keyboard.asr("teh cat sat")
        run.feedChanged()
        let stop = await run.stop(
            .live, committed: "teh cat sat ", text: "teh cat sat", finalText: nil, applied: nil,
            statelessPass: { _ in "The cat sat." }, copy: { _ in false })
        #expect(stop == .init(landed: false, cleaned: nil))
    }

    /// Live, the agent absent and the field's run text unknown at the stop (out of the window): the stateless
    /// pass goes to the clipboard, and its text only into the history when it got there.
    @Test func anAbsentAgentWhoseRunIsOutOfTheWindowCopiesAndReportsIt() async {
        let keyboard = WindowedKeyboard()
        let run = LinkedCleanupRun(
            owner: "run", agent: { nil }, transport: keyboard.transport, agentWait: .milliseconds(100),
            finalWait: .milliseconds(200))
        run.feedChanged()
        keyboard.asr("teh cat sat on the mat. ")
        run.feedChanged()
        keyboard.hideHead(13)
        keyboard.asr("a dgo ran.")
        var copied: [String] = []
        let stop = await run.stop(
            .live, committed: "teh cat sat on the mat. a dgo ran.", text: "teh cat sat on the mat. a dgo ran.",
            finalText: nil, applied: { true }, statelessPass: { _ in "The cat sat on the mat. A dog ran." },
            copy: { copied.append($0); return true })
        #expect(copied == ["The cat sat on the mat. A dog ran."])
        #expect(stop == .init(landed: true, cleaned: "The cat sat on the mat. A dog ran."))
        #expect(run.stopReport?.branch == .agentAbsent)
        #expect(run.stopReport?.reason == "outOfWindow")
        #expect(run.stopReport?.copied == true)
    }
}
