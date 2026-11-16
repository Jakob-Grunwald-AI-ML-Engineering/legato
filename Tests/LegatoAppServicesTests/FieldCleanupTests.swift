import Foundation
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
        let output = await FieldCleanupChunks.clean(source) { input in inputs.append(input); return input }
        #expect(output == source)
        #expect(inputs.count == 3)
        #expect(inputs[1].contains("word59"))
    }

    @Test func overlappingResultReplacesEarlierWordsWithoutDuplicatingThem() async {
        let source = (0..<100).map { "word\($0)" }.joined(separator: " ")
        var call = 0
        let output = await FieldCleanupChunks.clean(source) { input in
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
        session.clean = { input, _ in
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
        session.clean = { text, _ in
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
        session.clean = { _, _ in field.text = ""; field.cursor = 0; return "the boat." }
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
        session.clean = { _, _ in
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
        session.clean = { _, _ in "the boat." }
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
        session.clean = { _, _ in session.reset(); return "the boat" }
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

    @Test func missingFinalDeliveryTimesOutWithoutReadingOrEditingTheOldScope() async {
        let clock = VirtualClock()
        let field = CleanupField("teh old boat.")
        let pipeline = DictationPipeline(cleaner: FieldCleaner(), clock: clock, supportsLive: true)
        pipeline.attachCleanupField(field, duringPauses: true, waitsForLiveDelivery: true)
        pipeline.beginTake()
        await pipeline.receive(.init(sequence: 0, text: "teh green boat.", words: [], reason: "endpoint"))
        let finishing = Task { await pipeline.finishTake() }
        await awaitCleanupTest { clock.sleeperCount == 1 }
        clock.advance(by: .seconds(6)) // Existing liveTimeout policy; this is no field or keyboard lock.
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
            pipeline.fieldCleanup?.clean = { _, _ in reject(); return "the green boat." }
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
        session.clean = { _, _ in paused = false; answered = true; return "the boat" }
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
