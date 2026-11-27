import Foundation
import LegatoVocabulary
import Observation
import LegatoAgent
import LegatoKeyboardCore

/// A desktop draft owns its text until Insert hands it to History and delivery, or Discard clears it. A correction
/// replaces only the draft captured when Magic was pressed. Speech arriving afterwards appends.
@MainActor @Observable public final class MacComposerDraft: DictationRouteSink {
    private var base = ""
    private var additions = ""
    private var tail = ""
    public var text: String { LiveSegment.joined([base, additions, tail]) }
    public var isEmpty: Bool { text.isEmpty }
    public private(set) var isCorrecting = false
    public internal(set) var isInserting = false
    public enum Dismissal: Equatable { case insert, discard }
    public internal(set) var dismissal: Dismissal?
    public struct VisualRevision {
        public let id: Int
        public let source: String
        public let result: String
    }
    public private(set) var visualRevision: VisualRevision?
    public internal(set) var message: String?
    private var discarded: String?
    public var canUndoDiscard: Bool { discarded != nil }
    @ObservationIgnored private var expiry: Task<Void, Never>?
    @ObservationIgnored private var correction: Task<Void, Never>?
    @ObservationIgnored private var revision = 0
    @ObservationIgnored public private(set) var documentID = UUID()
    @ObservationIgnored var recognitionHints: Set<String> = []
    @ObservationIgnored public private(set) var original = ""
    @ObservationIgnored var acceptingSpeech = false
    @ObservationIgnored var needsFreshBoundary = false
    @ObservationIgnored var recentContext: () -> String = { "" }
    public var backgroundText: String { recentContext() }
    @ObservationIgnored var topicContext: (Date) -> VocabularyTopicContext = { _ in .init() }
    public func vocabularyTopicContext(since: Date) -> VocabularyTopicContext { topicContext(since) }
    @ObservationIgnored var onCut: ((Bool) -> Void)?
    @ObservationIgnored private let defaults: UserDefaults
    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    public func receive(_ line: DictationRouteLine) async {
        guard acceptingSpeech else { return }
        recognitionHints.formUnion(line.recognitionHints)
        additions = LiveSegment.joined([additions, line.text])
        original = LiveSegment.joined([original, line.text])
        tail = line.remainingTail ?? ""
    }
    public func tailChanged(_ text: String) { if acceptingSpeech { tail = text } }
    public func boundary(_ reason: String) {
        if reason == "finalize" || reason == "finished" { onCut?(true) }
    }
    /// A send, its acknowledgement and its timeout can finish in any order, even during a subsequent cut.
    func finalizeForMagic(request: @escaping @MainActor () async -> Bool) async -> Bool {
        guard onCut == nil else { return false }
        return await withCheckedContinuation { continuation in
            var pending: CheckedContinuation<Bool, Never>? = continuation
            let finish: @MainActor (Bool) -> Void = { [self] success in
                guard let continuation = pending else { return }
                pending = nil
                onCut = nil
                continuation.resume(returning: success)
            }
            onCut = finish
            Task { if !(await request()) { finish(false) } }
            Task {
                try? await Task.sleep(for: DictationPipeline.sendCutWait)
                finish(false)
            }
        }
    }

    public func reset() async { acceptingSpeech = false; tail = "" }

    func sealTail() {
        additions = LiveSegment.joined([additions, tail])
        original = LiveSegment.joined([original, tail])
        tail = ""
    }
    func correct(using pipeline: DictationPipeline, instructions: String?) {
        guard !isCorrecting, dismissal == nil else { return }
        guard pipeline.keepsTakes() else { message = "Magic is unavailable in a password field."; return }
        let source = LiveSegment.joined([base, additions])
        guard !source.isEmpty else { return }
        base = source
        additions = ""
        message = nil
        isCorrecting = true
        revision += 1
        let generation = revision
        let settings = ComposerWritingSettings(in: defaults)
        correction = Task {
            do {
                let result = try await pipeline.cleanDraft(source, instructions: instructions, writingSettings: settings)
                guard revision == generation else { return }
                let originalText = LiveSegment.joined([source, additions, tail])
                let rewrittenText = LiveSegment.joined([result, additions, tail])
                if originalText != rewrittenText {
                    visualRevision = .init(id: generation, source: originalText, result: rewrittenText)
                }
                base = result
            } catch {
                guard revision == generation else { return }
                message = "Magic couldn't finish. Your draft is ready to retry."
            }
            isCorrecting = false
            correction = nil
        }
    }

    func startNewDestination() {
        expireUndo()
        documentID = UUID()
        original = ""
        recognitionHints.removeAll()
        message = nil
        dismissal = nil
        visualRevision = nil
    }
    private func expireUndo() {
        expiry?.cancel()
        expiry = nil
        discarded = nil
        discardedOriginal = ""
    }
    func settleCorrection() async { await correction?.value }
    private var discardedOriginal = ""
    func discard() {
        let saved = LiveSegment.joined([base, additions, tail])
        let raw = LiveSegment.joined([original, tail])
        dismissal = .discard
        acceptingSpeech = false
        clear()
        guard !saved.isEmpty else { return }
        discarded = saved
        discardedOriginal = raw
    }

    /// The menu gets its whole undo window after capture has been released.
    func startUndoWindow() {
        guard canUndoDiscard else { return }
        expiry = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(DictationPipeline.discardUndoSeconds)) } catch { return }
            self?.expireUndo()
        }
    }
    func undo() {
        guard let discarded, isEmpty, !isInserting else { return }
        base = discarded
        original = discardedOriginal
        dismissal = nil
        expireUndo()
    }
    func clear() {
        expireUndo()
        onCut?(false)
        revision += 1
        correction?.cancel()
        correction = nil
        visualRevision = nil
        base = ""; additions = ""; tail = ""; original = ""; discardedOriginal = ""
        isCorrecting = false; message = nil
    }
}
