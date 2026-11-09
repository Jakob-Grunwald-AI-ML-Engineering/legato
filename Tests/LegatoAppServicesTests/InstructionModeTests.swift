import Foundation
import Testing
import LegatoAgent
import LegatoComposerDoc
import LegatoCore
import LegatoKeyboardCore
@testable import LegatoAppServices

@Suite struct SpeechModeRouterTests {
    @Test func aToggleWaitsForItsCutSoEarlierWordsKeepTheirMode() {
        var router = SpeechModeRouter()
        #expect(router.toggle(to: .instruction, cut: true).isEmpty)
        #expect(router.current == .dictation, "Words on their way were spoken before the toggle")
        #expect(router.target == .instruction)
        #expect(router.boundary() == .init(from: .dictation, to: .instruction))
        #expect(router.current == .instruction)
        #expect(router.boundary() == nil, "A boundary no toggle waits for changes nothing")
    }

    @Test func quickTogglesApplyInOrderAndWithoutAStreamAtOnce() {
        var router = SpeechModeRouter()
        router.toggle(to: .instruction, cut: true)
        router.toggle(to: .dictation, cut: true)
        #expect(router.target == .dictation && router.pending.count == 2)
        #expect(router.boundary()?.to == .instruction)
        #expect(router.boundary()?.to == .dictation)
        #expect(router.toggle(to: .instruction, cut: false) == [.init(from: .dictation, to: .instruction)])
        #expect(router.toggle(to: .instruction, cut: true).isEmpty, "Asking for the mode it is heading to does nothing")
        router.toggle(to: .dictation, cut: true)
        #expect(router.flush() == [.init(from: .instruction, to: .dictation)], "A cut that never comes is applied on timeout")
    }
}

@MainActor private final class RecordingDictation: DictationRouteSink {
    var lines: [String] = []
    var tails: [String] = []
    func receive(_ line: DictationRouteLine) async { lines.append(line.text) }
    func reset() async {}
    func tailChanged(_ text: String) { tails.append(text) }
}

@MainActor @Suite struct SpeechModeSinkTests {
    @Test func mixedSpeechIsTaggedPerSegment() async {
        let dictation = RecordingDictation()
        let sink = SpeechModeSink(dictation: dictation)
        var instruction: [String] = [], transitions: [SpeechMode] = []
        sink.onInstructionLine = { instruction.append($0.text) }
        sink.onTransition = { transitions.append($0.to) }
        func line(_ text: String) -> DictationRouteLine { .init(sequence: 0, text: text, words: [], reason: "endpoint") }

        await sink.receive(line("Dear Anna"))
        sink.toggle(to: .instruction, cut: true)
        await sink.receive(line("thanks for the call")) // spoken before the toggle, finalized by the cut
        sink.boundary("finalize")
        await sink.receive(line("make this more formal"))
        sink.tailChanged("and shorter")
        sink.toggle(to: .dictation, cut: true)
        sink.boundary("finalize")
        await sink.receive(line("See you soon"))

        #expect(dictation.lines == ["Dear Anna", "thanks for the call", "See you soon"])
        #expect(instruction == ["make this more formal"])
        #expect(transitions == [.instruction, .dictation])
        #expect(!dictation.tails.contains("and shorter"), "The instruction's live words never reach the field")
        #expect(dictation.tails.last == "", "Entering instruction mode clears the field's speaking head")
    }
}

/// The keyboard's field, in memory: answers reads from a fixed context and lands edits on a string.
@MainActor private final class FakeField: InstructionField {
    var text: String
    var reply: FieldReadReply
    var strips: [InstructionStrip] = []
    var reads: [FieldReadRequest.Kind] = []
    var edits: [ScopedEdit] = []
    var refuse = false
    /// The next edit stops partway (the field did not keep up) with the scope showing this.
    var stopWith: String?
    init(text: String, sessionLength: Int) {
        self.text = text
        reply = FieldReadReply(id: "r", state: .done, above: text, sessionLength: sessionLength, stop: .start)
    }
    func read(_ kind: FieldReadRequest.Kind, instructionID: String, reading: @escaping @MainActor () -> Void) async throws -> FieldReadReply {
        reads.append(kind)
        return reply
    }
    func apply(_ edit: ScopedEdit) async -> ScopedEditAck? {
        edits.append(edit)
        guard !refuse, text.hasSuffix(edit.before) else { return ScopedEditAck(id: edit.id, applied: false, reason: "The text changed, so nothing was edited.") }
        if let partial = stopWith {
            stopWith = nil
            text = String(text.dropLast(edit.before.count)) + partial
            return ScopedEditAck(id: edit.id, applied: false, cursor: partial.utf16.count, reason: "Stopped partway.", partial: partial, stopped: true)
        }
        text = String(text.dropLast(edit.before.count)) + edit.target
        return ScopedEditAck(id: edit.id, applied: true, cursor: edit.target.utf16.count)
    }
    func publish(_ strip: InstructionStrip) { strips.append(strip) }
}

private struct FixedRunner: InstructionRunning {
    var reply: String
    func run(instruction: String, context: InstructionContext, read: InstructionRunner.Reader) async throws -> InstructionOutcome {
        try InstructionRunner.outcome(reply: reply, context: context)
    }
}

private final class MemoryHistory: HistoryStore, @unchecked Sendable {
    var entries: [DictationEntry] = []
    func append(_ entry: DictationEntry) async throws { entries.append(entry) }
    func recent(limit: Int) async throws -> [DictationEntry] { entries }
    func delete(id: UUID) async throws { entries.removeAll { $0.id == id } }
}

@MainActor @Suite(.timeLimit(.minutes(1))) struct InstructionSessionTests {
    private func until(_ condition: () -> Bool) async throws {
        for _ in 0..<500 where !condition() { try await Task.sleep(for: .milliseconds(5)) }
        #expect(condition())
    }
    private func line(_ text: String) -> DictationRouteLine { .init(sequence: 0, text: text, words: [], reason: "endpoint") }

    @Test func releasingTheToggleRunsLandsSavesAndUndoes() async throws {
        let field = FakeField(text: "Notes\nhey can you send the file", sessionLength: 25)
        let history = MemoryHistory()
        let session = InstructionSession(runner: FixedRunner(reply: "SCOPE: session\nCould you send the file, please?"), history: history)
        session.field = field
        session.begin()
        session.hear(line("make this polite"))
        #expect(session.strip.phase == .listening && session.strip.transcript == "make this polite")
        #expect(field.edits.isEmpty, "Nothing runs while the toggle is on")
        session.end()
        try await until { session.strip.phase == .result }
        #expect(field.text == "Notes\nCould you send the file, please?")
        #expect(session.strip.canUndo && session.strip.scope == "session")
        #expect(history.entries.count == 1)
        #expect(history.entries.first?.rawText == "hey can you send the file" && history.entries.first?.engineID == "instruction")

        session.handle(InstructionIntent(action: .undo, instructionID: session.strip.instructionID))
        try await until { session.strip.phase == .undone }
        #expect(field.text == "Notes\nhey can you send the file")
        #expect(!session.strip.canUndo)
        #expect(field.strips.map(\.revision) == field.strips.map(\.revision).sorted(), "Every strip goes out with a higher revision")
    }

    @Test func nothingSaidNothingRunsAndAFailureEditsNothing() async throws {
        let field = FakeField(text: "Some text", sessionLength: 9)
        let session = InstructionSession(runner: FixedRunner(reply: "Sure, here you go"))
        session.field = field
        session.begin(); session.end()
        #expect(session.strip.phase == .idle && field.reads.isEmpty)
        session.begin(); session.hear(line("fix it")); session.end()
        try await until { session.strip.phase == .failed }
        #expect(field.edits.isEmpty && field.text == "Some text")
        #expect(session.strip.message == InstructionFailure.malformedReply.message)
    }

    @Test func deletingEverythingLandsEmptyAndUndoPutsItBack() async throws {
        let field = FakeField(text: "Notes\nhey can you send the file", sessionLength: 25)
        let session = InstructionSession(runner: FixedRunner(reply: "SCOPE: all\n"))
        session.field = field
        session.begin(); session.hear(line("delete everything")); session.end()
        try await until { session.strip.phase == .result }
        #expect(field.text == "" && session.strip.message == "Deleted the whole text.")
        session.handle(InstructionIntent(action: .undo, instructionID: session.strip.instructionID))
        try await until { session.strip.phase == .undone }
        #expect(field.text == "Notes\nhey can you send the file")
    }

    @Test func aNoOpSaysSoWithoutRetry() async throws {
        let field = FakeField(text: "Some text", sessionLength: 9)
        let session = InstructionSession(runner: FixedRunner(reply: "SCOPE: session\nSome text"))
        session.field = field
        session.begin(); session.hear(line("banana")); session.end()
        try await until { session.strip.phase == .failed }
        #expect(session.strip.message == "Nothing to change for that instruction." && session.strip.canRetry == false)
    }

    @Test func anEditThatStoppedPartwayCanStillBeUndone() async throws {
        let field = FakeField(text: "Notes\nhey can you send the file", sessionLength: 25)
        field.stopWith = "Could you send the file"
        let history = MemoryHistory()
        let session = InstructionSession(runner: FixedRunner(reply: "SCOPE: session\nCould you send the file, please?"), history: history)
        session.field = field
        session.begin(); session.hear(line("make this polite")); session.end()
        try await until { session.strip.phase == .failed }
        #expect(session.strip.canUndo && session.strip.message?.hasPrefix("Stopped partway.") == true)
        #expect(history.entries.isEmpty, "A stopped edit is not a result")
        session.handle(InstructionIntent(action: .undo, instructionID: session.strip.instructionID))
        try await until { session.strip.phase == .undone }
        #expect(field.text == "Notes\nhey can you send the file")
    }

    @Test func aFieldThatChangedRefusesTheEdit() async throws {
        let field = FakeField(text: "Draft text", sessionLength: 10)
        field.refuse = true
        let session = InstructionSession(runner: FixedRunner(reply: "SCOPE: all\nThe draft text."))
        session.field = field
        session.begin(); session.hear(line("tidy up")); session.end()
        try await until { session.strip.phase == .failed }
        #expect(session.strip.message == "The text changed, so nothing was edited.")
        #expect(!session.strip.canUndo)
    }
}

@MainActor @Suite(.timeLimit(.minutes(1))) struct InstructionFieldChannelTests {
    @Test func aReadIsAnsweredByItsIDFirstReadingThenDone() async throws {
        let store = LinkStore(MemoryLinkStore())
        let channel = InstructionFieldChannel(store: store, post: { _ in }, poll: .milliseconds(5), ackTimeout: 1, readTimeout: 2, editTimeout: 0.2)
        let keyboard = InstructionLink(store: store)
        let keyboardSide = Task { @MainActor in
            var request: FieldReadRequest?
            while request == nil { request = keyboard.takeRequest(); try? await Task.sleep(for: .milliseconds(5)) }
            keyboard.reply(FieldReadReply(id: request!.id, state: .reading))
            try? await Task.sleep(for: .milliseconds(40))
            keyboard.reply(FieldReadReply(id: request!.id, state: .done, above: "Hello", stop: .start))
            return request!
        }
        var walked = false
        let reply = try await channel.read(.context, instructionID: "i") { walked = true }
        let request = await keyboardSide.value
        #expect(request.instructionID == "i" && request.kind == .context)
        #expect(walked, "The strip can say it reads while the keyboard walks")
        #expect(reply.above == "Hello")
        #expect(keyboard.takeReply(id: request.id) == nil, "A finished reply leaves the App Group once read")
    }

    @Test func noAnswerFailsAndAnUnreadEditIsTakenBack() async throws {
        let store = LinkStore(MemoryLinkStore())
        let channel = InstructionFieldChannel(store: store, post: { _ in }, poll: .milliseconds(5), ackTimeout: 0.1, readTimeout: 1, editTimeout: 0.1)
        let keyboard = InstructionLink(store: store)
        await #expect(throws: InstructionFailure.self) { _ = try await channel.read(.more, instructionID: "i") {} }
        #expect(keyboard.takeRequest() == nil, "A request nobody took is removed, so it is never served late")
        let ack = await channel.apply(ScopedEdit(instructionID: "i", documentID: nil, before: "a", after: "", target: "b"))
        #expect(ack == nil)
        #expect(keyboard.takeEdit() == nil, "An edit nobody read can never land later")
    }
}

@MainActor @Suite(.timeLimit(.minutes(1))) struct KeyboardSessionInstructionTests {
    @Test func theMagicToggleRoutesSpeechAwayFromTheFieldAndReleasingItRuns() async throws {
        let composer = ComposerSession(microphone: GateMicrophone(), activateAudioSession: {})
        await composer.arm()
        let sink = RecordingSink(), sockets = SocketBox()
        let field = FakeField(text: "hey see you at nine", sessionLength: 19)
        let instruction = InstructionSession(runner: FixedRunner(reply: "SCOPE: session\nHey, see you at nine."))
        instruction.field = field
        let keyboard = KeyboardSession(composer: composer, sink: sink, instruction: instruction, sonioxKey: { "test" },
                                       makeSocket: { sockets.make() }, warmConnection: {})
        keyboard.update(visible: true, surface: .dictation)
        await keyboard.settle()

        try await keyboard.debugDictationLine("hey see you at nine")
        keyboard.magicReported(.held)
        #expect(keyboard.speechMode == .instruction && instruction.strip.phase == .listening)
        try await keyboard.debugDictationLine("add punctuation")
        #expect(sink.lines.map(\.text) == ["hey see you at nine"], "Instruction speech never reaches the dictation sink")
        keyboard.magicReported(.held) // the same report again does nothing
        keyboard.magicReported(.off)
        for _ in 0..<400 where instruction.strip.phase != .result { try await Task.sleep(for: .milliseconds(5)) }
        #expect(instruction.strip.phase == .result)
        #expect(field.text == "Hey, see you at nine.")
        #expect(field.reads == [.context])
    }
}
