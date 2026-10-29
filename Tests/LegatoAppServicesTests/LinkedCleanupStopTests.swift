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
    /// Runs after the edits taken from the link are queued, before they are written (the user acts meanwhile).
    var beforeDrain: (() -> Void)?
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
        beforeDrain?()
        beforeDrain = nil
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

    /// The user deletes the field's last UTF-16 unit (a backspace at the caret).
    func userBackspace() {
        field = String(decoding: Array(field.utf16).dropLast(), as: UTF16.self)
        queue.observe(FieldSnapshot(window: window, caret: caret))
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

    /// The device's Replace run: the host's before-context lost the run's head mid-run. The patches inside the
    /// window are written; the one in the head is not (a step outside the window never is): the session's whole
    /// cleaned text goes to the clipboard with the partial notice, and the stop says how much landed and why.
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
        #expect(stop.landed == false)  // the session copies its whole cleaned text
        #expect(run.notice == LinkedCleanupRun.partialNotice)
        #expect(keyboard.field == "teh cat sat on the mat. A dog ran.")
        #expect(run.stopReport?.branch == .partial)
        #expect(run.stopReport?.reason == "outOfWindow")
        #expect(run.stopReport?.line.hasPrefix("linked.stop mode=replace branch=partial reason=outOfWindow") == true)
        #expect(run.stopReport?.line.hasSuffix(" patched=2/3 outOfWindow=1") == true, "\(run.stopReport?.line ?? "-")")
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
        #expect(report?.branch == .applied && report?.sent == 2 && report?.acked == 2)  // one edit per patch
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

    // MARK: Option A: patch what the window shows, the rest via the clipboard (#80)

    /// The run's head left the window, but the feed said exactly how far (its edge shifts): the mirror keeps the
    /// text that scrolled out, so the run's text is still all known (the history records the field as it is).
    @Test func theMirrorKeepsTheRunsHeadThatLeftTheWindow() {
        let keyboard = WindowedKeyboard()
        var mirror = FeedMirror()
        mirror.fold(keyboard.publish().first!)
        keyboard.asr("teh cat sat on the mat. ")
        keyboard.hideHead(13)
        keyboard.asr("a dgo ran.")
        for batch in keyboard.publish() { mirror.fold(batch) }
        #expect(mirror.runText == "teh cat sat on the mat. a dgo ran.")
        let plan = mirror.patches(from: "teh cat sat on the mat. a dgo ran.", to: "The cat sat on the mat. A dog ran.", owner: "run")
        #expect(plan?.patches == 3 && plan?.outOfWindow == 1)
        #expect(plan?.transactions.count == 2)  // one per visible patch; the head's is not sent
        #expect(plan?.transactions.flatMap(\.steps).allSatisfy { $0.span.location >= 0 } == true)
    }

    /// Only the run's tail is known (the head's text was not kept): its place comes from the run's offsets the
    /// feed shifted, the visible text is a guard (the raw text must end with it), never a search.
    @Test func withOnlyTheTailKnownThePatchesAreMappedByTheRunsOffsets() throws {
        let keyboard = WindowedKeyboard()
        var mirror = FeedMirror(headLimit: 0)
        mirror.fold(keyboard.publish().first!)
        keyboard.asr("teh cat sat on the mat. ")
        keyboard.hideHead(13)
        keyboard.asr("a dgo ran.")
        for batch in keyboard.publish() { mirror.fold(batch) }
        #expect(mirror.runText == nil)  // not all of it is known
        let raw = "teh cat sat on the mat. a dgo ran."
        let plan = try #require(mirror.patches(from: raw, to: "The cat sat on the mat. A dog ran.", owner: "run"))
        #expect(plan.patches == 3 && plan.outOfWindow == 1)
        #expect(plan.transactions.flatMap(\.steps).map(\.span.location) == [11, 14])
        keyboard.receive(plan.transactions)
        #expect(keyboard.field == "teh cat sat on the mat. A dog ran.")
        // The visible text is the guard: a raw text that does not end with it, or that is longer than the run's
        // known extent, has no patches.
        #expect(mirror.patches(from: "teh cat sat on the mat. a cat ran.", to: "The cat sat on the mat. A cat ran.", owner: "run") == nil)
        #expect(mirror.unpatchable(raw: "teh cat sat on the mat. a cat ran.") == .textDiffers)
        #expect(mirror.patches(from: "So, teh cat sat on the mat. a dgo ran.", to: "So, the cat sat on the mat. A dog ran.", owner: "run") == nil)
    }

    /// A reset after the head left the window (the run's offsets are negative then) re-anchors without reading
    /// outside the text (no crash), for the mirror and for the agent.
    @Test func aResetAfterTheHeadLeftTheWindowIsSafe() async {
        let keyboard = WindowedKeyboard()
        var mirror = FeedMirror()
        let agent = CleanupAgent(session: WatchedSession([]), options: .init(owner: "run"))
        func feed() async {
            for batch in keyboard.publish() {
                mirror.fold(batch)
                _ = await agent.consume(batch)
            }
        }
        await feed()
        keyboard.asr("teh cat sat on the mat. ")
        keyboard.hideHead(13)
        keyboard.asr("a dgo ran.")
        await feed()
        keyboard.queue.reset(FieldSnapshot(window: keyboard.window, caret: keyboard.caret), reason: .unaligned)
        await feed()
        #expect(mirror.runText == nil)
        #expect(mirror.unpatchable(raw: "teh cat sat on the mat. a dgo ran.") == .outOfWindow)
    }

    /// Live: the agent's edits target the newest sentences, which are in the window: they land although the run's
    /// head is out of it. The sentence cut by the window's edge is only context (its start is not visible). At
    /// the stop the history gets the run's whole text as the field holds it, not only the visible tail.
    @Test func liveEditsLandWithTheRunsHeadOutOfTheWindow() async {
        let keyboard = WindowedKeyboard()
        let session = WatchedSession([(.zero, "[]"), (.zero, #"[{"sentence":1,"text":"N the mat."},{"sentence":2,"text":"A dog ran."}]"#)])
        let run = LinkedCleanupRun(
            owner: "run", agent: { CleanupAgent(session: session, options: .init(owner: "run", timeout: .seconds(5))) },
            transport: keyboard.transport, agentWait: .milliseconds(300), finalWait: .milliseconds(300))
        run.feedChanged()
        keyboard.asr("teh cat sat on the mat. ")
        run.feedChanged()
        var asked = false
        for _ in 0..<200 where !asked {
            asked = await session.requests.count == 1
            if !asked { try? await Task.sleep(for: .milliseconds(10)) }
        }
        #expect(asked)
        keyboard.hideHead(13)
        keyboard.asr("A dgo ran.")  // a new sentence: a capital after the period
        run.feedChanged()
        var landed = false
        for _ in 0..<200 where !landed {
            landed = keyboard.field.hasSuffix("A dog ran.")
            if !landed { try? await Task.sleep(for: .milliseconds(10)) }
        }
        #expect(landed, "\(keyboard.field)")
        #expect(keyboard.field == "teh cat sat on the mat. A dog ran.")  // the cut sentence was not edited
        let stop = await run.stop(
            .live, committed: "teh cat sat on the mat. A dgo ran.", text: "teh cat sat on the mat. A dgo ran.",
            finalText: nil, applied: { true }, statelessPass: { _ in nil }, copy: { _ in true })
        #expect(stop == .init(landed: true, cleaned: "teh cat sat on the mat. A dog ran."))
        #expect(run.stopReport?.branch == .applied)
    }

    /// Live without an agent, the head out of the window: the stateless pass's visible patches land, the rest
    /// goes to the clipboard as the whole cleaned text, with the partial notice.
    @Test func anAbsentAgentsPassPatchesTheVisiblePart() async {
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
        #expect(keyboard.field == "teh cat sat on the mat. A dog ran.")
        #expect(copied == ["The cat sat on the mat. A dog ran."])
        #expect(run.notice == LinkedCleanupRun.partialNotice)
        #expect(run.stopReport?.line.hasSuffix(" patched=2/3 outOfWindow=1") == true, "\(run.stopReport?.line ?? "-")")
    }

    /// Everything the stop sent landed: the report says all patches did, and no notice is given.
    @Test func aStopThatLandsReportsAllPatchesAndNoNotice() async {
        let keyboard = WindowedKeyboard("Hi")
        let run = LinkedCleanupRun(owner: "run", agent: nil, transport: keyboard.transport, finalWait: .milliseconds(300))
        run.feedChanged()
        keyboard.asr(" teh cat sat. a dgo ran.")
        let stop = await run.stop(
            .replace, committed: "teh cat sat. a dgo ran.", text: "the cat sat. a dog ran.", finalText: "the cat sat. a dog ran.",
            applied: { true }, statelessPass: { _ in nil }, copy: { _ in true })
        #expect(run.notice == nil)
        #expect(run.stopReport?.line.hasSuffix(" patched=2/2 outOfWindow=0") == true, "\(run.stopReport?.line ?? "-")")
    }

    /// One of three patches fails its guard (the user deleted into it before it was written): only that patch is
    /// left out, the other two land (one edit per patch: a single fail never stops the others).
    @Test func aFailedGuardLeavesOnlyItsPatchOut() async {
        let keyboard = WindowedKeyboard()
        let run = LinkedCleanupRun(owner: "run", agent: nil, transport: keyboard.transport, finalWait: .milliseconds(300))
        run.feedChanged()
        keyboard.asr("teh cat sat. A dgo ran. It thrre")
        keyboard.beforeDrain = { keyboard.userBackspace() }  // "…It thrr": the third patch's text is gone
        let stop = await run.stop(
            .replace, committed: "teh cat sat. A dgo ran. It thrre", text: "the cat sat. A dog ran. It three.",
            finalText: "the cat sat. A dog ran. It three.", applied: { true }, statelessPass: { _ in nil }, copy: { _ in true })
        #expect(keyboard.field == "the cat sat. A dog ran. It thrr")
        #expect(stop.landed == false)  // the session copies its whole cleaned text
        #expect(run.stopReport?.branch == .partial)
        #expect(run.stopReport?.reason == "conflict")
        #expect(run.stopReport?.sent == 3)
        #expect(run.stopReport?.line.hasSuffix(" patched=2/3 outOfWindow=0") == true, "\(run.stopReport?.line ?? "-")")
    }
}
