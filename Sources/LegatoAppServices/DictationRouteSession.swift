import Foundation
import LegatoKeyboardCore
import LegatoSoniox

/// Shared speech-route ownership. Hosts supply capture and field settling; the route alone owns
/// the engine, mode transitions and the cut that separates dictation from a spoken instruction.
@MainActor final class DictationRouteSession {
    let engine: DictationEngine
    let instruction: InstructionSession
    private let modeSink: SpeechModeSink
    private let pipeline: DictationPipeline?
    private var finishingDictation: Task<Void, Never>?
    private var cutTimeout: Task<Void, Never>?
    private var cutGeneration = 0
    var afterDictationSettled: @MainActor () async -> Void = {}
    var speechMode: SpeechMode { modeSink.target }

    init(sink: any DictationRouteSink, instruction: InstructionSession,
         sonioxKey: @escaping @MainActor () -> String,
         makeSocket: @escaping @Sendable () -> any SonioxSocket, vocabularyURL: URL,
         now: @escaping @MainActor () -> Double = { ProcessInfo.processInfo.systemUptime }) {
        self.instruction = instruction
        pipeline = sink as? DictationPipeline
        modeSink = SpeechModeSink(dictation: sink)
        engine = DictationEngine(sink: modeSink, sonioxKey: sonioxKey, makeSocket: makeSocket,
                                 vocabularyURL: vocabularyURL, now: now)
        pipeline?.cutRecognizer = { [engine] in await engine.finalizeChunk() }
        modeSink.onInstructionLine = { instruction.hear($0) }
        modeSink.onInstructionTail = { instruction.hearTail($0) }
        modeSink.onTransition = { [weak self] transition in
            guard let self else { return }
            if transition.to == .instruction {
                instruction.begin()
                if let pipeline { finishingDictation = Task { await pipeline.finishLiveRun() } }
            } else { instruction.end() }
        }
        if instruction.beforeRun == nil, pipeline != nil {
            instruction.beforeRun = { [weak self] in await self?.settleBeforeInstruction() }
        }
    }

    private func settleBeforeInstruction() async {
        guard let pipeline else { return }
        if let finishingDictation { await finishingDictation.value }
        else { await pipeline.finishLiveRun() }
        finishingDictation = nil
        _ = await pipeline.settle(timeout: .seconds(3))
        await afterDictationSettled()
    }

    func beginTake() { modeSink.beginTake() }

    /// A manual take is paused with words pending (`DictationPipeline.pauseTake`): a send still works without a take running.
    var isPaused: Bool { pipeline?.isPaused ?? false }

    /// The user's send of a staged take: the words so far go to the field now (`DictationPipeline.sendNow`). Dictation only.
    func sendNow(editPreview: Bool = false, preview: KeyboardRequest.PreviewAnchor? = nil) async {
        guard modeSink.target == .dictation else { return }
        await pipeline?.sendNow(editPreview: editPreview, preview: preview)
    }

    /// The user's raw send (`DictationPipeline.sendRawNow`): the same, with no cleanup. Dictation only.
    func sendRawNow(preview: KeyboardRequest.PreviewAnchor? = nil) async {
        guard modeSink.target == .dictation else { return }
        await pipeline?.sendRawNow(preview: preview)
    }

    /// The user's swipe left (`DictationPipeline.discardNow`) and its undo. Dictation only.
    func discardNow() async {
        guard modeSink.target == .dictation else { return }
        await pipeline?.discardNow()
    }

    func undoDiscardNow() async {
        guard modeSink.target == .dictation else { return }
        await pipeline?.undoDiscardNow()
    }

    /// Whether audio is still arriving is a host fact (including replay); cut ordering is shared.
    func setMagic(_ enabled: Bool, cut: Bool) {
        let mode: SpeechMode = enabled ? .instruction : .dictation
        guard mode != modeSink.target else { return }
        modeSink.toggle(to: mode, cut: cut)
        guard cut else { return }
        cutGeneration += 1
        let generation = cutGeneration
        Task { [weak self] in
            guard let self else { return }
            if !(await engine.finalizeChunk()), generation == cutGeneration { modeSink.flushCuts() }
        }
        cutTimeout?.cancel()
        cutTimeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, let self, generation == cutGeneration else { return }
            modeSink.flushCuts()
        }
    }

    func finishModes() {
        cancelCut()
        modeSink.flushCuts()
        if modeSink.target == .instruction { modeSink.toggle(to: .dictation, cut: false) }
    }

    func reset() async {
        resetRouting()
        await resetPipeline()
    }

    /// The session's routing (mode, cut, instruction); the pipeline keeps its run, which may still be ending.
    func resetRouting() {
        cancelCut()
        finishingDictation?.cancel(); finishingDictation = nil
        modeSink.resetRouter()
        instruction.reset()
    }

    /// The pipeline's session: drops the outbox and any run that never ended.
    func resetPipeline() async { await modeSink.dictation.reset() }

    private func cancelCut() {
        cutGeneration += 1
        cutTimeout?.cancel(); cutTimeout = nil
    }
}
