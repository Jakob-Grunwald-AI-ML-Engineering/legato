import Foundation
import LegatoKeyboardCore

/// What speech on the dictation route is: words for the field, or an instruction about the field's text.
public enum SpeechMode: String, Sendable, Equatable { case dictation, instruction }

/// Tags speech with the mode active when it was spoken. The magic toggle changes the mode at once for new speech, but
/// words spoken just before it are still on their way (Soniox finalizes a word seconds after it was said). So a toggle
/// cuts the stream (a `finalize`), and segments keep arriving in the old mode until the cut's boundary: Soniox handles
/// the cut in order, so everything before the boundary was spoken before the toggle.
public struct SpeechModeRouter: Sendable, Equatable {
    public struct Transition: Sendable, Equatable {
        public var from: SpeechMode
        public var to: SpeechMode
    }
    /// The mode of the speech arriving now.
    public private(set) var current = SpeechMode.dictation
    /// Toggles whose cut has not come through yet, oldest first.
    public private(set) var pending: [SpeechMode] = []
    public init() {}

    /// The mode the toggle asks for (where `current` ends up once every cut is through).
    public var target: SpeechMode { pending.last ?? current }

    /// The toggle asks for `mode`. `cut`: a finalize went out, so the change waits for its boundary; without one (no
    /// stream, nothing on its way) it applies now, together with any cut still waiting. Returns what changed now.
    @discardableResult
    public mutating func toggle(to mode: SpeechMode, cut: Bool) -> [Transition] {
        guard mode != target else { return [] }
        pending.append(mode)
        return cut ? [] : flush()
    }

    /// A cut is through (a `finalize` boundary, or the stream's end): the oldest waiting toggle applies.
    public mutating func boundary() -> Transition? {
        guard !pending.isEmpty else { return nil }
        let next = pending.removeFirst()
        defer { current = next }
        return next == current ? nil : Transition(from: current, to: next)
    }

    /// Applies every waiting toggle (no boundary came in time, or the stream is gone).
    public mutating func flush() -> [Transition] {
        var transitions: [Transition] = []
        while let transition = boundary() { transitions.append(transition) }
        pending = []
        return transitions
    }
}

/// The dictation route's sink in front of the dictation pipeline: speech in instruction mode goes to the instruction
/// (lines and the live tail), never to the field; dictation goes on to the pipeline as before.
@MainActor final class SpeechModeSink: DictationRouteSink {
    let dictation: any DictationRouteSink
    private(set) var router = SpeechModeRouter()
    /// Instruction speech: a finalized line, and the live tail.
    var onInstructionLine: (@MainActor (DictationRouteLine) -> Void)?
    var onInstructionTail: (@MainActor (String) -> Void)?
    /// The mode changed for the speech arriving now.
    var onTransition: (@MainActor (SpeechModeRouter.Transition) -> Void)?

    init(dictation: any DictationRouteSink) { self.dictation = dictation }

    var mode: SpeechMode { router.current }
    var target: SpeechMode { router.target }

    func toggle(to mode: SpeechMode, cut: Bool) { apply(router.toggle(to: mode, cut: cut)) }
    func flushCuts() { apply(router.flush()) }
    private func apply(_ transitions: [SpeechModeRouter.Transition]) { for transition in transitions { changed(transition) } }
    private func changed(_ transition: SpeechModeRouter.Transition) {
        // Words still showing as the field's speaking head are not dictation any more.
        if transition.to == .instruction { dictation.tailChanged("") } else { onInstructionTail?("") }
        onTransition?(transition)
    }

    func receive(_ line: DictationRouteLine) async {
        switch router.current {
        case .dictation: await dictation.receive(line)
        case .instruction: onInstructionLine?(line)
        }
    }
    func tailChanged(_ text: String) {
        switch router.current {
        case .dictation: dictation.tailChanged(text)
        case .instruction: onInstructionTail?(text)
        }
    }
    func speechActivity() { if router.current == .dictation { dictation.speechActivity() } }
    func boundary(_ reason: String) {
        if let transition = router.boundary() { changed(transition) }
        dictation.boundary(reason)
    }
    /// A new keyboard session starts in dictation mode.
    func reset() async {
        router = SpeechModeRouter()
        await dictation.reset()
    }
    func warm() async { await dictation.warm() }
    func finishTake() async { await dictation.finishTake() }
    var backgroundText: String { dictation.backgroundText }
}
