import Foundation
import Observation
import os
import LegatoAgent
import LegatoClaude
import LegatoCore
import LegatoKeyboardCore
import LegatoVocabulary

/// A cleaned line waiting for the keyboard to type it.
public struct DictationDelivery: Sendable, Equatable {
    public var lineID: String
    public var sequence: Int
    public var raw: String
    public var text: String
    public var cleaned: Bool
    /// The whole text is here. A take streams: the same delivery grows (`text` only ever appends) until it is final.
    public var final = true
    /// Set on a growing take whose cleanup then failed: the typed part stays until the user chooses (`retracted`).
    public var failed = false
    /// The streamed text is taken back (Retry or Insert as-is on a failed take, or the guard rejected it): whoever
    /// typed it erases it (if the field still shows exactly that) and acknowledges. The delivery is final.
    public var retracted = false
    /// A whole-take delivery (the take modes), as opposed to a line of line-by-line dictation.
    public var isTake = false
}

/// Where a take is: collecting lines, cleaning them in one call, or holding them raw after cleanup failed twice.
public enum DictationTakePhase: String, Sendable, Equatable { case buffering, cleaning, failed }

/// The host's end of dictation. Per the send setting, either the whole take is held while the user speaks and
/// cleaned in ONE cleanup-only call (on stop, or after a pause), or (line by line) every finalized line goes
/// through its own call (`DictationCleanupPipeline`). Either way the result waits in an ordered outbox until the
/// writer or keyboard acknowledges having typed it. The keyboard session resets it when the keyboard disappears.
///
/// In `live` (iOS keyboard only) nothing waits: the run's target text (raw words as spoken, then the speaking head)
/// is published as a `LiveDictationRun` snapshot, and the keyboard types it and edits it. The run's segments are
/// grouped into cleanup units (whole sentences, not the endpointer's pause fragments); each closed unit is cleaned in
/// the background (the line pipeline's, which may drop an all-filler unit); the cleaned units go into the target
/// once, when the take ends (`finishLive`).
@MainActor @Observable public final class DictationPipeline: DictationRouteSink {
    /// Names this keyboard session on the link; lines count from 0 within it.
    public private(set) var sessionID = UUID().uuidString
    /// Lines not yet acknowledged, in speaking order.
    public private(set) var outbox: [DictationDelivery] = []
    /// Lines received and not yet delivered to the outbox (in cleanup).
    public private(set) var pending = 0
    /// Why lines went raw, newest last (no dictated text), for diagnostics.
    public private(set) var fallbacks: [String] = []
    /// The take phase (take modes). `buffering` also holds while nothing is buffered.
    public private(set) var takePhase = DictationTakePhase.buffering
    /// Lines of the take received and not yet sent, in speaking order.
    public private(set) var takeLines: [String] = []
    /// The text being cleaned now (nil unless `takePhase == .cleaning`).
    public private(set) var cleaningText: String?
    /// The raw text held after cleanup failed twice (nil unless `takePhase == .failed`): `retry()` or `insertRaw()`.
    public private(set) var failedText: String?
    /// The pause countdown over the buffered take (host `systemUptime`); nil when none runs.
    public private(set) var countdownStart: Double?
    public private(set) var countdownDeadline: Double?
    /// Counts writes to history, so history views can reload.
    public private(set) var historyRevision = 0
    /// Everything the take holds, for display: failed or cleaning text first, then the buffer.
    public var takeDisplay: String {
        ([failedText ?? cleaningText] + takeLines).compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
    }
    /// Characters in `takeDisplay`.
    public var takeLength: Int { takeDisplay.count }
    /// Background text for Soniox at take start: the recent written takes.
    public var backgroundText: String { recentTakes.backgroundText() }
    /// The field's text before the cursor now (the keyboard reports it with its presence).
    @ObservationIgnored public var contextBefore: @MainActor () -> String = { "" }
    /// Called when the outbox changed.
    @ObservationIgnored public var onChange: (@MainActor () -> Void)?
    /// The last takes across sessions: cleanup context and Soniox background text. Survives `reset()`.
    @ObservationIgnored public let recentTakes: RecentTakesStore
    /// Keeps every dictated text. A take is saved raw before cleanup starts, so no cleanup outcome can lose it.
    @ObservationIgnored private let history: (any HistoryStore)?
    /// False while the field is a password field: its takes stay out of History and the recent takes (cleanup context).
    @ObservationIgnored public var keepsTakes: @MainActor () -> Bool = { true }
    /// Hosts opting in keep one checkpoint per live run rather than one row per cleanup unit.
    @ObservationIgnored private let groupsLiveHistory: Bool
    @ObservationIgnored private var liveHistoryWrite: Task<Void, Never>?
    @ObservationIgnored private var lastLiveHistory: DictationEntry?
    @ObservationIgnored private var liveHistoryFallbacks: Set<Int> = []
    /// The history entry of the last take: a retry of the same text updates it instead of adding another.
    @ObservationIgnored private var takeEntry: (raw: String, id: UUID)?
    @ObservationIgnored private let cleaner: any SentenceCleaning
    @ObservationIgnored private let vocabulary: @Sendable () async -> [String]
    @ObservationIgnored private let timeout: Duration
    /// How long a live sentence's cleanup may take before its raw words stand: the sentence lands as a small
    /// edit whenever it is ready, so it may take longer than a line of the other modes waits.
    @ObservationIgnored private let liveTimeout: Duration
    @ObservationIgnored private var pipeline: DictationCleanupPipeline?
    @ObservationIgnored private var terms: [String]?
    @ObservationIgnored private var lastWarm: Date?
    @ObservationIgnored private let sendMode: @MainActor () -> DictationSendSetting.Mode
    @ObservationIgnored private let pauseSeconds: @MainActor () -> Double
    @ObservationIgnored private let clock: any Clock<Duration>
    @ObservationIgnored private let takeTimeout: (@Sendable (Int) -> Duration)?
    @ObservationIgnored private var quietTask: Task<Void, Never>?
    @ObservationIgnored private var takeTask: Task<Void, Never>?
    @ObservationIgnored private var takeGeneration = 0
    @ObservationIgnored private var takeTextBefore = ""
    /// The growing delivery of the take being cleaned (nil until its first delta), and the text streamed so far.
    @ObservationIgnored private var streamSeq: Int?
    @ObservationIgnored private var streamed = ""
    /// The delivery of a take whose cleanup failed after text was streamed: `retry()` / `insertRaw()` retract it.
    @ObservationIgnored private var partialSeq: Int?
    @ObservationIgnored private var notifyTask: Task<Void, Never>?
    @ObservationIgnored private let streamTime: @Sendable () -> Duration
    @ObservationIgnored private var lastNotify: Duration = .zero
    /// Growth of a streaming delivery is announced at most this often (App Group writes and Darwin notes).
    private static let streamInterval = Duration.milliseconds(30)
    private static let log = Logger(subsystem: "de.gruenwald.legato", category: "dictation-pipeline")
    @ObservationIgnored private var nextTakeSequence = 0
    @ObservationIgnored private var suppressed = false
    /// Whether `live` may run here: the iOS keyboard link publishes it. Elsewhere (the Mac) `live` acts as `onStop`.
    @ObservationIgnored private let supportsLive: Bool
    /// The run being typed in `live` (nil between runs); a new one starts with the first words after a finished one.
    @ObservationIgnored public private(set) var liveRun: LiveDictationRun?
    /// The run's snapshot changed (nil: no run, remove it from the link). Called on every change; the host throttles.
    @ObservationIgnored public var onLiveChange: (@MainActor (LiveDictationSnapshot?) -> Void)?
    /// Counts and timings, never text: `live2.*` lines for the internal builds' diagnostics.
    @ObservationIgnored public var diagnostics: (@MainActor (_ event: String, _ fields: [String: Any]) -> Void)?
    @ObservationIgnored private var liveSubmitted: [Int: ContinuousClock.Instant] = [:]
    /// Live sentences are cleaned under a counter of their own (a cut-short segment is no sentence): cleanup
    /// sequence -> the key of the segment that closed the sentence in the run, and the unit's segments when it was sent
    /// (a unit the keyboard's split cut since then is cleaned again; this result is stale).
    @ObservationIgnored private var liveKeys: [Int: (key: Int, range: Range<Int>?)] = [:]
    /// A take began while the run before it still ends (its stop waits for its last words and cleanup): what the later
    /// takes bring (their speech, stops and starts) waits here, in order, and goes in once that run is complete, so each
    /// take is a run of its own. The link carries one run at a time, and a new take's words never join an old run.
    @ObservationIgnored private var held: [Held]?
    private enum Held { case tail(String), line(DictationRouteLine), stop, begin }
    /// A take began and its stop (`finishTake`) has not come yet.
    @ObservationIgnored private var liveTakeOpen = false
    /// The stop of the run that `held` waits for is still to come: the next `finishTake` is that run's.
    @ObservationIgnored private var heldAwaitsStop = false
    @ObservationIgnored private var liveCleanupSequence = 0
    /// When the run's take ended: a segment or cleanup that arrives within `liveStragglerGrace` still belongs to it.
    @ObservationIgnored private var liveFinishedAt: ContinuousClock.Instant?
    /// A run an instruction ended (`finishLiveRun`): nothing changes it any more (no late segment, unit or whole pass).
    @ObservationIgnored private var sealedLiveRunID: String?
    private static let liveStragglerGrace = Duration.seconds(3)
    /// The field's text before the cursor when the run began: the context its sentences are cleaned against. The
    /// field now holds the run's own words, which the cleaner must not see as "already typed" (it would drop them).
    @ObservationIgnored private var liveAnchor = ""
    #if DEBUG || LEGATO_INTERNAL
    /// Debug bridge: the next this many take cleanups fail (both attempts), so the failed state is reachable offline.
    @ObservationIgnored public var debugFailTakes = 0
    /// Debug bridge: when set, take cleanups stream from this scripted cleaner instead of the provider.
    @ObservationIgnored public var debugStreamCleaner: DebugStreamingCleaner?
    #endif
    /// The prompt cache lives 5 minutes after its last use.
    private static let warmInterval: TimeInterval = 240

    /// `defaults` holds the send setting: the Mac app's standard defaults, or the App Group on iOS.
    /// `supportsLive`: the iOS keyboard link is there to carry the live mode.
    public convenience init(vocabularyURL: URL, recentTakesURL: URL? = nil, history: (any HistoryStore)? = nil, defaults: UserDefaults = .standard,
                            supportsLive: Bool = false, groupsLiveHistory: Bool = false) {
        // `UserDefaults` is thread-safe by contract; the model is read on the cleanup call's thread.
        nonisolated(unsafe) let store = defaults
        self.init(recentTakes: RecentTakesStore(fileURL: recentTakesURL), history: history,
                  cleaner: SentenceCleanupClient(client: MessagesStream(keyStore: KeychainKeyStore()), model: { DictationSendSetting.cleanupModel(in: store) }),
                  vocabulary: { (try? await VocabularyStore(fileURL: vocabularyURL).snapshot().entries.filter { !$0.blocked }.map(\.text)) ?? [] },
                  sendMode: { DictationSendSetting.mode(in: defaults) }, pauseSeconds: { DictationSendSetting.pause(in: defaults) },
                  supportsLive: supportsLive, groupsLiveHistory: groupsLiveHistory)
    }
    public init(recentTakes: RecentTakesStore = RecentTakesStore(), history: (any HistoryStore)? = nil, cleaner: any SentenceCleaning, vocabulary: @escaping @Sendable () async -> [String] = { [] },
                timeout: Duration = .milliseconds(2500),
                sendMode: @escaping @MainActor () -> DictationSendSetting.Mode = { .lineByLine },
                pauseSeconds: @escaping @MainActor () -> Double = { DictationSendSetting.defaultPause },
                clock: any Clock<Duration> = ContinuousClock(),
                takeTimeout: (@Sendable (Int) -> Duration)? = nil,
                supportsLive: Bool = false,
                liveTimeout: Duration = .seconds(6), groupsLiveHistory: Bool = false) {
        self.groupsLiveHistory = groupsLiveHistory
        self.supportsLive = supportsLive; self.liveTimeout = liveTimeout
        self.recentTakes = recentTakes; self.history = history
        self.cleaner = cleaner; self.vocabulary = vocabulary; self.timeout = timeout
        self.sendMode = sendMode; self.pauseSeconds = pauseSeconds; self.clock = clock; self.takeTimeout = takeTimeout
        self.streamTime = Self.elapsedTime(on: clock)
    }

    /// The send setting now; `lineByLine` keeps the per-line path. `live` only where `supportsLive` (else `onStop`).
    public var mode: DictationSendSetting.Mode {
        let mode = sendMode()
        return mode == .live && !supportsLive ? .onStop : mode
    }

    public func receive(_ line: DictationRouteLine) async {
        let raw = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return }
        if mode == .live {
            if held != nil { held?.append(.line(line)); return }
            await receiveLive(raw, sequence: line.sequence, forced: Self.forcedSplits.contains(line.reason), remainingTail: line.remainingTail)
            return
        }
        if mode != .lineByLine { bufferLine(raw); return }
        pending += 1
        let pipeline = await current()
        await pipeline.submit(sequence: line.sequence, lineID: "\(sessionID)-\(line.sequence)", raw: raw, textBefore: contextBefore())
    }

    public func warm() async {
        if let lastWarm, Date().timeIntervalSince(lastWarm) < Self.warmInterval { return }
        lastWarm = Date()
        if mode == .lineByLine || mode == .live { await current().warm() } else { await cleaner.warmDictationTake() }
    }

    /// A new session: drops the outbox, lines in cleanup and the unsent take. `keepFailedTake` keeps the raw text
    /// of a take whose cleanup failed, so it is neither lost nor inserted without the user's choice.
    public func reset() async { await reset(keepFailedTake: false) }
    public func reset(keepFailedTake: Bool) async {
        let old = pipeline
        let kept = keepFailedTake ? failedText : nil
        cancelTake()
        partialSeq = nil
        pipeline = nil; terms = nil; lastWarm = nil
        sessionID = UUID().uuidString
        outbox = []; fallbacks = []; pending = 0
        nextTakeSequence = 0; takeLines = []
        endLiveRun()
        if let kept { failedText = kept; takePhase = .failed }
        await old?.reset()
        onChange?()
    }

    /// The keyboard typed (or stopped) every line up to `upTo` of session `sessionID`.
    public func acknowledge(sessionID: String, upTo: Int) {
        guard sessionID == self.sessionID else { return }
        let remaining = outbox.filter { $0.sequence > upTo }
        guard remaining.count != outbox.count else { return }
        outbox = remaining
        onChange?()
    }

    private func loadTerms() async -> [String] {
        if let terms { return terms }
        let loaded = await vocabulary()
        terms = loaded
        return loaded
    }

    private func current() async -> DictationCleanupPipeline {
        if let pipeline { return pipeline }
        let terms = await loadTerms()
        if let pipeline { return pipeline }
        var lineCleaner: any SentenceCleaning = cleaner
        #if DEBUG || LEGATO_INTERNAL
        if let scripted = debugStreamCleaner { lineCleaner = scripted }
        #endif
        let created = DictationCleanupPipeline(cleaner: lineCleaner, vocabulary: terms, timeout: mode == .live ? liveTimeout : timeout) { [weak self] line in
            await self?.deliver(line)
        }
        pipeline = created
        return created
    }

    /// Waits until every received line has reached the outbox (or `timeout` passes); true when none are pending.
    public func settle(timeout: Duration = .seconds(4)) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while pending > 0, ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(10)) }
        return pending == 0
    }

    // MARK: Take (on stop, after a pause)

    /// Whether the pause timer may run now: the Mac holds it back while the hotkey is held (release is the send).
    public func setAutoSendSuppressed(_ value: Bool) {
        guard suppressed != value else { return }
        suppressed = value
        if value { clearCountdown() } else { speechActivity() }
    }

    private func bufferLine(_ raw: String) {
        if let failed = failedText {
            // New speech after a failed cleanup: the held text and the new lines go in one take.
            takeLines.insert(failed, at: 0); failedText = nil
            retractPartial()
            if takePhase == .failed { takePhase = cleaningText == nil ? .buffering : .cleaning }
        }
        if takeLines.isEmpty, cleaningText == nil { takeTextBefore = String(contextBefore().suffix(600)) }
        takeLines.append(raw)
        onChange?()
        speechActivity()
    }

    /// New speech (a line or a live tail): the quiet timer of "after a pause" restarts from here.
    public func speechActivity() {
        clearCountdown()
        guard mode == .afterPause, !suppressed, !takeLines.isEmpty, takePhase != .cleaning else { return }
        let delay = DictationSendSetting.clampedPause(pauseSeconds())
        let now = ProcessInfo.processInfo.systemUptime
        countdownStart = now; countdownDeadline = now + delay
        let deadline = now + delay
        quietTask = Task { [weak self, clock] in
            do { try await clock.sleep(for: .seconds(delay)); await self?.autoSend(deadline: deadline) } catch {}
        }
        onChange?()
    }
    private func clearCountdown() {
        quietTask?.cancel(); quietTask = nil
        guard countdownDeadline != nil else { return }
        countdownStart = nil; countdownDeadline = nil
        onChange?()
    }
    private func autoSend(deadline: Double) async {
        guard countdownDeadline == deadline, mode == .afterPause, !suppressed else { return }
        quietTask = nil; countdownStart = nil; countdownDeadline = nil
        await sendTake()
    }

    /// Cleans the buffered take in one call and writes it once. A take already in cleanup is waited for; a failed
    /// take stays failed until `retry()` / `insertRaw()` (or new speech joins it).
    public func sendTake() async {
        clearCountdown()
        if let running = takeTask { await running.value }
        guard takePhase != .failed, !takeLines.isEmpty else { return }
        let raw = takeLines.joined(separator: " ")
        takeLines = []
        await runTake(raw)
    }
    public func finishTake() async {
        switch mode {
        case .live:
            // Stops come in take order: while later takes wait, a stop is the waited-for run's when that one's is still to
            // come, else a waiting take's (it ends once its speech went in).
            if held != nil {
                guard heldAwaitsStop else { held?.append(.stop); return }
                heldAwaitsStop = false
            } else {
                liveTakeOpen = false
            }
            await finishLive()
        // The last line is still in cleanup: the stop is done when it has been handed to the keyboard.
        case .lineByLine: _ = await settle()
        default: await sendTake()
        }
    }

    // MARK: Live (the keyboard types the run as it is spoken)

    /// The speaking head changed (the route's live tail). Words only; the head is empty when nothing is spoken.
    public func tailChanged(_ text: String) {
        guard mode == .live else { return }
        if held != nil {
            if case .tail? = held?.last { held?.removeLast() }
            held?.append(.tail(text))
            return
        }
        liveTail(text)
    }

    private func liveTail(_ text: String) {
        let head = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if head.isEmpty, liveRun == nil || liveRun?.complete == true { return }
        // Words spoken after the take's end are a new take (late segments come with an empty head).
        var run = currentLiveRun(straggler: false)
        run.setHead(head)
        publishLive(run)
    }

    /// A take began (the mic key): its speech is a run of its own. A finished run takes no more stragglers; a run that
    /// still ends (its stop waits for its last words and cleanup) has the new take's speech wait until it is complete.
    public func beginTake() {
        guard mode == .live else { return }
        if held != nil { held?.append(.begin); return }
        let stopComing = liveTakeOpen
        liveTakeOpen = true
        liveFinishedAt = nil
        guard let run = liveRun, !run.complete else { return }
        held = []
        heldAwaitsStop = stopComing
        diagnostics?("live2.take.wait", ["run": String(run.runID.prefix(8)), "stopComing": stopComing])
        // A run no take's stop will end (words that came with no take open): it ends now.
        if !stopComing, liveFinishing == nil { Task { await self.finishLive() } }
    }

    /// The run before is complete: what waited goes in, in order (what arrives meanwhile waits behind it). A waiting
    /// take's stop ends its run first, and the rest waits for that.
    private func releaseHeld() async {
        guard held != nil, !heldAwaitsStop, liveRun?.complete != false else { return }
        liveFinishedAt = nil
        while let item = held?.first {
            held?.removeFirst()
            switch item {
            case .tail(let text): liveTail(text)
            case .line(let line):
                let raw = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !raw.isEmpty { await receiveLive(raw, sequence: line.sequence, forced: Self.forcedSplits.contains(line.reason), remainingTail: line.remainingTail) }
            case .begin:
                // A take that began while this one ran without a stop: its run ends first.
                if let run = liveRun, !run.complete { held?.insert(.begin, at: 0); return await finishLive() }
                liveTakeOpen = true
                liveFinishedAt = nil
            case .stop:
                liveTakeOpen = false
                if held?.isEmpty == true { held = nil }
                return await finishLive()
            }
        }
        held = nil
    }

    /// Segment reasons that cut a sentence short (`Segmenter.maxWords`, `maxDuration`), not end it.
    private static let forcedSplits: Set<String> = ["words", "duration"]

    private func receiveLive(_ raw: String, sequence: Int, forced: Bool, remainingTail: String? = nil) async {
        var run = currentLiveRun()
        let unit = run.addFinal(key: sequence, text: raw, closes: !forced)
        // Commit the final and the provider update's residual words in one publication. A segment
        // often finalizes only the first few words of the head the keyboard already shows.
        if let remainingTail { run.setHead(remainingTail) }
        let pieces = run.drainSplitUnits()
        publishLive(run)
        for piece in pieces { await submitLive(piece.text, key: piece.key, run: run) }
        // A cut-short segment waits for the rest of its sentence, a pause fragment for the rest of its unit; the unit
        // is cleaned once, whole.
        guard let unit else { return }
        await submitLive(unit, key: sequence, run: run)
        // A straggler of a finished take: the short take is cleaned whole again with it, landing as one more diff.
        if run.complete { await cleanWholeLate(run) }
    }

    /// The keyboard started new pieces of the live run at these segments (the user typed or moved the caret between
    /// them and the words before, as in a list): no cleanup unit spans them, so each piece is cleaned on its own, and
    /// the whole-take pass is left out.
    public func livePieces(runID: String, startingAt segments: [Int]) async {
        guard mode == .live, var run = liveRun, run.runID == runID, run.runID != sealedLiveRunID else { return }
        var changed = false
        for segment in segments { changed = run.split(before: segment) || changed }
        guard changed else { return }
        let pieces = run.drainSplitUnits()
        liveRun = run
        diagnostics?("live2.pieces", ["run": String(runID.prefix(8)), "pieces": run.pieceStarts.count + 1, "closed": pieces.count])
        for piece in pieces { await submitLive(piece.text, key: piece.key, run: run) }
    }

    /// The whole-take pass for a finished take that a late segment joined (the stop could not wait for it).
    private func cleanWholeLate(_ run: LiveDictationRun) async {
        let whole = run.wholeRaw, runID = run.runID
        guard run.unitCount > 1, !run.isSplit, whole.words <= Self.wholeTakeWords else { return }
        let input = await wholeInput(whole.text)
        Task { [weak self] in
            guard let self, let text = await self.cleanWhole(input, late: true) else { return }
            // A newer straggler runs its own pass; this one is stale then. An instruction's run is not edited again.
            guard var run = self.liveRun, run.runID == runID, run.runID != self.sealedLiveRunID, !run.isSplit, run.wholeRaw.finals == whole.finals else { return }
            if run.setWhole(SentenceStart.capitalized(text, after: self.liveAnchor), finals: whole.finals) { self.publishLive(run) }
        }
    }

    /// Sends a closed unit (`key`: its last segment) to cleanup, against the text before the run and the units so far.
    private func submitLive(_ unit: String, key sequence: Int, run: LiveDictationRun) async {
        let id = liveCleanupSequence
        liveCleanupSequence += 1
        liveKeys[id] = (sequence, run.unitRange(key: sequence))
        pending += 1
        liveSubmitted[id] = .now
        // What stands before this sentence if the run were typed clean: the text before the run, then the sentences so far.
        // A sentence the segmenter closed is a sentence even when its raw words carry no final punctuation yet (they are
        // still in cleanup): the cleaner must not take it for an unfinished one and continue in lowercase.
        var prior = run.text(before: sequence)
        if let last = prior.last, last.isLetter || last.isNumber { prior += "." }
        let before = [liveAnchor, prior].filter { !$0.isEmpty }.joined(separator: liveAnchor.last?.isWhitespace == true ? "" : " ")
        let pipeline = await current()
        await pipeline.submit(sequence: id, lineID: "\(sessionID)-\(sequence)", raw: unit, textBefore: before, allowsEmpty: true)
    }

    /// An instruction is about to read the field: a live run's held cleanup lands now, whole-take pass and the wait for
    /// a final still on its way included (bounded like the stop). The run is then sealed: a late segment starts a new
    /// run, and a late unit or whole-take result is dropped, so nothing changes the field under the instruction.
    public func finishLiveRun() async {
        guard mode == .live else { return }
        await finishLive()
        guard let run = liveRun, run.complete else { return }
        sealedLiveRunID = run.runID
        liveFinishedAt = nil
    }

    /// The take ended: every sentence has landed or been left raw (waits for cleanup, bounded), and the run is complete
    /// with all cleaned sentences in one snapshot.
    /// A take of at most this many words is cleaned again as a whole when it ends, so a correction in a later sentence
    /// ("…to Tuesday." / "Uh, no sorry, Wednesday.") can replace what it corrects; the units' results are the fallback.
    public static let wholeTakeWords = 80

    /// How long the stop waits for the final segment of words still being spoken.
    private static let speakingGrace = Duration.milliseconds(1500)

    /// One end at a time: a stop while an instruction ends the run (or the other way round) waits for that end.
    @ObservationIgnored private var liveFinishing: Task<Void, Never>?

    private func finishLive() async {
        if let running = liveFinishing { return await running.value }
        let task = Task { await self.endLive() }
        liveFinishing = task
        await task.value
        liveFinishing = nil
        await releaseHeld()
    }

    private func endLive() async {
        let stoppedAt = ContinuousClock.now
        // The keyboard holds the user's keys until the take is complete (its final words, still on their way, first).
        if var run = liveRun, run.stop() { publishLive(run) }
        // Words still in the head: their final segment is on its way. It belongs in the units and the whole pass.
        let speakingDeadline = stoppedAt + Self.speakingGrace
        while let run = liveRun, !run.complete, run.isSpeaking, ContinuousClock.now < speakingDeadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        // The open unit (words since the last sentence end) is cleaned now; the wait below covers it.
        if var run = liveRun, !run.complete, let open = run.flush() {
            liveRun = run
            await submitLive(open.text, key: open.key, run: run)
        }
        // A short take of several units is also cleaned whole, in parallel with the units still in cleanup.
        var wholeTask: Task<String?, Never>?
        var wholeFinals = 0
        if let run = liveRun, !run.complete, run.unitCount > 1, !run.isSplit {
            let whole = run.wholeRaw
            if whole.words <= Self.wholeTakeWords {
                wholeFinals = whole.finals
                let input = await wholeInput(whole.text)
                wholeTask = Task { [weak self] in await self?.cleanWhole(input) }
            }
        }
        _ = await settle(timeout: liveTimeout + .seconds(1))
        // A segment that arrived during the wait opened a unit of its own: it is cleaned too (the whole call does not
        // cover it), bounded the same way.
        if var run = liveRun, !run.complete, let late = run.flush() {
            liveRun = run
            await submitLive(late.text, key: late.key, run: run)
            _ = await settle(timeout: liveTimeout + .seconds(1))
        }
        let wholeText = await wholeTask?.value
        guard var run = liveRun, !run.complete else { return }
        if let wholeText, !run.isSplit {
            let before = liveAnchor
            run.setWhole(SentenceStart.capitalized(wholeText, after: before), finals: wholeFinals)
        }
        run.finish()
        liveFinishedAt = .now
        publishLive(run)
        let parts = stoppedAt.duration(to: .now).components
        diagnostics?("live2.run.end", ["run": String(run.runID.prefix(8)), "sentences": run.finalCount, "units": run.unitCount,
                                       "whole": wholeTask == nil ? "none" : wholeText == nil ? "fallback" : "landed",
                                       "stopMs": Int(parts.seconds * 1000 + parts.attoseconds / 1_000_000_000_000_000),
                                       "chars": run.snapshot.segments.reduce(0) { $0 + $1.text.count }])
    }

    /// The cleanup call or nil once `timeout` passed.
    nonisolated private static func race(cleaner: any SentenceCleaning, input: SentenceCleanupInput, timeout: Duration) async -> Result<String, any Error>? {
        await withTaskGroup(of: Result<String, any Error>?.self) { group in
            group.addTask { do { return .success(try await cleaner.clean(input).text) } catch { return .failure(error) } }
            group.addTask { try? await Task.sleep(for: timeout); return nil }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    private func wholeInput(_ raw: String) async -> SentenceCleanupInput {
        .init(sentenceID: "\(sessionID)-whole-\(liveCleanupSequence)", sequence: liveCleanupSequence, text: raw,
              vocabulary: Array(await loadTerms().prefix(200)), dictation: .init(previousLines: [], textBeforeCursor: String(liveAnchor.suffix(600))))
    }

    /// The whole take's cleanup: the guarded text (empty: every word dropped), or nil when it failed, timed out or was
    /// rejected (the units' results stand).
    private func cleanWhole(_ input: SentenceCleanupInput, late: Bool = false) async -> String? {
        var cleaner: any SentenceCleaning = self.cleaner
        #if DEBUG || LEGATO_INTERNAL
        if let scripted = debugStreamCleaner { cleaner = scripted }
        #endif
        let started = ContinuousClock.now, raw = input.text
        let result = await Self.race(cleaner: cleaner, input: input, timeout: liveTimeout)
        var text: String?, reason = "timeout"
        switch result {
        case .success(let cleaned):
            let empty = cleaned.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !cleaned.contains(where: \.isNewline)
            let accepted = empty ? DictationCleanupGuard.acceptsDrop(raw: raw)
                : DictationTakeGuard.accepts(raw: raw, cleaned: cleaned)
            if accepted { text = empty ? "" : cleaned } else { reason = "rejected" }
        case .failure: reason = "failed"
        case nil: break
        }
        let parts = started.duration(to: .now).components
        diagnostics?("live2.whole", ["late": late, "landed": text != nil, "reason": text == nil ? reason : "", "changed": text.map { $0 != raw } as Any,
                                     "rawChars": raw.count, "chars": text?.count as Any,
                                     "ms": Int(parts.seconds * 1000 + parts.attoseconds / 1_000_000_000_000_000)])
        return text
    }

    /// A cleaned sentence is kept for the run's end (or replaces its raw words at once after it); a sentence whose
    /// cleanup failed stays raw.
    private func landLive(_ line: DictationCleanedLine) {
        let ms = liveSubmitted.removeValue(forKey: line.sequence).map { start in
            let parts = start.duration(to: .now).components
            return Int(parts.seconds * 1000 + parts.attoseconds / 1_000_000_000_000_000)
        }
        guard var run = liveRun, let (key, range) = liveKeys.removeValue(forKey: line.sequence) else { return }
        if run.runID == sealedLiveRunID {
            diagnostics?("live2.cleanup", ["landed": false, "reason": "sealed", "rawChars": line.raw.count, "ms": ms as Any])
            return
        }
        // The keyboard split the unit since it was sent: its parts are cleaned again, this joins them.
        if let now = run.unitRange(key: key), now != range {
            diagnostics?("live2.cleanup", ["landed": false, "reason": "split", "rawChars": line.raw.count, "ms": ms as Any])
            return
        }
        if line.status == .cleaned {
            // The model sometimes leaves a sentence start lowercase after a sentence end: that is fixed here.
            let before = [liveAnchor, run.text(before: key)].filter { !$0.isEmpty }.joined(separator: " ")
            let text = SentenceStart.capitalized(line.text, after: before)
            let segments = run.unitSegments(key: key)
            let shown = run.setCleaned(key: key, text: text)
            // `changed`: the cleaned unit differs from its raw words (held or not); `shown`: the target changed now.
            diagnostics?("live2.cleanup", ["landed": true, "changed": text != line.raw, "dropped": text.isEmpty, "shown": shown, "held": !run.complete,
                                           "segments": segments, "rawChars": line.raw.count, "chars": text.count, "ms": ms as Any])
            if shown { publishLive(run) } else { liveRun = run }
        } else {
            diagnostics?("live2.cleanup", ["landed": false, "reason": line.reason ?? "raw", "detail": line.detail ?? "", "rawChars": line.raw.count, "ms": ms as Any])
        }
    }

    /// The run in progress, or a new one when none runs or the last is complete.
    private func currentLiveRun(straggler: Bool = true) -> LiveDictationRun {
        // A segment can reach the sink after the take's end was seen (its event is still on its way): it belongs to the run.
        let late = straggler && liveFinishedAt.map { $0.duration(to: .now) < Self.liveStragglerGrace } == true
        if let run = liveRun, !run.complete || late { return run }
        liveHistoryFallbacks = []
        let run = LiveDictationRun()
        liveRun = run
        liveAnchor = String(contextBefore().suffix(600))
        diagnostics?("live2.run.start", ["run": String(run.runID.prefix(8))])
        return run
    }

    private func publishLive(_ run: LiveDictationRun) {
        liveRun = run
        onLiveChange?(run.snapshot)
        checkpointLiveHistory(run)
    }

    /// Capture finalized speech only. Head updates do no disk work, and queued snapshots retain their run's ID
    /// across a reset or the next take. Serialize writes so an older checkpoint cannot replace a newer cleanup.
    private func checkpointLiveHistory(_ run: LiveDictationRun) {
        guard groupsLiveHistory, let history, keepsTakes(), let id = UUID(uuidString: run.runID) else { return }
        let raw = run.wholeRaw.text
        guard !raw.isEmpty else { return }
        let text = run.snapshot.segments.filter(\.final).map(\.text).filter { !$0.isEmpty }.joined(separator: " ")
        let entry = DictationEntry(id: id, date: lastLiveHistory.flatMap { $0.id == id ? $0.date : nil } ?? Date(),
            text: text, rawText: text == raw ? nil : raw, localeIdentifier: Locale.current.identifier,
            engineID: "dictation", duration: 0, cleanupFallback: liveHistoryFallbacks.isEmpty ? nil : true)
        guard entry != lastLiveHistory else { return }
        lastLiveHistory = entry
        let previous = liveHistoryWrite
        liveHistoryWrite = Task { [weak self] in
            await previous?.value
            do {
                try await history.upsert(entry)
                self?.historyRevision += 1
            } catch {}
        }
    }

    /// Wait for captured history checkpoints (independent of provider cleanup or field delivery).
    func settleHistory() async { await liveHistoryWrite?.value }

    private func endLiveRun() {
        liveSubmitted = [:]; liveKeys = [:]; liveFinishedAt = nil
        held = nil; heldAwaitsStop = false; liveTakeOpen = false
        guard liveRun != nil else { return }
        liveRun = nil
        onLiveChange?(nil)
    }

    /// The user chose Retry after a failed cleanup.
    public func retry() async {
        guard takePhase == .failed, let raw = failedText else { return }
        failedText = nil
        retractPartial()
        await runTake(raw)
    }

    /// The user chose Insert as-is after a failed cleanup: the raw text is delivered, once.
    public func insertRaw() async {
        guard takePhase == .failed, let raw = failedText else { return }
        failedText = nil
        retractPartial()
        takePhase = cleaningText == nil ? .buffering : .cleaning
        deliverTake(raw: raw, text: raw, cleaned: false)
        speechActivity()
    }

    /// Drops the unsent take and the failed text: nothing is typed.
    public func discardTake() {
        cancelTake()
        takeLines = []
        onChange?()
    }
    private func cancelTake() {
        // A take cut short keeps what it typed: its delivery is final as it stands.
        for i in outbox.indices where !outbox[i].final { outbox[i].final = true }
        streamSeq = nil; streamed = ""
        notifyTask?.cancel(); notifyTask = nil
        takeGeneration += 1
        takeTask?.cancel(); takeTask = nil
        clearCountdown()
        cleaningText = nil; failedText = nil; takePhase = .buffering
    }

    private func runTake(_ raw: String) async {
        cleaningText = raw; takePhase = .cleaning
        onChange?()
        let generation = takeGeneration
        let id = "\(sessionID)-t\(nextTakeSequence)", recent = recentTakes.correctionPairs(), before = takeTextBefore
        var forcedFailure = false
        #if DEBUG || LEGATO_INTERNAL
        if debugFailTakes > 0 { debugFailTakes -= 1; forcedFailure = true }
        #endif
        var takeCleaner: any SentenceCleaning = self.cleaner
        #if DEBUG || LEGATO_INTERNAL
        if let scripted = debugStreamCleaner { takeCleaner = scripted }
        #endif
        let cleaner = DictationTakeCleaner(cleaner: takeCleaner, timeout: takeTimeout ?? { DictationTakeLimits.timeout(characters: $0) })
        let entryID = takeEntry?.raw == raw ? takeEntry?.id ?? UUID() : UUID()
        takeEntry = (raw, entryID)
        let task = Task { @MainActor [weak self] in
            await self?.save(id: entryID, raw: raw, text: raw)
            var result = DictationTakeCleanupResult.failed(reason: "forced")
            var rejected = false
            if !forcedFailure, let terms = await self?.loadTerms() {
                (result, rejected) = await cleaner.cleanStreaming(
                    DictationTakeInput(takeID: id, text: raw, vocabulary: terms, recentTakes: recent, textBeforeCursor: before)
                ) { [weak self] delta in await self?.streamDelta(delta, generation: generation, raw: raw) }
            }
            guard let self, generation == self.takeGeneration else { return }
            self.takeTask = nil
            self.cleaningText = nil
            switch result {
            case .cleaned(let text):
                self.takePhase = .buffering
                self.finishStream(raw: raw, text: text, rejected: rejected)
                await self.save(id: entryID, raw: raw, text: rejected ? raw : text, fallback: rejected)
            case .unavailable:
                self.takePhase = .buffering
                self.deliverTake(raw: raw, text: raw, cleaned: false)
            case .failed(let reason):
                // Text already streamed stays in the field until Retry / Insert as-is erases it.
                if let seq = self.streamSeq, let i = self.outbox.firstIndex(where: { $0.sequence == seq }) {
                    self.outbox[i].failed = true; self.partialSeq = seq
                }
                self.streamSeq = nil; self.streamed = ""
                self.failedText = raw; self.takePhase = .failed
                self.fallbacks.append("take-" + reason); if self.fallbacks.count > 20 { self.fallbacks.removeFirst() }
                self.onChange?()
                await self.save(id: entryID, raw: raw, text: raw, fallback: true)
            }
            self.speechActivity()
        }
        takeTask = task
        await task.value
    }

    /// A piece of the take's cleaned text arrived: it is appended to the take's growing delivery (created on the first).
    private func streamDelta(_ delta: String, generation: Int, raw: String) {
        guard generation == takeGeneration, !delta.isEmpty else { return }
        streamed += delta
        if let seq = streamSeq {
            if let i = outbox.firstIndex(where: { $0.sequence == seq }) { outbox[i].text = streamed }
            notifyStream(force: false)
        } else {
            let sequence = nextTakeSequence
            nextTakeSequence += 1
            streamSeq = sequence
            outbox.append(.init(lineID: "\(sessionID)-t\(sequence)", sequence: sequence, raw: raw, text: streamed, cleaned: true, final: false, isTake: true))
            notifyStream(force: true)
        }
    }

    /// The stream ended: the delivery is final with the validated text. A result the guard rejects is not the
    /// speaker's words, so what it streamed is taken back and the raw take goes in instead.
    private func finishStream(raw: String, text: String, rejected: Bool) {
        if rejected {
            fallbacks.append("take-rejected"); if fallbacks.count > 20 { fallbacks.removeFirst() }
            Self.log.warning("take cleanup rejected by the guard; inserting the raw take")
            if let seq = streamSeq, let i = outbox.firstIndex(where: { $0.sequence == seq }) {
                outbox[i].retracted = true; outbox[i].final = true
            }
            streamSeq = nil; streamed = ""
            return deliverTake(raw: raw, text: raw, cleaned: false)
        }
        guard let seq = streamSeq else { return deliverTake(raw: raw, text: text, cleaned: true) }
        streamSeq = nil; streamed = ""
        // The delivery may be gone: the keyboard stopped typing it (the user moved on) and acknowledged.
        if let i = outbox.firstIndex(where: { $0.sequence == seq }) { outbox[i].text = text; outbox[i].final = true }
        if keepsTakes() { recentTakes.record(raw: raw, cleaned: text, wasCleaned: true) }
        notifyStream(force: true)
    }

    /// Retry and Insert as-is take back what a failed take streamed into the field.
    private func retractPartial() {
        guard let seq = partialSeq else { return }
        partialSeq = nil
        guard let i = outbox.firstIndex(where: { $0.sequence == seq }) else { return }
        outbox[i].retracted = true; outbox[i].final = true
        notifyStream(force: true)
    }

    /// Keep elapsed time and sleeps on the same injected clock, including clocks with their own Instant type.
    private static func elapsedTime<C: Clock>(on clock: C) -> @Sendable () -> Duration where C.Duration == Duration {
        let origin = clock.now
        return { origin.duration(to: clock.now) }
    }

    private func notifyStream(force: Bool) {
        let elapsed = streamTime() - lastNotify
        if force || elapsed >= Self.streamInterval {
            notifyTask?.cancel(); notifyTask = nil
            lastNotify = streamTime()
            onChange?()
        } else if notifyTask == nil {
            notifyTask = Task { [weak self, clock = self.clock] in
                try? await clock.sleep(for: Self.streamInterval - elapsed)
                guard !Task.isCancelled, let self else { return }
                self.notifyTask = nil; self.lastNotify = self.streamTime()
                self.onChange?()
            }
        }
    }

    private func deliverTake(raw: String, text: String, cleaned: Bool) {
        let sequence = nextTakeSequence
        nextTakeSequence += 1
        outbox.append(.init(lineID: "\(sessionID)-t\(sequence)", sequence: sequence, raw: raw, text: text, cleaned: cleaned, isTake: true))
        if keepsTakes() { recentTakes.record(raw: raw, cleaned: text, wasCleaned: cleaned) }
        onChange?()
    }

    private func save(id: UUID, raw: String, text: String, fallback: Bool = false) async {
        guard let history, keepsTakes() else { return }
        try? await history.upsert(DictationEntry(id: id, date: Date(), text: text, rawText: text == raw ? nil : raw,
                                                 localeIdentifier: Locale.current.identifier, engineID: "dictation", duration: 0,
                                                 cleanupFallback: fallback ? true : nil))
        historyRevision += 1
    }

    var nextOutboxSequenceForTesting: Int { nextTakeSequence }

    /// Debug bridge and tests: the take's state.
    public var takeState: [String: Any] {
        var state: [String: Any] = ["takePhase": takePhase.rawValue, "takeLength": takeLength, "takeLines": takeLines.count,
         "countdownDeadline": countdownDeadline as Any? ?? NSNull(), "mode": mode.rawValue]
        if let run = liveRun {
            state["liveRun"] = String(run.runID.prefix(8)); state["liveVersion"] = run.version
            state["liveSentences"] = run.finalCount; state["liveComplete"] = run.complete
        }
        if let held { state["liveHeld"] = held.count }
        return state
    }

    private func deliver(_ line: DictationCleanedLine) {
        pending = max(0, pending - 1)
        if mode == .live {
            landLive(line)
            if let reason = line.reason { fallbacks.append(reason); if fallbacks.count > 20 { fallbacks.removeFirst() } }
            if groupsLiveHistory {
                if line.reason != nil { liveHistoryFallbacks.insert(line.sequence) }
                else { liveHistoryFallbacks.remove(line.sequence) }
                if let run = liveRun { checkpointLiveHistory(run) }
            } else {
                Task { [weak self] in await self?.save(id: UUID(), raw: line.raw, text: line.text, fallback: line.reason != nil) }
            }
            return
        }
        outbox.append(.init(lineID: line.lineID, sequence: line.sequence, raw: line.raw, text: line.text, cleaned: line.status == .cleaned))
        if let reason = line.reason { fallbacks.append(reason); if fallbacks.count > 20 { fallbacks.removeFirst() } }
        onChange?()
        Task { [weak self] in await self?.save(id: UUID(), raw: line.raw, text: line.text, fallback: line.reason != nil) }
    }
}
