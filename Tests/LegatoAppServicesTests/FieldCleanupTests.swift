import Foundation
import Synchronization
import Testing
import LegatoAgent
import LegatoCore
import LegatoKeyboardCore
@testable import LegatoAppServices

@MainActor private final class CleanupField: InstructionField {
    var text: String
    var cursor: Int
    var edits: [ScopedEdit] = []
    var reads = 0
    var complete = true
    var draftID: String?
    var beforeApply: (() -> Void)?
    init(_ text: String) { self.text = text; cursor = text.count }
    func publish(_ strip: InstructionStrip) {}
    func read(_ kind: FieldReadRequest.Kind, instructionID: String, reading: @escaping @MainActor () -> Void) async throws -> FieldReadReply {
        reads += 1
        return .init(id: instructionID, state: .done, above: String(text.prefix(cursor)), below: String(text.dropFirst(cursor)),
                     stop: complete ? .start : .unread, stopBelow: complete ? .start : .unread, documentID: "field", draftID: draftID)
    }
    func apply(_ edit: ScopedEdit) async -> ScopedEditAck? {
        beforeApply?()
        edits.append(edit)
        guard edit.draftID == draftID, edit.scopeText == text else { return .init(id: edit.id, applied: false) }
        text = edit.target; cursor = text.count
        return .init(id: edit.id, applied: true, cursor: text.utf16.count)
    }
}

private final class FieldCleaner: SentenceCleaning {
    func clean(_ input: SentenceCleanupInput) async throws -> ValidatedSentence {
        .init(sentenceID: input.sentenceID, sequence: input.sequence, text: input.text)
    }
    func cleanTake(_ input: DictationTakeInput) async throws -> String {
        #expect(input.fieldDocument)
        return input.text.replacingOccurrences(of: "teh", with: "the")
    }
}

@MainActor private func awaitCleanupTest(_ condition: @MainActor () -> Bool) async {
    let deadline = ContinuousClock.now + .seconds(5)
    while !condition(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(2)) }
    #expect(condition())
}

@Suite @MainActor struct FieldCleanupTests {
    @Test func identityChunksPreserveEveryCharacterAndOverlapDoesNotDuplicateWords() async {
        let source = "  - " + (0..<137).map { "word\($0)" }.joined(separator: " \n") + "\n"
        var inputs: [String] = []
        let output = await FieldCleanupChunks.clean(source) { input, _ in inputs.append(input); return input }
        #expect(output == source)
        #expect(inputs.count == 3)
        #expect(inputs[1].contains("word59"))
    }

    @Test func overlappingResultReplacesEarlierWordsWithoutDuplicatingThem() async {
        let source = (0..<100).map { "word\($0)" }.joined(separator: " ")
        var call = 0
        let output = await FieldCleanupChunks.clean(source) { input, _ in
            call += 1
            return call == 2 ? input.replacingOccurrences(of: "word55", with: "corrected55") : input
        }
        #expect(output == source.replacingOccurrences(of: "word55", with: "corrected55"))
    }

    @Test func successivePausesReadOnlyOverlapAndNewWordsEvenWhenTheFieldGrowsDuringCleanup() async {
        let first = (0..<60).map { "word\($0)" }.joined(separator: " ")
        let added = (60..<108).map { "word\($0)" }.joined(separator: " ")
        let field = CleanupField(first)
        let session = FieldCleanupSession()
        session.field = field
        var inputs: [String] = []
        session.clean = { input, _, _, _ in
            inputs.append(input)
            if inputs.count == 1 {
                field.text = "Heading\n" + first + " " + added
                field.cursor = field.text.count
            }
            return input
        }
        session.request()
        await session.settle()
        session.request()
        await session.settle()
        #expect(inputs.count == 2)
        #expect(inputs[0] == first)
        #expect(inputs[1] == (48..<108).map { "word\($0)" }.joined(separator: " "))
        session.request(final: true)
        await session.settle()
        #expect(inputs.last == field.text, "Stop deliberately reads the whole field again")
    }

    @Test func userChangedWordWinsAndUntouchedCorrectionStillLands() async throws {
        let field = CleanupField("teh red boat sails")
        let session = FieldCleanupSession()
        session.field = field
        session.clean = { text, _, _, _ in
            field.text = "teh blue boat sails"; field.cursor = field.text.count
            return "the red boat sails."
        }
        session.request(final: true)
        await session.settle()
        #expect(field.text == "the blue boat sails.")
        #expect(session.lastApplied)
    }

    @Test func sentDraftIsNotRepopulatedByLateCleanup() async {
        let field = CleanupField("teh boat")
        let session = FieldCleanupSession()
        session.field = field
        var status: CleanupFieldStatus?
        session.clean = { _, _, _, _ in field.text = ""; field.cursor = 0; return "the boat." }
        session.onResult = { _, _, result in status = result }
        session.request(final: true)
        await session.settle()
        #expect(field.text.isEmpty)
        #expect(field.edits.isEmpty)
        #expect(status == .undelivered)
        #expect(!session.lastApplied)
    }

    @Test func newDraftWithSameDocumentAndTextRejectsOldResult() async {
        let field = CleanupField("teh boat")
        field.draftID = "sent-draft"
        let session = FieldCleanupSession()
        session.field = field
        session.clean = { _, _, _, _ in
            // Even identical text may be a new message after Send.
            field.draftID = "next-draft"
            return "the boat."
        }
        session.request(final: true)
        await session.settle()
        #expect(field.text == "teh boat")
        #expect(field.edits.isEmpty)
        #expect(!session.lastApplied)
    }

    @Test func draftChangesAfterReadAreStillRefusedAtApply() async {
        let field = CleanupField("teh boat")
        field.draftID = "first"
        let session = FieldCleanupSession()
        session.field = field
        session.clean = { _, _, _, _ in "the boat." }
        field.beforeApply = { field.draftID = "next" }
        session.request(final: true)
        await session.settle()
        #expect(field.text == "teh boat")
        #expect(field.edits.first?.draftID == "first")
        #expect(!session.lastApplied)
    }

    @Test func resetDuringProviderWorkCannotWriteOrReportIntoNextTake() async {
        let field = CleanupField("teh boat")
        let session = FieldCleanupSession()
        session.field = field
        var results = 0
        session.clean = { _, _, _, _ in session.reset(); return "the boat" }
        session.onResult = { _, _, _ in results += 1 }
        session.request(final: true)
        await session.settle()
        #expect(field.text == "teh boat")
        #expect(field.edits.isEmpty)
        #expect(results == 0)
    }

    @Test func bufferedTakeCleansPendingWordsWithTheActualField() async {
        let field = CleanupField("Shopping:\n- ")
        let pipeline = DictationPipeline(cleaner: FieldCleaner(), sendMode: { .onStop })
        pipeline.attachCleanupField(field, duringPauses: false)
        await pipeline.receive(.init(sequence: 0, text: "teh milk", words: [], reason: "endpoint"))
        await pipeline.finishTake()
        #expect(field.text == "Shopping:\n- the milk")
        #expect(pipeline.outbox.isEmpty)
        #expect(pipeline.takePhase == .buffering)
        #expect(pipeline.fieldCleanupOutcome?.status == .cleaned, "Presentation receives the confirmed outcome even without a History store")
    }

    @Test func finalCleanupReadsOnlyAfterTheExactRawVersionLands() async throws {
        let clock = VirtualClock()
        let field = CleanupField("teh old boat.")
        field.complete = false // Like an iOS queue snapshot: changed bounded scopes cannot be merged safely.
        let pipeline = DictationPipeline(cleaner: FieldCleaner(), clock: clock, supportsLive: true)
        pipeline.attachCleanupField(field, duringPauses: true, waitsForLiveDelivery: true)
        pipeline.beginTake()
        await pipeline.receive(.init(sequence: 0, text: "teh green boat.", words: [], reason: "endpoint"))
        let finishing = Task { await pipeline.finishTake() }
        await awaitCleanupTest { pipeline.liveRun?.complete == true && clock.sleeperCount == 1 }
        let snapshot = try #require(pipeline.liveRun?.snapshot)
        #expect(field.reads == 0)
        // A stale complete version, another run, or a partial acknowledgement cannot release cleanup.
        for ack in [
            LiveDictationAck(runID: snapshot.runID, version: snapshot.version - 1, complete: true, stats: .init(), delivered: true),
            .init(runID: "other-run", version: snapshot.version, complete: true, stats: .init(), delivered: true),
            .init(runID: snapshot.runID, version: snapshot.version, complete: false, stats: .init(), delivered: true)
        ] {
            let arms = clock.armCount
            pipeline.acknowledgeDelivery(ack)
            clock.advance(by: .milliseconds(20))
            await awaitCleanupTest { clock.armCount > arms && clock.sleeperCount == 1 }
            #expect(field.reads == 0)
        }
        // A valid slow delivery outlives the provider's six-second timeout without admitting an early read.
        let arms = clock.armCount
        clock.advance(by: .seconds(6))
        await awaitCleanupTest { clock.armCount > arms && clock.sleeperCount == 1 }
        #expect(field.reads == 0)
        field.text = "teh green boat."; field.cursor = field.text.count
        pipeline.acknowledgeDelivery(.init(runID: snapshot.runID, version: snapshot.version, complete: true, stats: .init(), delivered: true))
        // Statistics-only updates, including older adapters, cannot erase positive delivery evidence.
        pipeline.acknowledgeDelivery(.init(runID: snapshot.runID, version: nil, complete: true, stats: .init()))
        pipeline.acknowledgeDelivery(.init(runID: snapshot.runID, version: snapshot.version, complete: true, stats: .init()))
        clock.advance(by: .milliseconds(20))
        await finishing.value
        #expect(field.reads == 2)
        #expect(field.text == "the green boat.")
        #expect(pipeline.fieldCleanupOutcome?.status == .cleaned)
    }

    /// iPhone (#299): a sentence is cleaned when it ends, not only at the stop, and lands in the next gap between words.
    @Test(arguments: [false, true])
    func aSentenceIsCleanedWhenItEndsAndLandsInTheNextGap(perSentence: Bool) async {
        let sentence = "teh boat waits near the harbour today."
        let field = CleanupField(sentence)
        let pipeline = DictationPipeline(cleaner: FieldCleaner(), supportsLive: true)
        pipeline.attachCleanupField(field, duringPauses: true, waitsForLiveDelivery: true, perSentence: perSentence)
        pipeline.beginTake()
        await pipeline.receive(.init(sequence: 0, text: sentence, words: [], reason: "endpoint"))
        if perSentence {
            // Cleaned while the take runs: the result waits while speech goes on.
            await awaitCleanupTest { field.reads == 1 }
            #expect(field.edits.isEmpty)
            pipeline.boundary("endpoint")
            await awaitCleanupTest { field.text == "the boat waits near the harbour today." }
            #expect(field.edits.count == 1)
        } else {
            try? await Task.sleep(for: .milliseconds(50))
            #expect(field.reads == 0, "a short sentence waits for a full passage or the stop")
        }
    }

    /// iPhone (#299 device run): the read is the keyboard's shadow (bounded), and speech goes on while the model works.
    /// The sentence's result still lands in the gap, the words typed meanwhile stay, and the pass is logged.
    @Test func aSentenceLandsAroundSpeechTypedDuringItsCleanupInABoundedField() async {
        let field = CleanupField("Earlier text. teh boat waits near the harbour today.")
        field.complete = false
        let pipeline = DictationPipeline(cleaner: FieldCleaner(), supportsLive: true)
        pipeline.attachCleanupField(field, duringPauses: true, waitsForLiveDelivery: true, perSentence: true)
        var events: [[String: Any]] = []
        pipeline.diagnostics = { event, fields in if event == "field.cleanup" { events.append(fields) } }
        pipeline.beginTake()
        await pipeline.receive(.init(sequence: 0, text: "teh boat waits near the harbour today.", words: [], reason: "endpoint"))
        await awaitCleanupTest { field.reads == 1 }
        // The next sentence's words go in while the model works and before the gap.
        field.text += " And then"; field.cursor = field.text.count
        pipeline.boundary("endpoint")
        await awaitCleanupTest { field.text == "Earlier text. the boat waits near the harbour today. And then" }
        let landed = events.first { $0["status"] as? String == "cleaned" }
        #expect(landed?["sentence"] as? Bool == true)
        #expect(landed?["moved"] as? Bool == true)
        #expect(landed?["modelMs"] is Int)
    }

    @Test func aCleanupTheModelRefusedIsKeptAsTypedAndSaysWhy() async {
        let field = CleanupField("teh boat waits near the harbour today.")
        field.complete = false
        let session = FieldCleanupSession()
        session.field = field
        var events: [[String: Any]] = []
        var status: CleanupFieldStatus?
        session.diagnostics = { _, fields in events.append(fields) }
        session.onResult = { _, _, result in status = result }
        session.clean = { _, _, _, _ in session.cleanFailure = "rejected"; return nil }
        session.request(final: true)
        await session.settle()
        #expect(status == .keptAsTyped)
        #expect(events.last?["status"] as? String == "modelFailed")
        #expect(events.last?["reason"] as? String == "rejected")
        #expect(field.edits.isEmpty)
    }

    // MARK: A sentence's pass (#299 recheck: "We meet At the", "and Then walk over")

    /// The pass for a sentence that just ended cleans whole sentences only: its passage starts where the sentence the
    /// uncovered text begins in starts (never inside a sentence, which a model capitalises) and ends with the last
    /// finished sentence. The words after it, a sentence still being said, are neither sent nor edited.
    @Test func aSentencePassEditsNoWordBeyondTheFinishedSentence() async {
        let field = CleanupField("The review is moved to Wednesday. We meet at the Bahnhof so um sechs Uhr. and then walk")
        field.complete = false
        let session = FieldCleanupSession()
        session.field = field
        var calls: [(passage: String, before: String)] = []
        session.clean = { passage, _, before, _ in
            calls.append((passage, before))
            // A model that capitalises whatever it is given first, and punctuates.
            return passage.prefix(1).uppercased() + passage.dropFirst().replacingOccurrences(of: "Bahnhof so", with: "Bahnhof, so")
        }
        session.request(sentence: true)
        await session.settle()
        #expect(calls.map(\.passage) == ["The review is moved to Wednesday. We meet at the Bahnhof so um sechs Uhr."])
        #expect(field.text == "The review is moved to Wednesday. We meet at the Bahnhof, so um sechs Uhr. and then walk",
                "the unfinished sentence after it stays as typed")
    }

    /// Once part of the field is covered, the next sentence's passage goes back to the start of the sentence its uncovered
    /// words begin in, with the text before it as context: never from the middle of a sentence.
    @Test func aLaterSentencePassStartsAtASentenceStartWithTheTextBeforeAsContext() async {
        let first = "The review is moved to Wednesday and we meet at the station near the old harbour at six in the evening."
        let field = CleanupField(first)
        field.complete = false
        let session = FieldCleanupSession()
        session.field = field
        var calls: [(passage: String, before: String)] = []
        session.clean = { passage, _, before, _ in
            calls.append((passage, before))
            return passage.prefix(1).uppercased() + passage.dropFirst()
        }
        session.request(sentence: true)
        await session.settle()
        field.text = first + " Then we walk over together."
        field.cursor = field.text.count
        session.request(sentence: true)
        await session.settle()
        #expect(calls.count == 2)
        // The overlap reaches back into the first sentence: the passage holds that whole sentence.
        #expect(calls.last?.passage == field.text)
        #expect(field.text == first + " Then we walk over together.", "nothing in the middle of a sentence was capitalised")
        // A pass with no finished sentence after what is covered sends nothing and says so.
        var events: [[String: Any]] = []
        session.diagnostics = { _, fields in events.append(fields) }
        field.text += " and then"
        field.cursor = field.text.count
        session.request(sentence: true)
        await session.settle()
        #expect(calls.count == 2)
        #expect(events.last?["status"] as? String == "noSentence")
    }

    /// The stop's pass settles the whole take: after sentence passes covered part of a bounded read, it still sends all of
    /// it, so a correction spanning two sentences ("Tuesday." … "Uh, no sorry, Wednesday.") can be applied.
    @Test func theFinalPassCleansTheWholeTakeAfterSentencePasses() async {
        let field = CleanupField("The review is moved to Tuesday. Uh, no sorry, Wednesday.")
        field.complete = false
        let session = FieldCleanupSession()
        session.field = field
        var calls: [(passage: String, final: Bool)] = []
        session.clean = { passage, final, _, _ in
            calls.append((passage, final))
            return final ? "The review is moved to Wednesday." : passage
        }
        session.request(sentence: true)
        await session.settle()
        field.text += " We meet at six."
        field.cursor = field.text.count
        session.request(sentence: true)
        session.request(final: true)
        await session.settle()
        #expect(calls.last?.final == true)
        #expect(calls.last?.passage == "The review is moved to Tuesday. Uh, no sorry, Wednesday. We meet at six.")
        #expect(field.text == "The review is moved to Wednesday.")
    }

    /// An Enter the user pressed while speaking stands between dictated words; a cleanup that joined the lines (WhatsApp,
    /// #299 recheck: "to⏎Anna," became "to Anna,") gets the break back, and its other changes still land.
    @Test func aLineBreakInTheFieldSurvivesACleanupThatJoinedTheLines() {
        let passage = "Please send the draft to\nAnna, cc Lina. um and bring the slides."
        let cleaned = "Please send the draft to Anna, cc Lina. And bring the slides."
        #expect(FieldCleanupChunks.keepingLineBreaks(of: passage, in: cleaned) == "Please send the draft to\nAnna, cc Lina. And bring the slides.")
        // A break the result adds stays; no break in the passage, nothing to keep.
        #expect(FieldCleanupChunks.keepingLineBreaks(of: "a. b.", in: "A.\n\nB.") == "A.\n\nB.")
    }

    /// A passage cleaned in halves after a rejection gives each half what stands before it, so the second half is never
    /// read as a text of its own.
    @Test func aSplitPassagesSecondHalfHasTheFirstAsContext() async {
        let source = "Um, the review moved to Tuesday. We meet so um sechs Uhr there."
        var calls: [(String, String)] = []
        _ = await FieldCleanupChunks.cleanSplitting(source, before: "Hi Anna. ") { text, before in
            calls.append((text, before))
            if calls.count == 1 { return .rejected }
            return .cleaned(text.replacingOccurrences(of: "Um, t", with: "T"))
        }
        #expect(calls.count == 3)
        #expect(calls[1].1 == "Hi Anna. ")
        #expect(calls[2].1 == "Hi Anna. The review moved to Tuesday.")
    }

    /// A pass whose edit the field did not take says why (`why`): it could not be placed, it stopped, or was refused.
    @Test func aPassTheFieldDidNotTakeSaysWhy() async {
        let field = CleanupField("teh boat waits.")
        field.beforeApply = { field.draftID = "another" }
        let session = FieldCleanupSession()
        session.field = field
        var events: [[String: Any]] = []
        session.diagnostics = { _, fields in events.append(fields) }
        session.clean = { passage, _, _, _ in passage.replacingOccurrences(of: "teh", with: "The") }
        session.request(final: true)
        await session.settle()
        #expect(events.last?["applied"] as? Bool == false)
        #expect(events.last?["why"] as? String == "refused")
    }

    @Test func aRejectedTakeKeepsOnlyTheRefusedSentenceRaw() async {
        let source = "Um, the review moved to Tuesday. We meet so um sechs Uhr there. Uh, bring the slides."
        var calls: [String] = []
        let split = await FieldCleanupChunks.cleanSplitting(source) { text, _ in
            calls.append(text)
            if text.contains("um sechs") { return .rejected }
            return .cleaned(text.replacingOccurrences(of: "Um, t", with: "T").replacingOccurrences(of: "Uh, b", with: "B"))
        }
        #expect(split.result == .cleaned("The review moved to Tuesday. We meet so um sechs Uhr there. Bring the slides."))
        #expect(split.keptRaw == 1)
        #expect(split.calls == calls.count)
        let failed = await FieldCleanupChunks.cleanSplitting(source) { _, _ in .failed("timeout") }
        #expect(failed.result == .failed("timeout") && failed.calls == 1, "a timeout is not split")
        let single = await FieldCleanupChunks.cleanSplitting("We meet so um sechs Uhr.") { _, _ in .rejected }
        #expect(single.result == .rejected)
    }

    @Test func missingFinalDeliveryTimesOutWithoutReadingOrEditingTheOldScope() async {
        let clock = VirtualClock()
        let field = CleanupField("teh old boat.")
        let pipeline = DictationPipeline(cleaner: FieldCleaner(), clock: clock, supportsLive: true)
        pipeline.attachCleanupField(field, duringPauses: true, waitsForLiveDelivery: true)
        pipeline.beginTake()
        await pipeline.receive(.init(sequence: 0, text: "teh green boat.", words: [], reason: "endpoint"))
        let finishing = Task { await pipeline.finishTake() }
        await awaitCleanupTest { clock.sleeperCount == 1 }
        let characters = "teh green boat.".count
        clock.advance(by: .milliseconds(FieldQueue.budgetMs(sourceCharacters: characters, targetCharacters: characters)))
        await finishing.value
        #expect(field.reads == 0)
        #expect(field.edits.isEmpty)
        #expect(field.text == "teh old boat.")
        #expect(pipeline.fieldCleanupOutcome?.status == .undelivered)
    }

    @Test func resetCancelsTheFinalDeliveryWaitWithoutReportingIntoTheNextTake() async {
        let clock = VirtualClock()
        let field = CleanupField("teh old boat.")
        let pipeline = DictationPipeline(cleaner: FieldCleaner(), clock: clock, supportsLive: true)
        pipeline.attachCleanupField(field, duringPauses: true, waitsForLiveDelivery: true)
        pipeline.beginTake()
        await pipeline.receive(.init(sequence: 0, text: "teh green boat.", words: [], reason: "endpoint"))
        let finishing = Task { await pipeline.finishTake() }
        await awaitCleanupTest { clock.sleeperCount == 1 }
        await pipeline.reset()
        await finishing.value
        #expect(clock.sleeperCount == 0)
        #expect(field.reads == 0)
        #expect(field.edits.isEmpty)
        #expect(pipeline.fieldCleanupOutcome == nil)
    }

    @Test(arguments: [false, true])
    func terminalReceiptNeverReadsOrCleansTheSuccessorDraft(afterModel: Bool) async throws {
        let clock = VirtualClock()
        let field = CleanupField("teh green boat.")
        let historyURL = FileManager.default.temporaryDirectory.appending(path: "legato-delivery-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: historyURL) }
        let history = JSONLHistoryStore(fileURL: historyURL)
        let pipeline = DictationPipeline(history: history, cleaner: FieldCleaner(), clock: clock,
                                        supportsLive: true, groupsLiveHistory: true)
        pipeline.attachCleanupField(field, duringPauses: true, waitsForLiveDelivery: true)
        pipeline.beginTake()
        await pipeline.receive(.init(sequence: 0, text: "teh green boat.", words: [], reason: "endpoint"))
        let finishing = Task { await pipeline.finishTake() }
        await awaitCleanupTest { pipeline.liveRun?.complete == true && clock.sleeperCount == 1 }
        let snapshot = try #require(pipeline.liveRun?.snapshot)
        let reject = {
            field.text = "next draft"; field.cursor = field.text.count; field.draftID = "next"
            pipeline.acknowledgeDelivery(.init(runID: snapshot.runID, version: snapshot.version, complete: true,
                                               stats: .init(), delivered: false))
        }
        if afterModel {
            pipeline.fieldCleanup?.clean = { _, _, _, _ in reject(); return "the green boat." }
            pipeline.acknowledgeDelivery(.init(runID: snapshot.runID, version: snapshot.version, complete: true,
                                               stats: .init(), delivered: true))
        } else { reject() }
        clock.advance(by: .milliseconds(20))
        await finishing.value
        await pipeline.settleHistory()
        #expect(field.reads == (afterModel ? 1 : 0))
        #expect(field.edits.isEmpty)
        #expect(field.text == "next draft")
        #expect(pipeline.fieldCleanupOutcome?.status == .undelivered)
        let saved = try #require(try await JSONLHistoryStore(fileURL: historyURL).recent(limit: 1).first)
        #expect(saved.rawText == "teh green boat.")
        #expect(saved.text == "teh green boat.")
        #expect(saved.cleanupFieldStatus == .undelivered)
        #expect(saved.cleanupResultText == nil)
    }

    @Test func modelResultWaitsWhenSpeechResumes() async {
        let field = CleanupField("teh boat")
        let session = FieldCleanupSession()
        session.field = field
        var paused = true
        var answered = false
        session.canApply = { paused }
        session.clean = { _, _, _, _ in paused = false; answered = true; return "the boat" }
        session.request(final: true)
        while !answered { await Task.yield() }
        #expect(field.edits.isEmpty)
        paused = true
        await session.settle()
        #expect(field.text == "the boat")
    }

    @Test func semanticPauseNeverConsumesAMagicModeCut() {
        let pipeline = DictationPipeline(cleaner: FieldCleaner())
        let sink = SpeechModeSink(dictation: pipeline)
        sink.toggle(to: .instruction, cut: true)
        sink.boundary("endpoint")
        #expect(sink.mode == .dictation)
        sink.boundary("finalize")
        #expect(sink.mode == .instruction)
    }

    @Test func quietAudioNeedsAFreshEndpointAndActivityRevokesIt() {
        var gate = DictationActivity()
        let quiet = Data(repeating: 0, count: 6400)
        let withoutAudio = gate.boundary("endpoint")
        #expect(!withoutAudio)
        gate.receive(quiet)
        #expect(gate.state == .speaking)
        let gap = gate.boundary("gap")
        #expect(!gap)
        let endpoint = gate.boundary("endpoint")
        #expect(endpoint)
        #expect(gate.state == .paused)
        let loud = Data((0..<320).flatMap { _ in [UInt8(0), UInt8(64)] })
        let activity = gate.receive(loud)
        #expect(activity)
        #expect(gate.state == .speaking)
        gate.receive(quiet)
        #expect(gate.state == .speaking)
        let nextEndpoint = gate.boundary("endpoint")
        #expect(nextEndpoint)
    }
}

/// A field that cannot place an edit (the keyboard's queue dropped it as unplaceable), having lost one character to it.
@MainActor private final class UnplaceableField: InstructionField {
    var text: String
    var refusals: Int
    var applied: [ScopedEdit] = []
    init(_ text: String, refusals: Int) { self.text = text; self.refusals = refusals }
    func publish(_ strip: InstructionStrip) {}
    func read(_ kind: FieldReadRequest.Kind, instructionID: String, reading: @escaping @MainActor () -> Void) async throws -> FieldReadReply {
        .init(id: instructionID, state: .done, above: text, below: "", stop: .start, stopBelow: .start, documentID: "field")
    }
    func apply(_ edit: ScopedEdit) async -> ScopedEditAck? {
        guard refusals == 0 else {
            refusals -= 1
            text = text.replacingOccurrences(of: "bread", with: "read")
            return .init(id: edit.id, applied: false, unplaceable: true)
        }
        guard edit.scopeText == text else { return .init(id: edit.id, applied: false) }
        applied.append(edit); text = edit.target
        return .init(id: edit.id, applied: true, cursor: text.utf16.count)
    }
}

@Suite @MainActor struct FieldCleanupRepassTests {
    private func session(_ field: UnplaceableField, inputs: @escaping @MainActor (String) -> Void) -> FieldCleanupSession {
        let session = FieldCleanupSession()
        session.field = field
        session.clean = { text, _, _, _ in
            inputs(text)
            return text.replacingOccurrences(of: " read", with: " bread").replacingOccurrences(of: "teh", with: "the")
        }
        return session
    }

    @Test func anUnplaceableCleanupEditGetsOnePassMoreOnTheFieldAsItIsReadThen() async {
        let field = UnplaceableField("We bring teh bread", refusals: 1)
        var inputs: [String] = []
        let session = session(field) { inputs.append($0) }
        session.request(final: true)
        await session.settle()
        #expect(inputs == ["We bring teh bread", "We bring teh read"], "The second pass cleans what the field holds now")
        #expect(field.text == "We bring the bread")
        #expect(session.lastApplied)
    }

    @Test func aPausePassThatCouldNotBePlacedIsRepeatedToo() async {
        let words = (0..<60).map { "word\($0)" }.joined(separator: " ")
        let field = UnplaceableField(words + " teh bread", refusals: 1)
        var inputs: [String] = []
        let session = session(field) { inputs.append($0) }
        session.request()
        await session.settle()
        #expect(inputs.count == 2)
        #expect(field.text == words + " the bread")
    }

    @Test func theAutomaticPassIsNeverFollowedByAnother() async {
        let field = UnplaceableField("We bring teh bread", refusals: 5)
        var inputs: [String] = []
        let session = session(field) { inputs.append($0) }
        session.request(final: true)
        await session.settle()
        #expect(inputs.count == 2)
        #expect(field.applied.isEmpty && !session.lastApplied)
        // The stop's pass (or the next pause's) still runs as before, with one more pass of its own at most.
        session.request(final: true)
        await session.settle()
        #expect(inputs.count == 4)
    }

    @Test func anEditRefusedForAnotherReasonAsksForNoPass() async {
        @MainActor final class Refusing: InstructionField {
            func publish(_ strip: InstructionStrip) {}
            func read(_ kind: FieldReadRequest.Kind, instructionID: String, reading: @escaping @MainActor () -> Void) async throws -> FieldReadReply {
                .init(id: instructionID, state: .done, above: "We bring teh bread", below: "", stop: .start, stopBelow: .start, documentID: "field")
            }
            func apply(_ edit: ScopedEdit) async -> ScopedEditAck? { .init(id: edit.id, applied: false, reason: "The text changed.") }
        }
        let field = Refusing(), session = FieldCleanupSession()
        session.field = field
        var passes = 0
        session.clean = { _, _, _, _ in passes += 1; return "We bring the bread" }
        session.request(final: true)
        await session.settle()
        #expect(passes == 1)
    }
}

/// #299 round 4: on iPhone a pass starts from the keyboard's shadow of the field (`FieldShadow`), sent with no read, and
/// its edit goes without a re-read (the keyboard places it through every change since and merges around them).
@Suite @MainActor struct ShadowCleanupPassTests {
    private func shadowed(_ field: CleanupField, takeStart: Int? = nil, asks: @escaping @MainActor () -> Void = {}) -> FieldCleanupSession {
        let session = FieldCleanupSession()
        session.field = field
        session.shadow = { id in
            asks()
            return FieldShadow(id: id, runID: "r", above: String(field.text.prefix(field.cursor)), below: String(field.text.dropFirst(field.cursor)),
                               takeStart: takeStart, documentID: "field", draftID: field.draftID)
        }
        return session
    }

    @Test func aPassFromTheShadowReadsNothingAndAppliesAtOnce() async throws {
        let field = CleanupField("teh boat sails. we meet at six.")
        let session = shadowed(field)
        var lines: [[String: Any]] = []
        session.diagnostics = { event, fields in if event == "field.cleanup" { lines.append(fields) } }
        session.clean = { passage, _, _, _ in passage.replacingOccurrences(of: "teh", with: "The").replacingOccurrences(of: "we", with: "We") }
        session.request(sentence: true)
        await session.settle()
        #expect(field.reads == 0, "no read before the model, no re-read after it")
        #expect(field.edits.count == 1)
        #expect(field.edits.first?.before == "teh boat sails. we meet at six.")
        #expect(field.text == "The boat sails. We meet at six.")
        #expect(session.lastApplied)
        let line = try #require(lines.last)
        #expect(line["status"] as? String == "cleaned")
        for phase in ["shadowSentMs", "shadowMs", "modelStartMs", "modelEndMs", "applySentMs", "confirmedMs"] {
            #expect(line[phase] is Int, "\(phase) is logged")
        }
    }

    /// The keyboard could not place the edit (the field changed in a way no merge explains): it drops, and one fresh pass
    /// starts from a new shadow.
    @Test func anEditTheKeyboardCannotPlaceRunsOneFreshPass() async {
        let field = CleanupField("teh boat sails.")
        var asks = 0
        let session = shadowed(field) { asks += 1 }
        session.clean = { passage, _, _, _ in
            // The first result comes back to a field that changed meanwhile (the stub field takes only an exact match).
            if asks == 1 { field.text = "teh boat sails today."; field.cursor = field.text.count }
            return passage.replacingOccurrences(of: "teh", with: "The")
        }
        session.request(final: true)
        await session.settle()
        #expect(asks == 2)
        #expect(field.edits.count == 2)
        #expect(field.text == "The boat sails today.")
    }

    /// The pass at stop covers the whole take (from its start in the field, not the text before it) and gets the take's
    /// raw words: sentence passes tidied "Uh, no sorry," away, the raw words still show the correction.
    @Test func theWholeTakePassGetsTheRawWordsAndResolvesACorrectionAcrossSentences() async {
        let field = CleanupField("Hi Anna, see below. The review is moved to Tuesday. Wednesday.")
        let session = shadowed(field, takeStart: "Hi Anna, see below. ".count)
        let raw = "the review is moved to tuesday uh no sorry wednesday"
        session.rawWords = { raw }
        var calls: [(passage: String, whole: Bool, before: String, raw: String?)] = []
        session.clean = { passage, whole, before, rawWords in
            calls.append((passage, whole, before, rawWords))
            // A stub model: the raw words show the correction the text no longer shows.
            guard rawWords?.contains("no sorry") == true else { return passage }
            return passage.replacingOccurrences(of: "Tuesday. Wednesday.", with: "Wednesday.")
        }
        session.request(final: true)
        await session.settle()
        #expect(calls.count == 1)
        #expect(calls.first?.whole == true)
        #expect(calls.first?.passage == "The review is moved to Tuesday. Wednesday.")
        #expect(calls.first?.before == "Hi Anna, see below. ")
        #expect(calls.first?.raw == raw)
        #expect(field.text == "Hi Anna, see below. The review is moved to Wednesday.")
        // A sentence's pass gets no raw words.
        field.text += " Bring teh slides."; field.cursor = field.text.count
        session.request(sentence: true)
        await session.settle()
        #expect(calls.last?.whole == false && calls.last?.raw == nil)
    }

    /// Device run 4 (Notes, 2026-11-17): the whole-take pass ran to the end of the shadow, whose text after the caret was
    /// the field's ". " in front of the next sentence. The model trims its answer, so the edit took the space out and
    /// glued that sentence on (". I think" became ".I think"). The passage's own leading and trailing whitespace stays.
    @Test func theWholePassKeepsThePassagesTrailingSeparator() async {
        let field = CleanupField("Done by late afternoon. Then it is coffee and cake on the terrace. ")
        field.cursor = "Done by late afternoon. Then it is coffee and cake on the terrace".count
        let session = shadowed(field, takeStart: "Done by late afternoon. ".count)
        session.rawWords = { "then it is coffee and cake on the terrace" }
        session.clean = { passage, _, _, _ in passage.trimmingCharacters(in: .whitespacesAndNewlines) }
        var lines: [[String: Any]] = []
        session.diagnostics = { event, fields in if event == "field.cleanup" { lines.append(fields) } }
        session.request(final: true)
        await session.settle()
        #expect(field.text == "Done by late afternoon. Then it is coffee and cake on the terrace. ")
        #expect(field.edits.isEmpty, "nothing to change")
        #expect(lines.last?["why"] as? String == "cleanAsTyped")
    }

    /// Device run 4: the guard refused the sentence with a German "um" before a time, and every later sentence pass sent it
    /// again (its overlap reaches back into it), was refused again and split into several calls: 4–6 s a pass. A refused
    /// sentence that would open a sentence pass stands before it as context instead.
    @Test func aSentenceTheGuardRefusedIsNotSentAgainAtTheNextPassesStart() async {
        let refused = "We meet at the Bahnhof so um sechs Uhr and then walk over together."
        let field = CleanupField("The review moved to Wednesday. " + refused)
        let session = shadowed(field)
        var calls: [(passage: String, before: String)] = []
        session.clean = { [weak session] passage, _, before, _ in
            calls.append((passage, before))
            // The guard refuses the "um" sentence: it stays as typed (the pipeline's split reports it).
            if passage.contains("um sechs") { session?.refusedSentences.insert(refused) }
            return passage
        }
        session.request(sentence: true)
        await session.settle()
        field.text += " Please send the draft to Anna, cc Lina. Actually, no, cc Tom."; field.cursor = field.text.count
        session.request(sentence: true)
        await session.settle()
        #expect(calls.count == 2)
        #expect(calls.last?.passage == "Please send the draft to Anna, cc Lina. Actually, no, cc Tom.")
        #expect(calls.last?.before == "The review moved to Wednesday. " + refused + " ")
    }

    /// A long pause runs the whole-take pass too, once per change of the take.
    @Test func aLongPausesWholePassRunsOncePerChange() async {
        let field = CleanupField("The review is moved to Tuesday. Wednesday.")
        let session = shadowed(field, takeStart: 0)
        session.rawWords = { "the review is moved to tuesday uh no sorry wednesday" }
        var calls = 0
        session.clean = { passage, whole, _, raw in
            calls += 1
            #expect(whole && raw != nil)
            return passage
        }
        session.request(whole: true)
        await session.settle()
        session.request(whole: true)
        await session.settle()
        #expect(calls == 1, "the same take is not cleaned whole again")
    }
}

private final class RawCapturingCleaner: SentenceCleaning {
    let inputs = Mutex<[DictationTakeInput]>([])
    func clean(_ input: SentenceCleanupInput) async throws -> ValidatedSentence {
        .init(sentenceID: input.sentenceID, sequence: input.sequence, text: input.text)
    }
    func cleanTake(_ input: DictationTakeInput) async throws -> String {
        inputs.withLock { $0.append(input) }
        return input.text.replacingOccurrences(of: "teh", with: "the")
    }
}

@Suite @MainActor struct ShadowPipelineTests {
    /// The pipeline asks the keyboard for its shadow with the run's next snapshot and waits for it (no read); a long pause
    /// runs the whole-take pass with the take's raw words.
    @Test func aSentencePassAsksTheShadowAndALongPauseCleansTheWholeTake() async throws {
        let clock = VirtualClock()
        let field = CleanupField("")
        let cleaner = RawCapturingCleaner()
        let pipeline = DictationPipeline(cleaner: cleaner, clock: clock, supportsLive: true)
        pipeline.attachCleanupField(field, duringPauses: true, waitsForLiveDelivery: true, perSentence: true)
        var asked: [String] = []
        // The keyboard: types each snapshot, and answers an ask from its shadow.
        pipeline.onLiveChange = { snapshot in
            guard let snapshot else { return }
            field.text = snapshot.text; field.cursor = field.text.count
            if let ask = snapshot.shadowAsk, !asked.contains(ask) { asked.append(ask) }
        }
        pipeline.takeFieldShadow = { id in
            asked.contains(id) ? FieldShadow(id: id, runID: "r", above: field.text, documentID: "field") : nil
        }
        pipeline.beginTake()
        await pipeline.receive(.init(sequence: 0, text: "teh green boat sails out today.", words: [], reason: "endpoint"))
        // The sentence's result waits for a gap between words: the endpoint brings it (and arms the long pause).
        await awaitCleanupTest { asked.count == 1 }
        pipeline.boundary("endpoint")
        await awaitCleanupTest { field.edits.count == 1 }
        #expect(asked.count >= 1, "the sentence's pass asked for the shadow")
        #expect(field.reads == 0)
        #expect(field.edits.last?.target == "the green boat sails out today.")
        let sentenceInput = try #require(cleaner.inputs.withLock { $0 }.last)
        #expect(sentenceInput.rawWords == nil)
        // A pause long enough: the whole take, with its raw words.
        await pipeline.fieldCleanup?.settle()
        await awaitCleanupTest { clock.sleeperCount >= 1 }
        clock.advance(by: DictationPipeline.wholeTakePause)
        await awaitCleanupTest { cleaner.inputs.withLock { $0 }.contains { $0.rawWords != nil } }
        await pipeline.fieldCleanup?.settle()
        let whole = try #require(cleaner.inputs.withLock { $0 }.last { $0.rawWords != nil })
        #expect(whole.rawWords == "teh green boat sails out today.")
        #expect(field.reads == 0)
    }
}
