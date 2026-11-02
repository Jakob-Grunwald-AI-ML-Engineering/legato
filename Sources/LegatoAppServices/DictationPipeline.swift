import Foundation
import Observation
import LegatoAgent
import LegatoClaude
import LegatoVocabulary

/// A cleaned line waiting for the keyboard to type it.
public struct DictationDelivery: Sendable, Equatable {
    public var lineID: String
    public var sequence: Int
    public var raw: String
    public var text: String
    public var cleaned: Bool
}

/// Where a take is: collecting lines, cleaning them in one call, or holding them raw after cleanup failed twice.
public enum DictationTakePhase: String, Sendable, Equatable { case buffering, cleaning, failed }

/// The host's end of dictation. Per the send setting, either the whole take is held while the user speaks and
/// cleaned in ONE cleanup-only call (on stop, or after a pause), or (line by line) every finalized line goes
/// through its own call (`DictationCleanupPipeline`). Either way the result waits in an ordered outbox until the
/// writer or keyboard acknowledges having typed it. The keyboard session resets it when the keyboard disappears.
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
    /// Everything the take holds, for display: failed or cleaning text first, then the buffer.
    public var takeDisplay: String {
        ([failedText ?? cleaningText] + takeLines).compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
    }
    /// Characters in `takeDisplay`.
    public var takeLength: Int { takeDisplay.count }
    /// The field's text before the cursor now (the keyboard reports it with its presence).
    @ObservationIgnored public var contextBefore: @MainActor () -> String = { "" }
    /// Called when the outbox changed.
    @ObservationIgnored public var onChange: (@MainActor () -> Void)?
    @ObservationIgnored private let cleaner: any SentenceCleaning
    @ObservationIgnored private let vocabulary: @Sendable () async -> [String]
    @ObservationIgnored private let timeout: Duration
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
    @ObservationIgnored private var sentChunks: [String] = []
    @ObservationIgnored private var nextTakeSequence = 0
    @ObservationIgnored private var suppressed = false
    #if DEBUG || LEGATO_INTERNAL
    /// Debug bridge: the next this many take cleanups fail (both attempts), so the failed state is reachable offline.
    @ObservationIgnored public var debugFailTakes = 0
    #endif
    /// The prompt cache lives 5 minutes after its last use.
    private static let warmInterval: TimeInterval = 240

    /// `defaults` holds the send setting: the Mac app's standard defaults, or the App Group on iOS.
    public convenience init(vocabularyURL: URL, defaults: UserDefaults = .standard) {
        self.init(cleaner: SentenceCleanupClient(client: MessagesStream(keyStore: KeychainKeyStore())),
                  vocabulary: { (try? await VocabularyStore(fileURL: vocabularyURL).snapshot().entries.filter { !$0.blocked }.map(\.text)) ?? [] },
                  sendMode: { DictationSendSetting.mode(in: defaults) }, pauseSeconds: { DictationSendSetting.pause(in: defaults) })
    }
    public init(cleaner: any SentenceCleaning, vocabulary: @escaping @Sendable () async -> [String] = { [] },
                timeout: Duration = .milliseconds(2500),
                sendMode: @escaping @MainActor () -> DictationSendSetting.Mode = { .lineByLine },
                pauseSeconds: @escaping @MainActor () -> Double = { DictationSendSetting.defaultPause },
                clock: any Clock<Duration> = ContinuousClock(),
                takeTimeout: (@Sendable (Int) -> Duration)? = nil) {
        self.cleaner = cleaner; self.vocabulary = vocabulary; self.timeout = timeout
        self.sendMode = sendMode; self.pauseSeconds = pauseSeconds; self.clock = clock; self.takeTimeout = takeTimeout
    }

    /// The send setting now; `lineByLine` keeps the per-line path.
    public var mode: DictationSendSetting.Mode { sendMode() }

    public func receive(_ line: DictationRouteLine) async {
        let raw = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return }
        if mode != .lineByLine { bufferLine(raw); return }
        pending += 1
        let pipeline = await current()
        await pipeline.submit(sequence: line.sequence, lineID: "\(sessionID)-\(line.sequence)", raw: raw, textBefore: contextBefore())
    }

    public func warm() async {
        if let lastWarm, Date().timeIntervalSince(lastWarm) < Self.warmInterval { return }
        lastWarm = Date()
        if mode == .lineByLine { await current().warm() } else { await cleaner.warmDictationTake() }
    }

    /// A new session: drops the outbox, lines in cleanup and the unsent take. `keepFailedTake` keeps the raw text
    /// of a take whose cleanup failed, so it is neither lost nor inserted without the user's choice.
    public func reset() async { await reset(keepFailedTake: false) }
    public func reset(keepFailedTake: Bool) async {
        let old = pipeline
        let kept = keepFailedTake ? failedText : nil
        cancelTake()
        pipeline = nil; terms = nil; lastWarm = nil
        sessionID = UUID().uuidString
        outbox = []; fallbacks = []; pending = 0
        sentChunks = []; nextTakeSequence = 0; takeLines = []
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
        let created = DictationCleanupPipeline(cleaner: cleaner, vocabulary: terms, timeout: timeout) { [weak self] line in
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
    public func finishTake() async { await sendTake() }

    /// The user chose Retry after a failed cleanup.
    public func retry() async {
        guard takePhase == .failed, let raw = failedText else { return }
        failedText = nil
        await runTake(raw)
    }

    /// The user chose Insert as-is after a failed cleanup: the raw text is delivered, once.
    public func insertRaw() async {
        guard takePhase == .failed, let raw = failedText else { return }
        failedText = nil
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
        takeGeneration += 1
        takeTask?.cancel(); takeTask = nil
        clearCountdown()
        cleaningText = nil; failedText = nil; takePhase = .buffering
    }

    private func runTake(_ raw: String) async {
        cleaningText = raw; takePhase = .cleaning
        onChange?()
        let generation = takeGeneration
        let id = "\(sessionID)-t\(nextTakeSequence)", previous = Array(sentChunks.suffix(2)), before = takeTextBefore
        var forcedFailure = false
        #if DEBUG || LEGATO_INTERNAL
        if debugFailTakes > 0 { debugFailTakes -= 1; forcedFailure = true }
        #endif
        let cleaner = DictationTakeCleaner(cleaner: self.cleaner, timeout: takeTimeout ?? { DictationTakeLimits.timeout(characters: $0) })
        let task = Task { @MainActor [weak self] in
            var result = DictationTakeCleanupResult.failed(reason: "forced")
            if !forcedFailure, let terms = await self?.loadTerms() {
                result = await cleaner.clean(DictationTakeInput(takeID: id, text: raw, vocabulary: terms, previousChunks: previous, textBeforeCursor: before))
            }
            guard let self, generation == self.takeGeneration else { return }
            self.takeTask = nil
            self.cleaningText = nil
            switch result {
            case .cleaned(let text):
                self.takePhase = .buffering
                self.deliverTake(raw: raw, text: text, cleaned: true)
            case .failed(let reason):
                self.failedText = raw; self.takePhase = .failed
                self.fallbacks.append("take-" + reason); if self.fallbacks.count > 20 { self.fallbacks.removeFirst() }
                self.onChange?()
            }
            self.speechActivity()
        }
        takeTask = task
        await task.value
    }

    private func deliverTake(raw: String, text: String, cleaned: Bool) {
        let sequence = nextTakeSequence
        nextTakeSequence += 1
        outbox.append(.init(lineID: "\(sessionID)-t\(sequence)", sequence: sequence, raw: raw, text: text, cleaned: cleaned))
        sentChunks.append(text); if sentChunks.count > 4 { sentChunks.removeFirst() }
        onChange?()
    }

    var nextOutboxSequenceForTesting: Int { nextTakeSequence }

    /// Debug bridge and tests: the take's state.
    public var takeState: [String: Any] {
        ["takePhase": takePhase.rawValue, "takeLength": takeLength, "takeLines": takeLines.count,
         "countdownDeadline": countdownDeadline as Any? ?? NSNull(), "mode": mode.rawValue]
    }

    private func deliver(_ line: DictationCleanedLine) {
        pending = max(0, pending - 1)
        outbox.append(.init(lineID: line.lineID, sequence: line.sequence, raw: line.raw, text: line.text, cleaned: line.status == .cleaned))
        if let reason = line.reason { fallbacks.append(reason); if fallbacks.count > 20 { fallbacks.removeFirst() } }
        onChange?()
    }
}
