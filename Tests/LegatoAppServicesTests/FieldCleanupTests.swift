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
    init(_ text: String) { self.text = text; cursor = text.count }
    func publish(_ strip: InstructionStrip) {}
    func read(_ kind: FieldReadRequest.Kind, instructionID: String, reading: @escaping @MainActor () -> Void) async throws -> FieldReadReply {
        .init(id: instructionID, state: .done, above: String(text.prefix(cursor)), below: String(text.dropFirst(cursor)),
              stop: .start, stopBelow: .start, documentID: "field")
    }
    func apply(_ edit: ScopedEdit) async -> ScopedEditAck? {
        edits.append(edit)
        guard edit.scopeText == text else { return .init(id: edit.id, applied: false) }
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
