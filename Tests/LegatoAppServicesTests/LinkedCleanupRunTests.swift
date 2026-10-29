import Foundation
import LegatoCore
import LegatoFieldEdit
import LegatoPostProcessing
import Testing
@testable import LegatoAppServices

/// A scripted rolling session: replies in order (`[]` once they run out); a reply may wait first.
private actor ScriptedSession: LLMSession {
    nonisolated let tokenBudget = 4_000
    private var replies: [(delay: Duration, json: String)]
    private(set) var requests: [String] = []
    private(set) var appended: [String] = []

    init(_ replies: [(Duration, String)]) { self.replies = replies.map { (delay: $0.0, json: $0.1) } }

    func usage() async throws -> LLMTokenUsage { LLMTokenUsage(head: 0, history: 0) }
    func append(_ chunk: LLMSessionChunk) async throws { if case .text(let text) = chunk { appended.append(text) } }
    func respond(to request: String) async throws -> String { "" }
    func respondStructured<Output: LLMStructuredOutput>(_ type: Output.Type, to request: String) async throws -> Output {
        requests.append(request)
        let reply = replies.isEmpty ? (delay: Duration.zero, json: "[]") : replies.removeFirst()
        if reply.delay > .zero { try await Task.sleep(for: reply.delay) }
        return try LLMStructuredDecoding.decode(Output.self, from: reply.json)
    }
    func trim(keepingSuffix tokens: Int) async throws {}
    func warm() async throws {}
    func close() async {}
}

private func edit(_ sentence: Int, _ text: String) -> String { #"[{"sentence":\#(sentence),"text":"\#(text)"}]"# }

/// The keyboard of an iOS run, in memory: its queue over the caret-relative window, the feed it publishes, the
/// edits it takes from the link (each written and confirmed at once).
@MainActor
private final class Keyboard {
    var queue: FieldEditQueue
    var field: String
    var caret: Int
    private var published: Int?
    var inbox: [EditTransaction] = []

    init(_ text: String = "") {
        field = text
        caret = text.utf16.count
        queue = FieldEditQueue(FieldSnapshot(window: text, caret: text.utf16.count))
    }

    var transport: LinkedCleanupRun.Transport {
        LinkedCleanupRun.Transport(
            read: { @MainActor [unowned self] in self.publish() },
            send: { @MainActor [unowned self] transactions in self.receive(transactions) })
    }

    /// The batches since the last read (one per call here: the feed so far).
    func publish() -> [FeedBatch] {
        let batch = queue.feed.since(published)
        guard batch.resync || !batch.entries.isEmpty else { return [] }
        published = batch.lastSeq
        return [batch]
    }

    /// The keyboard process starts over (a crash, a new appearance): a new queue instance over the same field; its
    /// first batch is a resync from another session.
    func restart() {
        queue = FieldEditQueue(FieldSnapshot(window: field, caret: caret))
        published = nil
    }

    /// The keyboard takes no edits (it went away): they never get an outcome.
    var deaf = false

    func receive(_ transactions: [EditTransaction]) {
        guard !deaf else { return }
        for transaction in transactions { queue.submit(transaction) }
        drain()
    }

    func drain() {
        while let write = queue.next() {
            for step in write.steps { field = step.apply(to: field)! }
            caret = write.caret
            queue.settle(FieldSnapshot(window: field, caret: caret))
        }
    }

    /// The run's stream: ASR text at the caret.
    func asr(_ text: String) {
        queue.submit(EditTransaction(origin: .asr, owner: "run", base: queue.document.version, steps: [.insert(text, at: caret)]))
        drain()
    }

    /// The user types `text` at UTF-16 offset `at` (the caret moved there, then back to the end).
    func user(_ text: String, at: Int) {
        queue.observe(FieldSnapshot(window: field, caret: at))  // the user taps there
        var units = Array(field.utf16)
        units.insert(contentsOf: text.utf16, at: at)
        field = String(decoding: units, as: UTF16.self)
        queue.observe(FieldSnapshot(window: field, caret: at + text.utf16.count))  // types
        caret = field.utf16.count
        queue.observe(FieldSnapshot(window: field, caret: caret))  // and taps the end again
    }
}

@MainActor
private func run(_ keyboard: Keyboard, session: ScriptedSession?, agentDelay: Duration = .zero) -> LinkedCleanupRun {
    var agent: (@Sendable () async -> CleanupAgent?)?
    if let session {
        agent = { @Sendable () async -> CleanupAgent? in
            if agentDelay > .zero { try? await Task.sleep(for: agentDelay) }
            return CleanupAgent(session: session, options: .init(owner: "run", timeout: .seconds(5)))
        }
    }
    return LinkedCleanupRun(
        owner: "run", agent: agent, transport: keyboard.transport, agentWait: .milliseconds(300), finalWait: .milliseconds(500))
}

/// Waits until `condition` holds (2 s at most), letting the run's tasks go on.
@MainActor
private func linkSettles(_ condition: @MainActor () async -> Bool) async -> Bool {
    for _ in 0..<200 {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return false
}

@Suite(.timeLimit(.minutes(1)))
@MainActor
struct LinkedCleanupRunTests {
    // MARK: Patches

    @Test func twoCorrectionsFarApartAreTwoSmallSteps() {
        let steps = TextPatches.steps(from: "teh cat sat. a dgo ran.", to: "the cat sat. a dog ran.", at: 3)
        #expect(steps == [
            EditStep(span: Span(location: 4, length: 2), text: "he", expect: "eh"),
            EditStep(span: Span(location: 19, length: 2), text: "og", expect: "go"),
        ])
    }

    @Test func insertedAndRemovedWordsArePatchesToo() {
        let old = "um so we meet at ten"
        let new = "So we meet at 10."
        var text = old
        for step in TextPatches.steps(from: old, to: new, at: 0).reversed() { text = step.apply(to: text)! }
        #expect(text == new)
    }

    /// The run streamed after the user's own text: the patch goes into the run's text only, at its place.
    @Test func theFinalPatchRewritesOnlyTheRunsText() throws {
        let keyboard = Keyboard("Hi")
        var mirror = FeedMirror()
        mirror.fold(keyboard.publish().first!)
        keyboard.asr(" hello teh")
        mirror.fold(keyboard.publish().first!)
        #expect(mirror.runText == "hello teh")
        let patch = try #require(mirror.patch(from: "hello teh", to: "Hello the.", owner: "run"))
        #expect(patch.origin == .finalSwap)
        #expect(patch.base == keyboard.queue.feed.version && patch.session == keyboard.queue.session)
        keyboard.receive([patch])
        #expect(keyboard.field == "Hi Hello the.")
    }

    @Test func noFinalPatchWhenTheUserChangedTheRunsText() {
        let keyboard = Keyboard()
        var mirror = FeedMirror()
        mirror.fold(keyboard.publish().first!)
        keyboard.asr("hello teh")
        keyboard.user("x", at: 2)
        mirror.fold(keyboard.publish().first!)
        #expect(mirror.patch(from: "hello teh", to: "hello the", owner: "run") == nil)
    }

    @Test func aClearedFieldForgetsTheRunsText() {
        let keyboard = Keyboard()
        var mirror = FeedMirror()
        mirror.fold(keyboard.publish().first!)
        keyboard.asr("hello teh")
        keyboard.queue.reset(FieldSnapshot(window: "", caret: 0), reason: .cleared)
        mirror.fold(keyboard.publish().first!)
        #expect(mirror.runText == nil && mirror.wasCleared)
    }

    // MARK: Live

    /// Live: the agent's sentence edit goes over the link and lands as a 2/2 patch; the stop takes its final pass
    /// and nothing is left unapplied.
    @Test func theAgentsEditsLandOverTheLink() async {
        let keyboard = Keyboard()
        let session = ScriptedSession([(.zero, edit(1, "I saw the dog."))])
        let run = run(keyboard, session: session)
        run.feedChanged()  // the keyboard's first batch: the field before the run's text
        keyboard.asr("I saw teh dog.")
        run.heard(committed: "I saw teh dog. ", volatile: "")
        let ready1 = await linkSettles { @MainActor in keyboard.field == "I saw the dog." }
        #expect(ready1)
        let outcome = await run.finish()
        #expect(outcome == .init(unapplied: []))
        let appended = await session.appended
        #expect(appended.contains { $0.contains("I saw teh dog.") })  // heard
    }

    /// The user types into the sentence the agent is rewriting while it thinks: the edit comes back as a conflict
    /// with the user's note, the agent writes the note into its context and goes on with the next sentence; the
    /// user's text stays.
    @Test func aUserEditMidRunConflictsWithANoteAndTheAgentReplans() async {
        let keyboard = Keyboard()
        let session = ScriptedSession([(.milliseconds(300), edit(1, "the cat sat.")), (.zero, edit(2, "A dog ran."))])
        let run = run(keyboard, session: session)
        var lines: [String] = []
        run.trace = { lines.append($0) }
        run.feedChanged()
        keyboard.asr("teh cat sat.")
        run.feedChanged()
        let ready2 = await linkSettles { await session.requests.count == 1 }
        #expect(ready2)
        keyboard.user("x", at: 2)  // "texh cat sat."
        keyboard.asr(" A dgo ran.")  // a new sentence: a capital after the period
        run.feedChanged()
        let ready3 = await linkSettles { @MainActor in keyboard.field == "texh cat sat. A dog ran." }
        #expect(ready3, "\(keyboard.field)")
        let outcome = await run.finish()
        #expect(lines.contains("agent.outcome result=conflict reason=overlap byUser=1 note=1"))
        let notes = await session.appended
        #expect(notes.contains { $0.contains(Conflict.userNote) })
        let requests = await session.requests
        #expect(requests.count == 2 && requests[1].contains("Locked: 1"))
        #expect(outcome.unapplied.isEmpty)  // the conflicted one was re-planned during the run
        #expect(keyboard.field == "texh cat sat. A dog ran.")
    }

    /// The final pass's edit gets no outcome within the wait: it is unapplied, and the fallback text carries it.
    @Test func aFinalEditThatDoesNotLandIsLeftForTheClipboard() async {
        let keyboard = Keyboard()
        let session = ScriptedSession([(.zero, edit(1, "I saw the dog"))])
        let run = run(keyboard, session: session)
        run.feedChanged()
        keyboard.asr("I saw teh dog")  // unfinished: only the final pass reviews it
        run.feedChanged()
        keyboard.deaf = true
        let outcome = await run.finish()
        #expect(outcome.unapplied.count == 1)
        #expect(run.fallbackText(unapplied: outcome.unapplied) == "I saw the dog")
        #expect(keyboard.field == "I saw teh dog")
    }

    /// No rolling session: the agent is absent; the stop's stateless pass goes in as patches.
    @Test func anAbsentAgentLeavesTheStatelessPassToTheStop() async {
        let keyboard = Keyboard()
        let run = LinkedCleanupRun(
            owner: "run", agent: { nil }, transport: keyboard.transport, agentWait: .milliseconds(300),
            finalWait: .milliseconds(500))
        run.feedChanged()
        keyboard.asr("teh cat sat")
        let outcome = await run.finish()
        #expect(outcome.agentAbsent)
        let delivered = await run.deliver(raw: "teh cat sat", cleaned: "The cat sat.")
        #expect(delivered == .applied)
        #expect(keyboard.field == "The cat sat.")
    }

    /// An agent still warming past the cap is absent, and once it arrives it changes nothing.
    @Test func aLateAgentIsRetired() async {
        let keyboard = Keyboard()
        let session = ScriptedSession([(.zero, edit(1, "I saw the dog."))])
        let run = run(keyboard, session: session, agentDelay: .milliseconds(600))
        run.feedChanged()
        keyboard.asr("I saw teh dog.")
        run.feedChanged()
        let late = await run.finish()
        #expect(late.agentAbsent)
        try? await Task.sleep(for: .milliseconds(700))
        let asked = await session.requests
        #expect(asked.isEmpty)
        #expect(keyboard.field == "I saw teh dog.")
    }

    // MARK: Replace

    @Test func replaceWritesTheStatelessPassAsPatches() async {
        let keyboard = Keyboard("Hi")
        let run = LinkedCleanupRun(owner: "run", agent: nil, transport: keyboard.transport, finalWait: .milliseconds(500))
        run.feedChanged()
        keyboard.asr(" teh cat sat. a dgo ran.")
        let delivered = await run.deliver(raw: "teh cat sat. a dgo ran. ", cleaned: "the cat sat. a dog ran.")
        #expect(delivered == .applied)
        #expect(keyboard.field == "Hi the cat sat. a dog ran.")
    }

    @Test func replaceWithTheUserInTheRunsTextIsNotWritten() async {
        let keyboard = Keyboard()
        let run = LinkedCleanupRun(owner: "run", agent: nil, transport: keyboard.transport, finalWait: .milliseconds(500))
        run.feedChanged()
        keyboard.asr("teh cat")
        keyboard.user("x", at: 1)
        let delivered = await run.deliver(raw: "teh cat", cleaned: "the cat")
        #expect(delivered == .notShown)
        #expect(keyboard.field == "txeh cat")
    }

    /// The fallback text for edits that did not land: the run's text with them applied where they are now.
    @Test func theFallbackTextAppliesWhatDidNotLand() async throws {
        let keyboard = Keyboard()
        let run = LinkedCleanupRun(owner: "run", agent: nil, transport: keyboard.transport, finalWait: .milliseconds(100))
        run.feedChanged()
        keyboard.asr("teh cat sat")
        run.feedChanged()
        let pending = try #require(run.mirror.patch(from: "teh cat sat", to: "the cat sat", owner: "run"))
        keyboard.asr(" down")
        run.feedChanged()
        #expect(run.fallbackText(unapplied: [pending]) == "the cat sat down")
    }

    // MARK: Coalescing (review L6 #1)

    /// Batches that arrive while a pass is in flight are taken in together once it is done: one pass over the
    /// newest field (based on the newest version), not one per batch, each based further back.
    @Test func batchesArrivingDuringAPassAreConsumedTogether() async {
        let keyboard = Keyboard()
        let session = ScriptedSession([(.milliseconds(300), edit(1, "I saw the dog."))])
        let run = run(keyboard, session: session)
        run.feedChanged()
        keyboard.asr("I saw teh dog.")
        run.feedChanged()
        let asked = await linkSettles { await session.requests.count == 1 }
        #expect(asked)
        for sentence in [" It ran.", " It sat.", " It slept."] {
            keyboard.asr(sentence)
            run.feedChanged()
        }
        let landed = await linkSettles { @MainActor in keyboard.field.hasPrefix("I saw the dog.") }
        #expect(landed)
        try? await Task.sleep(for: .milliseconds(200))
        let requests = await session.requests
        #expect(requests.count == 2, "\(requests.count) passes")
        #expect(requests.last.map { $0.contains("It ran.") && $0.contains("It slept.") } == true)
        _ = await run.finish()
    }

    // MARK: Mirror re-anchoring (review L6 #5)

    /// A resync from the same queue (the ring dropped batches the app had not read) keeps the run's text where it
    /// is found exactly once, as the agent re-anchors it.
    @Test func aResyncFromTheSameQueueKeepsTheRunsText() {
        let keyboard = Keyboard("Hi")
        var mirror = FeedMirror()
        mirror.fold(keyboard.publish().first!)
        keyboard.asr(" teh cat sat")
        mirror.fold(keyboard.publish().first!)
        keyboard.user("Oh. ", at: 0)
        _ = keyboard.publish()  // never read by the app
        mirror.fold(keyboard.queue.feed.since(nil))
        #expect(mirror.runText == "teh cat sat")
    }

    /// A resync from another queue (the keyboard restarted) is another field as far as anyone can tell: nothing
    /// is the run's, like the agent.
    @Test func aResyncFromAnotherQueueForgetsTheRunsText() {
        let keyboard = Keyboard()
        var mirror = FeedMirror()
        mirror.fold(keyboard.publish().first!)
        keyboard.asr("teh cat sat")
        mirror.fold(keyboard.publish().first!)
        keyboard.restart()
        mirror.fold(keyboard.publish().first!)
        #expect(mirror.runText == nil)
    }

    // MARK: Stop (review L6 #4, #5, #6)

    /// The keyboard went away mid-run with the agent cleaning it (the session's own final pass was off): the
    /// stateless final pass cleans the run's text, and that goes to the clipboard and into the history.
    @Test func aKeyboardGoneAtTheStopOfAnAgentRunCopiesTheStatelessPass() async {
        let keyboard = Keyboard()
        let run = run(keyboard, session: ScriptedSession([]))
        run.feedChanged()
        keyboard.asr("teh cat sat")
        run.feedChanged()
        var copied: [String] = []
        let stop = await run.stop(
            .live, committed: "teh cat sat ", text: "teh cat sat", finalText: nil, applied: nil,
            statelessPass: { _ in "The cat sat." }, copy: { copied.append($0); return true })
        #expect(copied == ["The cat sat."])
        #expect(stop == .init(landed: true, cleaned: "The cat sat."))
    }

    /// Without an agent the session cleaned the text itself: a keyboard gone at the stop leaves it to the session.
    @Test func aKeyboardGoneAtTheStopOfARunWithoutAnAgentLeavesTheSessionsText() async {
        let keyboard = Keyboard()
        let run = LinkedCleanupRun(owner: "run", agent: nil, transport: keyboard.transport, finalWait: .milliseconds(100))
        var passes = 0
        var copied: [String] = []
        let stop = await run.stop(
            .replace, committed: "teh cat ", text: "The cat.", finalText: "The cat.", applied: nil,
            statelessPass: { _ in passes += 1; return "x" }, copy: { copied.append($0); return true })
        #expect(stop == .init(landed: false, cleaned: nil))
        #expect(passes == 0 && copied.isEmpty)
    }

    /// The keyboard restarted after the agent's final edit went out: the mirror no longer knows the run's spans,
    /// so the edit cannot be placed in a fallback text. The whole text cleaned by the stateless pass is copied
    /// instead, never nothing.
    @Test func unknownSpansFallBackToTheWholeCleanedText() async {
        let keyboard = Keyboard()
        let run = run(keyboard, session: ScriptedSession([(.zero, edit(1, "I saw the dog"))]))
        run.feedChanged()
        keyboard.asr("I saw teh dog")  // unfinished: only the final pass reviews it
        run.feedChanged()
        keyboard.deaf = true  // the final edit goes nowhere, then the keyboard comes back as a new queue
        var copied: [String] = []
        let stopping = Task { @MainActor in
            await run.stop(
                .live, committed: "I saw teh dog ", text: "I saw teh dog", finalText: nil, applied: { true },
                statelessPass: { _ in "I saw the dog." }, copy: { copied.append($0); return true })
        }
        try? await Task.sleep(for: .milliseconds(100))
        keyboard.restart()
        let stop = await stopping.value
        #expect(copied == ["I saw the dog."])
        #expect(stop.landed)
    }

    /// The keyboard restarted before the stop: the agent and the mirror both lost the run's text, nothing was
    /// cleaned in the field. The stateless pass's text goes to the clipboard.
    @Test func aRestartBeforeTheStopStillCopiesTheCleanedText() async {
        let keyboard = Keyboard()
        let run = run(keyboard, session: ScriptedSession([]))
        run.feedChanged()
        keyboard.asr("I saw teh dog")
        run.feedChanged()
        keyboard.restart()
        var copied: [String] = []
        let stop = await run.stop(
            .live, committed: "I saw teh dog ", text: "I saw teh dog", finalText: nil, applied: { true },
            statelessPass: { _ in "I saw the dog." }, copy: { copied.append($0); return true })
        #expect(copied == ["I saw the dog."])
        #expect(stop.landed)
    }

    /// Replace: a cleaned text that is the raw text once trimmed changes nothing, and does not reach the clipboard
    /// (the stream is in the field).
    @Test func anUnchangedReplaceLeavesTheClipboardAlone() async {
        let keyboard = Keyboard()
        let run = LinkedCleanupRun(owner: "run", agent: nil, transport: keyboard.transport, finalWait: .milliseconds(100))
        run.feedChanged()
        keyboard.asr("teh cat")
        var copied: [String] = []
        let stop = await run.stop(
            .replace, committed: "teh cat", text: "teh cat ", finalText: "teh cat ", applied: { true },
            statelessPass: { _ in nil }, copy: { copied.append($0); return true })
        #expect(stop.landed)
        #expect(copied.isEmpty)
    }
}
