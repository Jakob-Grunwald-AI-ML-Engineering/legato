import Foundation
import Observation
import LegatoAgent
import LegatoKeyboardCore

/// A desktop draft owns its text until a confirmed Insert or an explicit Discard. A correction
/// replaces only the draft captured when Magic was pressed. Speech arriving afterwards appends.
@MainActor @Observable public final class MacComposerDraft: DictationRouteSink {
    private var base = ""
    private var additions = ""
    private var tail = ""
    private var preview: String?
    public var text: String { LiveSegment.joined([preview ?? base, additions, tail]) }
    public var isEmpty: Bool { text.isEmpty }
    public private(set) var isCorrecting = false
    public internal(set) var isInserting = false
    public internal(set) var needsCopy = false
    public internal(set) var message: String?
    private var discarded: String?
    public var canUndoDiscard: Bool { discarded != nil }
    @ObservationIgnored private var expiry: Task<Void, Never>?
    @ObservationIgnored private var correction: Task<Void, Never>?
    @ObservationIgnored private var revision = 0
    @ObservationIgnored var documentID = UUID()
    @ObservationIgnored var original = ""
    @ObservationIgnored var acceptingSpeech = false
    @ObservationIgnored var needsFreshBoundary = false
    @ObservationIgnored var recentContext: () -> String = { "" }
    public var backgroundText: String { recentContext() }
    @ObservationIgnored var onCut: (() -> Void)?
    @ObservationIgnored private let defaults: UserDefaults
    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    public func receive(_ line: DictationRouteLine) async {
        guard acceptingSpeech else { return }
        additions = LiveSegment.joined([additions, line.text])
        original = LiveSegment.joined([original, line.text])
        tail = line.remainingTail ?? ""
    }
    public func tailChanged(_ text: String) { if acceptingSpeech { tail = text } }
    public func boundary(_ reason: String) {
        if reason == "finalize" || reason == "finished" { onCut?() }
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
            onCut = { finish(true) }
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
        guard !isCorrecting, !isInserting, !needsCopy else { return }
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
                let result = try await pipeline.cleanDraft(source, instructions: instructions, writingSettings: settings) { [self] visible in
                    guard revision == generation else { return }
                    preview = visible
                }
                guard revision == generation else { return }
                base = result
            } catch {
                guard revision == generation else { return }
                message = "Magic couldn't finish. Your draft is ready to retry."
            }
            preview = nil
            isCorrecting = false
            correction = nil
        }
    }

    func startNewDestination() {
        expireUndo()
        documentID = UUID()
        original = ""
        message = nil
        needsCopy = false
    }
    private func expireUndo() {
        expiry?.cancel()
        expiry = nil
        discarded = nil
        discardedOriginal = ""
        discardedNeedsCopy = false
    }
    func settleCorrection() async { await correction?.value }
    private var discardedNeedsCopy = false
    private var discardedOriginal = ""
    func discard() {
        let saved = LiveSegment.joined([base, additions, tail])
        guard !saved.isEmpty else { return }
        let raw = original
        let retained = needsCopy
        clear()
        discardedNeedsCopy = retained
        discarded = saved
        discardedOriginal = raw
        expiry = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(DictationPipeline.discardUndoSeconds)) } catch { return }
            self?.expireUndo()
        }
    }
    func undo() {
        guard let discarded, isEmpty, !isInserting else { return }
        base = discarded
        original = discardedOriginal
        needsCopy = discardedNeedsCopy
        if needsCopy { message = "Insertion couldn't be confirmed. Check the field before pasting a copy." }
        expireUndo()
    }
    func clear() {
        expireUndo()
        revision += 1
        correction?.cancel()
        correction = nil
        preview = nil
        base = ""; additions = ""; tail = ""; original = ""; discardedOriginal = ""
        isCorrecting = false; needsCopy = false; message = nil
    }
}
