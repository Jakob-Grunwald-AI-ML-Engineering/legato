import Foundation
import Observation
import os
import LegatoAgent
import LegatoClaude
import LegatoComposerDoc
import LegatoCore
import LegatoKeyboardCore
import LegatoVocabulary

/// The keyboard's field, as instruction mode needs it: reads around the cursor, scoped edits, and the strip.
@MainActor public protocol InstructionField: AnyObject {
    /// Reads the field for `instructionID`. `reading` is called when the keyboard says it walks the field (the cursor
    /// moves visibly). Throws `InstructionFailure.read` when the read failed or nobody answered.
    func read(_ kind: FieldReadRequest.Kind, instructionID: String, reading: @escaping @MainActor () -> Void) async throws -> FieldReadReply
    /// Lands `edit` and waits for the keyboard's answer; nil when none came.
    func apply(_ edit: ScopedEdit) async -> ScopedEditAck?
    func publish(_ strip: InstructionStrip)
}

/// Runs one instruction (`InstructionRunner` conforms); a fake in tests.
public protocol InstructionRunning: Sendable {
    func run(instruction: String, context: InstructionContext, read: InstructionRunner.Reader) async throws -> InstructionOutcome
}
extension InstructionRunner: InstructionRunning {}

/// Instruction mode for one keyboard session: collects the instruction's speech while the magic toggle is on, runs it
/// when the toggle goes off (or on the strip's Run), lands the result in the field as a scoped edit, and offers undo.
/// Nothing runs on its own. Publishes `InstructionStrip` for the keyboard on every change.
@MainActor @Observable public final class InstructionSession {
    public private(set) var strip = InstructionStrip()
    /// Counts writes to history, so history views can reload.
    public private(set) var historyRevision = 0
    @ObservationIgnored public weak var field: (any InstructionField)?
    /// Called before the field is read: the dictation before the instruction finishes landing (its cleanup), so the
    /// model sees the field as the user will.
    @ObservationIgnored public var beforeRun: (@MainActor () async -> Void)?
    /// Counts and timings, never text.
    @ObservationIgnored public var diagnostics: (@MainActor (_ event: String, _ fields: [String: Any]) -> Void)?
    @ObservationIgnored private let runner: any InstructionRunning
    @ObservationIgnored private let history: (any HistoryStore)?
    @ObservationIgnored private var words: [Word] = []
    @ObservationIgnored private var tail = ""
    @ObservationIgnored private var listening = false
    @ObservationIgnored private var task: Task<Void, Never>?
    /// Names the task in `task`, so a finished one clears only itself.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var landed: (edit: ScopedEdit, cursor: Int)?
    private static let log = Logger(subsystem: "de.gruenwald.legato", category: "instruction")

    public init(runner: any InstructionRunning, history: (any HistoryStore)? = nil) {
        self.runner = runner; self.history = history
    }

    /// The model from the composer's setting (`composer.liveModel`), the personal prompt and the vocabulary, as the
    /// composer's writer uses them.
    public convenience init(vocabularyURL: URL, history: (any HistoryStore)? = nil, defaults: UserDefaults = .standard) {
        nonisolated(unsafe) let store = defaults
        self.init(runner: InstructionRunner(
            client: MessagesStream(keyStore: KeychainKeyStore()),
            model: { ModelChoice(rawValue: store.string(forKey: "composer.liveModel") ?? "") ?? .haiku },
            personalPrompt: { store.string(forKey: "composer.personalPrompt") ?? "" },
            vocabulary: { (try? await VocabularyStoreAccess.terms(vocabularyURL)) ?? [] }), history: history)
    }

    /// The instruction's words so far (final words, then the live tail), as the strip shows them.
    public var transcript: String {
        ([words.map(\.text).joined(separator: " "), tail.trimmingCharacters(in: .whitespacesAndNewlines)]).filter { !$0.isEmpty }.joined(separator: " ")
    }
    public var isRunning: Bool { task != nil }

    // MARK: Speech

    /// Instruction mode came on: a new instruction starts (a result still on the strip counts as accepted).
    public func begin() {
        // A new instruction replaces one that is still running (its result would land under the new strip).
        task?.cancel(); task = nil
        listening = true
        landed = nil
        words = []; tail = ""
        update(InstructionStrip(instructionID: UUID().uuidString, phase: .listening))
    }

    public func hear(_ line: DictationRouteLine) {
        let lineWords = line.words.isEmpty ? line.text.split(whereSeparator: \.isWhitespace).map { Word(text: String($0)) } : line.words
        words += lineWords
        tail = ""
        if listening { setTranscript() }
    }
    public func hearTail(_ text: String) {
        tail = text
        if listening { setTranscript() }
    }

    /// Instruction mode went off and every word of it is through: run it, unless nothing was said.
    public func end() {
        guard listening else { return }
        listening = false
        tail = ""
        guard !words.isEmpty else { return update(InstructionStrip()) }
        run()
    }

    // MARK: Intents

    public func handle(_ intent: InstructionIntent) {
        guard intent.instructionID == nil || intent.instructionID == strip.instructionID else { return }
        switch intent.action {
        case .run: if !listening, strip.phase == .failed || strip.phase == .idle, !words.isEmpty { run() }
        case .undo: undo()
        case .accept: landed = nil; if strip.phase == .result || strip.phase == .undone { update(InstructionStrip()) }
        case .dismiss:
            task?.cancel(); task = nil
            if !listening { words = []; tail = ""; update(InstructionStrip()) } else { words = []; tail = ""; setTranscript() }
        }
    }

    /// The keyboard went away: everything is dropped (a running instruction too).
    public func reset() {
        task?.cancel(); task = nil
        listening = false; words = []; tail = ""; landed = nil
        if strip.phase != .idle || strip.instructionID != nil { update(InstructionStrip()) }
    }

    // MARK: Run

    private func run() {
        guard task == nil else { return }
        let id = strip.instructionID ?? UUID().uuidString
        generation += 1
        let generation = self.generation
        let instruction = InstructionRunner.present(words)
        let transcript = self.transcript
        update(InstructionStrip(instructionID: id, phase: .running, transcript: transcript))
        let started = ContinuousClock.now
        task = Task { [weak self] in
            guard let self else { return }
            defer { if self.generation == generation { self.task = nil } }
            do {
                await self.beforeRun?()
                guard let field = self.field else { throw InstructionFailure.read("Legato's keyboard isn't connected.") }
                try Task.checkCancellation()
                let reply = try await field.read(Self.mentionsSelection(transcript) ? .contextInPlace : .context, instructionID: id) { [weak self] in self?.setPhase(.reading, id: id) }
                self.setPhase(.running, id: id)
                // The edit goes to the field that was read (the keyboard refuses it in another one).
                let documentID = reply.documentID
                let outcome = try await self.runner.run(instruction: instruction, context: Self.context(reply)) { @MainActor [weak self] kind in
                    try Task.checkCancellation()
                    guard let self, let field = self.field else { throw InstructionFailure.read("Legato's keyboard isn't connected.") }
                    let more = try await field.read(kind == .block ? .more : .toCap, instructionID: id) { [weak self] in self?.setPhase(.reading, id: id) }
                    self.setPhase(.running, id: id)
                    return Self.context(more)
                }
                try Task.checkCancellation()
                let edit = ScopedEdit(instructionID: id, documentID: documentID, before: outcome.range.before, after: outcome.range.after,
                                      selected: outcome.range.selected, target: outcome.target)
                let ack = await field.apply(edit)
                if let ack, !ack.applied, let partial = ack.partial {
                    // Stopped partway: what landed stays, and undo puts the original back.
                    guard self.strip.instructionID == id else { return }
                    self.stranded(original: edit.scopeText, partial: partial, documentID: edit.documentID, ack: ack, id: id)
                    self.diagnostics?("instruction.run", ["ok": false, "reason": "partial", "ms": Self.ms(since: started)])
                    return
                }
                guard let ack, ack.applied else {
                    let reason = ack?.reason ?? "The keyboard didn't answer, so nothing was edited."
                    // An edit that stopped partway is not run again over a field in an unknown state.
                    throw ack?.stopped == true ? InstructionFailure.unreadable(reason) : InstructionFailure.read(reason)
                }
                guard self.strip.instructionID == id else { return }
                self.landed = (edit, ack.cursor ?? edit.target.utf16.count)
                self.words = []
                await self.save(original: edit.scopeText, result: edit.target)
                self.update(InstructionStrip(instructionID: id, phase: .result, transcript: transcript, scope: outcome.scope.rawValue,
                                             message: Self.done(Self.changedScope(outcome.scope, original: edit.scopeText, result: edit.target),
                                                                deleted: edit.target.isEmpty), canUndo: true))
                self.diagnostics?("instruction.run", ["ok": true, "scope": outcome.scope.rawValue, "reads": outcome.reads,
                                                      "chars": edit.scopeText.count, "newChars": edit.target.count, "ms": Self.ms(since: started)])
            } catch is CancellationError {
                self.diagnostics?("instruction.run", ["ok": false, "reason": "cancelled", "ms": Self.ms(since: started)])
            } catch {
                guard self.strip.instructionID == id else { return }
                let failure = error as? InstructionFailure ?? .provider(String(describing: type(of: error)))
                Self.log.error("instruction failed: \(String(describing: failure).prefix(200), privacy: .public)")
                self.diagnostics?("instruction.run", ["ok": false, "reason": Self.reason(failure), "ms": Self.ms(since: started)])
                self.update(InstructionStrip(instructionID: id, phase: .failed, transcript: transcript, message: failure.message,
                                             canRetry: failure.canRetry))
            }
        }
    }

    private func undo() {
        guard let landed, task == nil, let id = strip.instructionID, let field else { return }
        let edit = ScopedEditPlanner.undo(of: landed.edit, cursor: landed.cursor)
        generation += 1
        let generation = self.generation
        task = Task { [weak self] in
            guard let self else { return }
            defer { if self.generation == generation { self.task = nil } }
            let ack = await field.apply(edit)
            guard self.strip.instructionID == id else { return }
            if let ack, !ack.applied, let partial = ack.partial {
                // The undo stopped partway: undo again goes on from what landed.
                self.stranded(original: edit.target, partial: partial, documentID: edit.documentID, ack: ack, id: id)
            } else if ack?.applied == true {
                self.landed = nil
                self.update(InstructionStrip(instructionID: id, phase: .undone, transcript: self.strip.transcript, scope: self.strip.scope,
                                             message: "Undone.", canUndo: false))
            } else {
                self.landed = nil
                self.update(InstructionStrip(instructionID: id, phase: .failed, transcript: self.strip.transcript,
                                             message: ack?.stopped == true ? ack?.reason : "The text changed, so there is nothing to undo.",
                                             canRetry: false))
            }
        }
    }

    /// An edit stopped partway (the field did not keep up): the field shows `partial` where the scope was. `landed`
    /// becomes an edit from `original` to it, so undo puts `original` back; the instruction is not run again on its own.
    private func stranded(original: String, partial: String, documentID: String?, ack: ScopedEditAck, id: String) {
        landed = (ScopedEdit(instructionID: id, documentID: documentID, before: original, after: "", target: partial),
                  ack.cursor ?? partial.utf16.count)
        words = []
        update(InstructionStrip(instructionID: id, phase: .failed, transcript: strip.transcript, scope: strip.scope,
                                message: (ack.reason ?? "The edit stopped partway.") + " Undo puts the text back.", canUndo: true,
                                canRetry: false))
    }

    // MARK: Helpers

    /// The scope the strip names: a change that stays within one paragraph of a larger scope is "the paragraph".
    static func changedScope(_ scope: InstructionScope, original: String, result: String) -> InstructionScope {
        guard scope == .above || scope == .all, original.contains(where: \.isNewline), !result.isEmpty else { return scope }
        let old = Array(original), new = Array(result)
        var start = 0
        while start < min(old.count, new.count), old[start] == new[start] { start += 1 }
        var end = 0
        while end < min(old.count, new.count) - start, old[old.count - 1 - end] == new[new.count - 1 - end] { end += 1 }
        // The changed part of the original, widened to whole lines: one paragraph, or more.
        let changed = old[start..<(old.count - end)].contains(where: \.isNewline) || new[start..<(new.count - end)].contains(where: \.isNewline)
        return changed ? scope : .paragraph
    }

    /// The instruction is about selected text: its first read must not move the cursor (a walk would lose the selection).
    static func mentionsSelection(_ instruction: String) -> Bool {
        let words = instruction.lowercased().split { !$0.isLetter }
        return words.contains { word in
            ["selection", "selected", "highlighted", "auswahl", "markierung"].contains(word)
                || word.hasPrefix("markiert") || word.hasPrefix("ausgewählt")
        }
    }

    /// What the model is shown, from the keyboard's read.
    static func context(_ reply: FieldReadReply) -> InstructionContext {
        // Final: nothing more is read on that side. Complete: the shown text reaches the end of the user's text there.
        func final(_ stop: FieldStop, more: Bool) -> Bool { [.start, .quote, .signature, .cap].contains(stop) || !more }
        func complete(_ stop: FieldStop, more: Bool) -> Bool { [.start, .quote, .signature].contains(stop) || !more }
        let below = reply.stopBelow ?? .unread
        return InstructionContext(above: reply.above, below: reply.below, selection: reply.selection, sessionLength: reply.sessionLength,
                                  moreAbove: reply.moreAbove, moreBelow: reply.moreBelow,
                                  aboveFinal: final(reply.stop, more: reply.moreAbove), belowFinal: final(below, more: reply.moreBelow),
                                  aboveComplete: complete(reply.stop, more: reply.moreAbove), belowComplete: complete(below, more: reply.moreBelow))
    }

    /// The strip's line for a landed result: what was done, to which part.
    static func done(_ scope: InstructionScope, deleted: Bool) -> String {
        let part = switch scope {
        case .selection: "the selection"
        case .session: "what you dictated"
        case .paragraph: "the paragraph"
        case .above: "the text above"
        case .all: "the whole text"
        }
        return (deleted ? "Deleted " : "Rewrote ") + part + "."
    }

    private static func reason(_ failure: InstructionFailure) -> String {
        switch failure {
        case .missingKey: "missingKey"
        case .provider: "provider"
        case .malformedReply: "malformed"
        case .unknownScope: "unknownScope"
        case .unavailableScope(let scope): "unavailable-\(scope.rawValue)"
        case .emptyText: "empty"
        case .unchanged: "unchanged"
        case .noText: "noText"
        case .commentary: "commentary"
        case .partialScope(let scope): "partial-\(scope.rawValue)"
        case .overreach: "overreach"
        case .read: "read"
        case .unreadable: "unreadable"
        }
    }

    private static func ms(since start: ContinuousClock.Instant) -> Int {
        let parts = start.duration(to: .now).components
        return Int(parts.seconds * 1000 + parts.attoseconds / 1_000_000_000_000_000)
    }

    private func setTranscript() {
        var next = strip
        next.transcript = transcript
        update(next)
    }
    private func setPhase(_ phase: InstructionStrip.Phase, id: String) {
        guard strip.instructionID == id, strip.phase != phase else { return }
        var next = strip
        next.phase = phase
        update(next)
    }
    private func update(_ value: InstructionStrip) {
        var value = value
        value.revision = strip.revision + 1
        guard value.phase != strip.phase || value.transcript != strip.transcript || value.message != strip.message
                || value.instructionID != strip.instructionID || value.canUndo != strip.canUndo || value.scope != strip.scope
                || value.canRetry != strip.canRetry else { return }
        strip = value
        field?.publish(value)
    }

    /// One history entry per instruction: the scope's text before (`rawText`) and after (`text`).
    private func save(original: String, result: String) async {
        guard let history else { return }
        try? await history.upsert(DictationEntry(id: UUID(), date: Date(), text: result, rawText: original,
                                                 localeIdentifier: Locale.current.identifier, engineID: "instruction", duration: 0))
        historyRevision += 1
    }

    #if DEBUG || LEGATO_INTERNAL
    /// Debug bridge: a typed instruction stands in for speech (`begin`, the words, `end`), so it runs as a spoken one would.
    public func debugInstruction(_ text: String) {
        begin()
        hear(DictationRouteLine(sequence: 0, text: text, words: [], reason: "debug"))
        end()
    }
    public var debugState: [String: Any] {
        ["phase": strip.phase.rawValue, "revision": strip.revision, "instructionID": strip.instructionID ?? NSNull(),
         "transcriptChars": transcript.count, "scope": strip.scope ?? NSNull(), "message": strip.message ?? NSNull(),
         "canUndo": strip.canUndo, "running": isRunning, "listening": listening]
    }
    #endif
}

/// Vocabulary terms for the instruction's system prompt (as the composer's writer gets them).
enum VocabularyStoreAccess {
    static func terms(_ url: URL) async throws -> [String] {
        try await VocabularyStore(fileURL: url).snapshot().entries.filter { !$0.blocked }.map(\.text)
    }
}
