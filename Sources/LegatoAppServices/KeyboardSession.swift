import Foundation
import Observation
import os
import LegatoAgent
import LegatoClaude
import LegatoComposerDoc
import LegatoKeyboardCore
import LegatoRoom
import LegatoSoniox
import LegatoVocabulary

/// One keyboard appearance on the host. Appearing pre-warms the held microphone input (audio discarded
/// while the gate is idle), the current surface's Soniox stream and the Claude connection; the composer
/// surface also builds its composition (cleanup pipeline and writer). A mic tap only opens the gate.
/// Disappearing closes everything: composition, writer conversation, cleanup and dictation context.
///
/// Surfaces decide routes: typing → `dictation`, whose finalized lines go to a `DictationRouteSink`
/// through a Room of their own; composer → `agent`, the existing composition. Dictation audio never
/// reaches the composition.
///
/// On the dictation route the keyboard's magic toggle tags speech (`SpeechModeSink`): dictation goes to the sink,
/// instruction speech to `instruction`, which runs it when the toggle goes off.
@MainActor @Observable public final class KeyboardSession {
    public private(set) var isOpen = false
    public private(set) var meetingSuspended = false

    /// Serialize a microphone handoff after queued presence and take operations. Keep the draft intact.
    public func suspendForMeeting() async {
        meetingSuspended = true
        composer.microphoneReserved = true
        desired.visible = false
        await settle()
        await serial { [self] in
            if gate.route != .idle { await perform(gate.close()) }
            await takeFinish?.value
            await closeDictation()
            isOpen = false
            composer.dictationAudio = nil
            await composer.suspendMicrophoneForMeeting()
        }
    }

    /// A stopped meeting never implicitly rearms the microphone. A new explicit arm is required.
    public func finishMeeting() { meetingSuspended = false; composer.microphoneReserved = false }
    public var surface: AudioRoute { gate.surface }
    public var route: AudioRoute { gate.route }
    /// The dictation route's uncommitted words.
    public var dictationTail: String { dictation.tail }
    public var dictationVoiceIsolationStatus: String? { gate.route == .dictation ? dictation.voiceIsolationStatus : nil }
    /// Why the last dictation tap could not start (shown in the keyboard's word row); `dictationNoticeID` changes
    /// with every new notice so the same text can show again.
    public private(set) var dictationNotice: String?
    public private(set) var dictationNoticeID = 0
    /// Mic tap → first live tail, newest last (bounded).
    public private(set) var probes: [TapLatencyProbe.Result] = []
    @ObservationIgnored private let composer: ComposerSession
    @ObservationIgnored private let sink: any DictationRouteSink
    /// In front of `sink`: speech in instruction mode goes to `instruction` instead.
    @ObservationIgnored private let modeSink: SpeechModeSink
    /// The keyboard's instruction mode (the magic toggle's speech, its run, the strip).
    @ObservationIgnored public let instruction: InstructionSession
    /// The live run being ended for an instruction (`finishLiveRun`), awaited before the field is read.
    @ObservationIgnored private var finishingDictation: Task<Void, Never>?
    /// The magic toggle as the keyboard last reported it: only a change acts (a debug override then stays).
    @ObservationIgnored private var reportedMagic = MagicToggle.off
    /// Applies the toggle's change when the stream's cut does not come through in time.
    @ObservationIgnored private var cutTimeout: Task<Void, Never>?
    public var speechMode: SpeechMode { modeSink.target }
    @ObservationIgnored private let sonioxKey: @MainActor () -> String
    @ObservationIgnored private let makeSocket: @Sendable () -> any SonioxSocket
    @ObservationIgnored private let warmConnection: @Sendable () async -> Void
    @ObservationIgnored private let now: @MainActor () -> Double
    @ObservationIgnored private var gate = AudioGate()
    @ObservationIgnored private var desired: (visible: Bool, surface: AudioRoute) = (false, .agent)
    @ObservationIgnored private var reconciling: Task<Void, Never>?
    /// Presence transitions and gate operations run strictly one after another, in arrival order.
    @ObservationIgnored private var queue: Task<Void, Never>?
    /// The dictation route's Soniox side (Room, held connection, take, lines into the sink).
    @ObservationIgnored private let dictation: DictationEngine
    @ObservationIgnored private var probe = TapLatencyProbe()
    @ObservationIgnored private var routeClosedAt: Double?
    /// Waits for the stopped take's last words, then has the sink clean and write the take once.
    @ObservationIgnored private var takeFinish: Task<Void, Never>?
    private static let log = Logger(subsystem: "de.gruenwald.legato", category: "keyboard-session")

    public convenience init(composer: ComposerSession, sink: any DictationRouteSink = DiscardingDictationSink(), instruction: InstructionSession? = nil) {
        self.init(composer: composer, sink: sink, instruction: instruction ?? InstructionSession(vocabularyURL: composer.vocabularyURL),
                  sonioxKey: { (try? KeychainKeyStore(service: "de.gruenwald.legato.soniox").apiKey()) ?? "" },
                  makeSocket: { URLSessionSonioxSocket() }, warmConnection: { await Self.warmClaudeConnection() })
    }
    init(composer: ComposerSession, sink: any DictationRouteSink, instruction: InstructionSession? = nil, sonioxKey: @escaping @MainActor () -> String,
         makeSocket: @escaping @Sendable () -> any SonioxSocket, warmConnection: @escaping @Sendable () async -> Void,
         now: @escaping @MainActor () -> Double = { ProcessInfo.processInfo.systemUptime }) {
        self.composer = composer; self.sink = sink; self.sonioxKey = sonioxKey; self.makeSocket = makeSocket
        self.warmConnection = warmConnection; self.now = now
        self.instruction = instruction ?? InstructionSession(runner: InstructionRunner(client: MessagesStream(keyStore: KeychainKeyStore()), model: { .haiku }))
        modeSink = SpeechModeSink(dictation: sink)
        composer.makeSocket = makeSocket
        dictation = DictationEngine(sink: modeSink, sonioxKey: sonioxKey, makeSocket: makeSocket, vocabularyURL: composer.vocabularyURL, now: now)
        let instructionSession = self.instruction
        modeSink.onInstructionLine = { line in instructionSession.hear(line) }
        modeSink.onInstructionTail = { text in instructionSession.hearTail(text) }
        let pipeline = sink as? DictationPipeline
        modeSink.onTransition = { [weak self] transition in
            if transition.to == .instruction {
                instructionSession.begin()
                // Every dictation word before the cut is in: the run ends now (its held cleanup and whole-take pass run
                // while the instruction is spoken), and nothing of the instruction's speech can join it.
                if let pipeline { self?.finishingDictation = Task { await pipeline.finishLiveRun() } }
            } else { instructionSession.end() }
        }
        if instructionSession.beforeRun == nil, let pipeline {
            // The dictation just before the instruction lands first (a live run's cleanup is held until its end), then
            // the field is read.
            instructionSession.beforeRun = { [weak self] in
                if let finishing = self?.finishingDictation { await finishing.value } else { await pipeline.finishLiveRun() }
                self?.finishingDictation = nil
                _ = await pipeline.settle(timeout: .seconds(3))
                try? await Task.sleep(for: .milliseconds(150))
            }
        }
        dictation.onTail = { [weak self] text in self?.observeTail(text, route: .dictation) }
        composer.onTail = { [weak self] text in self?.observeTail(text, route: .agent) }
        composer.keyboardDiagnostics = { [weak self] in self?.diagnostics ?? [:] }
    }

    /// The keyboard's presence, read on every host link pass. Transitions run one at a time, in order.
    public func update(visible: Bool, surface: AudioRoute) {
        guard !meetingSuspended else { return }
        desired = (visible, surface == .idle ? .agent : surface)
        guard reconciling == nil, visible != isOpen || (visible && desired.surface != gate.surface) else { return }
        reconciling = Task { [weak self] in
            while let self, await self.serial({ await self.reconcileStep() }) {}
            self?.reconciling = nil
        }
    }
    /// Finishes queued presence transitions and gate operations.
    public func settle() async {
        while let task = reconciling { await task.value }
        await queue?.value
    }
    private func serial<T: Sendable>(_ body: @escaping @MainActor () async -> T) async -> T {
        let previous = queue
        let task = Task { @MainActor in await previous?.value; return await body() }
        queue = Task { _ = await task.value }
        return await task.value
    }
    /// The composition was cleared (✕, New topic): build the next one now so the next tap stays warm.
    public func rewarm() async {
        await serial { [weak self] in
            guard let self, !self.meetingSuspended, self.isOpen, self.gate.surface == .agent else { return }
            await self.composer.prepareComposition()
        }
    }

    private func reconcileStep() async -> Bool {
        let target = desired
        if meetingSuspended { return false }
        if !target.visible { guard isOpen else { return false }; await close(); return true }
        if !isOpen { await open(surface: target.surface); return true }
        guard target.surface != gate.surface else { return false }
        if let action = gate.show(target.surface) {
            await perform(action)
            // Leaving the typing surface mid-take: the words already final are written, not lost.
            if action == .abandon(.dictation) { finishDictationTake(waitingForWords: false) }
        }
        await cool(except: gate.surface)
        await warm(gate.surface)
        return true
    }

    private func open(surface: AudioRoute) async {
        isOpen = true
        gate = AudioGate(surface: surface); probe.cancel(); routeClosedAt = nil
        composer.dictationAudio = { [weak self] pcm in await self?.sendDictation(pcm) }
        let warmConnection = self.warmConnection
        Task.detached { await warmConnection() }
        _ = await composer.holdWarmInput()
        await warm(surface)
        Self.log.info("keyboard.session.open surface=\(surface.rawValue, privacy: .public) input=\(self.composer.holdsWarmInput ? 1 : 0)")
    }

    private func close() async {
        if let action = gate.abandon() { await perform(action) }
        isOpen = false; probe.cancel()
        // The take is the keyboard appearance's: closing mid-take drops what was not sent.
        takeFinish?.cancel(); takeFinish = nil
        cutTimeout?.cancel(); cutTimeout = nil; reportedMagic = .off
        await closeDictation()
        await modeSink.reset()
        instruction.reset()
        dictation.resetSequence()
        composer.dictationAudio = nil
        await composer.endKeyboardSession()
        Self.log.info("keyboard.session.close")
    }

    private func warm(_ surface: AudioRoute) async {
        switch surface {
        case .agent: await composer.prepareComposition()
        case .dictation:
            openDictation()
            // Cleanup's connection and prompt cache are warm before the first spoken line needs them.
            let sink = self.sink
            Task { await sink.warm() }
        case .idle: break
        }
    }
    private func cool(except surface: AudioRoute) async {
        if surface != .dictation { await closeDictation() }
        if surface != .agent { await composer.closeAgentStream() }
    }

    // MARK: Gate

    /// The mic key while the keyboard is open: opens the current surface's route, or finalizes the open
    /// one. `tapAt` is the keyboard's tap time. False when no input could be held (the keyboard hops).
    @discardableResult public func tap(at tapAt: Date? = nil) async -> Bool {
        if gate.route != .idle { await closeGate(); return true }
        return await openGate(tapAt: tapAt)
    }
    @discardableResult public func openGate(tapAt: Date? = nil) async -> Bool {
        await serial { [weak self] in await self?.performOpen(tapAt: tapAt) ?? false }
    }
    private func performOpen(tapAt: Date?) async -> Bool {
        guard !VoiceEnrollmentController.shared.isBusy else { return false }
        guard !meetingSuspended, !composer.microphoneReserved, isOpen else { return false }
        guard gate.route == .idle else { return true }
        let tapped = now() - max(0, tapAt.map { Date().timeIntervalSince($0) } ?? 0)
        if !composer.holdsWarmInput, !(await composer.holdWarmInput()) { return false }
        let surface = gate.surface
        let warmSince = surface == .agent ? composer.agentWarmSince : dictation.liveSince
        probe.tapped(route: surface, at: tapped, warm: warmSince != nil,
                     idleS: warmSince.map { now() - max($0, routeClosedAt ?? $0) })
        _ = gate.tap()
        composer.beginTakeBuffer(for: surface)
        // Before any chunk routes: the headset's mic for this take (the idle hold prefers the built-in one).
        await composer.preferTakeInput()
        switch surface {
        case .agent:
            await composer.start()
            guard composer.isListening else {
                composer.discardTakeBuffer()
                _ = gate.close(); probe.cancel(); await composer.preferIdleInput()
                return composer.error == nil
            }
        case .dictation:
            await dictation.activate()
            if let failure = composer.takeBufferFailure {
                await dictation.abandonTake()
                composer.discardTakeBuffer(); _ = gate.close(); probe.cancel()
                dictationNotice = failure.localizedDescription; dictationNoticeID += 1
                return true
            }
            guard dictation.hasActiveTake else {
                // No stream to talk to (no or unreachable Soniox): do not pretend to listen.
                composer.discardTakeBuffer()
                _ = gate.close(); probe.cancel(); await composer.preferIdleInput()
                dictationNotice = sonioxKey().isEmpty
                    ? "Add your Soniox key in the Legato app to dictate."
                    : "Can't reach Soniox. Check your connection and key, then try again."
                dictationNoticeID += 1
                return true
            }
            composer.setRoute(.dictation)
        case .idle: break
        }
        probe.gateOpened(at: now())
        return true
    }
    /// Tap again: stop routing and finalize (after ~200 ms of silence, as Soniox recommends). The finalized
    /// stream ends in the background once its words are final; a held, unbilled connection waits for the next tap.
    public func closeGate() async {
        await serial { [weak self] in
            guard let self else { return }
            let action = self.gate.close()
            await self.perform(action)
        }
    }

    private func perform(_ action: AudioGate.Action) async {
        routeClosedAt = now()
        switch action {
        case .open: break
        case .finalize(.agent): await composer.finalizeTake()
        case .finalize(.dictation):
            composer.setRoute(.idle)
            await dictation.finalizeTake()
            finishDictationTake(waitingForWords: true)
        case .abandon(.agent): await composer.abandonTake()
        case .abandon(.dictation):
            composer.setRoute(.idle)
            // Drop half-spoken words: close without finalizing. Delivered lines stay with the sink.
            await dictation.abandonTake()
        case .finalize(.idle), .abandon(.idle): composer.setRoute(.idle)
        }
        // Closing (or abandoning) a take: back to the built-in mic so the headset leaves call mode.
        if case .open = action {} else { await composer.preferIdleInput() }
        probe.cancel()
    }

    // MARK: Instruction mode

    /// The keyboard's presence reported the magic toggle: only a change acts on it.
    public func magicReported(_ toggle: MagicToggle) {
        guard isOpen, toggle != reportedMagic else { return }
        reportedMagic = toggle
        setMagic(toggle)
    }

    /// The magic toggle: on, speech from now on is an instruction; off, the instruction runs once its last words are
    /// through. Words on their way when it changes keep the mode they were spoken in (the stream is cut first).
    public func setMagic(_ toggle: MagicToggle) {
        guard isOpen, !meetingSuspended else { return }
        let mode: SpeechMode = toggle.isOn ? .instruction : .dictation
        guard mode != modeSink.target else { return }
        let dictation = self.dictation
        let cut = gate.route == .dictation || dictation.hasActiveTake || dictation.isReplaying
        modeSink.toggle(to: mode, cut: cut)
        guard cut else { return }
        Task { [weak self] in
            if !(await dictation.finalizeChunk()) { self?.modeSink.flushCuts() }
        }
        cutTimeout?.cancel()
        cutTimeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            self?.modeSink.flushCuts()
        }
    }

    /// A tap on the instruction strip.
    public func handle(_ intent: InstructionIntent) { instruction.handle(intent) }

    // MARK: Dictation route

    private func openDictation() { dictation.open() }
    private func finishDictationTake(waitingForWords: Bool) {
        let dictation = self.dictation, sink = self.sink
        takeFinish?.cancel()
        takeFinish = Task {
            if waitingForWords { await dictation.waitForFinish(timeout: .seconds(3)) }
            guard !Task.isCancelled else { return }
            await sink.finishTake()
        }
    }
    private func closeDictation() async { await dictation.close() }
    private func sendDictation(_ pcm: Data) async {
        guard gate.route == .dictation else { return }
        if let rate = composer.routedAudioAt { probe.audioRouted(at: rate) }
        await dictation.send(pcm)
    }

    #if DEBUG || LEGATO_INTERNAL
    /// Debug bridge: a finalized line enters the dictation route exactly where a Soniox segment does
    /// (the sink), so cleanup, the link and keyboard typing run for real. Requires the open dictation surface.
    public func debugDictationLine(_ text: String) async throws {
        guard isOpen, gate.surface == .dictation else { throw DebugDictationError.notOnDictationSurface }
        guard await dictation.debugLine(text) else { throw DebugDictationError.empty }
    }
    /// Debug bridge: sets (or with empty text clears) the dictation route's live partial.
    public func debugDictationTail(_ text: String) throws {
        guard isOpen, gate.surface == .dictation else { throw DebugDictationError.notOnDictationSurface }
        dictation.debugTail(text)
    }
    /// Debug bridge: ends the take as the mic key's stop does (no microphone is involved), so the held take is
    /// cleaned and written now.
    public func debugDictationStop() throws {
        guard isOpen, gate.surface == .dictation else { throw DebugDictationError.notOnDictationSurface }
        dictation.debugTail("")
        finishDictationTake(waitingForWords: false)
    }
    /// Debug bridge: replays a recorded Soniox token timeline into the dictation route (no microphone), then ends the
    /// take as the mic key's stop does. Returns when the take is written.
    public func debugDictationReplay(_ timeline: DictationReplayTimeline, speed: Double = 1) async throws {
        guard isOpen, gate.surface == .dictation else { throw DebugDictationError.notOnDictationSurface }
        try await dictation.debugReplay(timeline, speed: speed)
        await dictation.waitForFinish(timeout: .seconds(3))
        await sink.finishTake()
    }
    /// Debug bridge: the magic toggle as if the keyboard set it (`off`, `latched`, `held`); it stays until either changes it.
    public func debugMagic(_ toggle: MagicToggle) throws {
        guard isOpen, gate.surface == .dictation else { throw DebugDictationError.notOnDictationSurface }
        setMagic(toggle)
    }
    public enum DebugDictationError: Error, CustomStringConvertible, Sendable {
        case notOnDictationSurface, empty
        public var description: String {
            switch self {
            case .notOnDictationSurface: "Keyboard session is not open on the ABC dictation surface."
            case .empty: "Empty dictation text."
            }
        }
    }
    #endif

    // MARK: Probe

    private func observeTail(_ text: String, route: AudioRoute) {
        if let audio = composer.routedAudioAt { probe.audioRouted(at: audio) }
        guard let result = probe.tail(text, route: route, at: now()) else { return }
        probes.append(result)
        if probes.count > 20 { probes.removeFirst(probes.count - 20) }
        Self.log.info("probe.tap.tail route=\(result.route.rawValue, privacy: .public) warm=\(result.warm ? 1 : 0) idleS=\(result.idleS ?? -1) tapToGateMs=\(result.tapToGateMs) tapToAudioMs=\(result.tapToAudioMs ?? -1) tapToTailMs=\(result.tapToTailMs)")
        composer.traceProbe(result)
    }

    var diagnostics: [String: Any] {
        ["open": isOpen, "surface": gate.surface.rawValue, "route": gate.route.rawValue, "speechMode": modeSink.target.rawValue,
         "dictationStreamLive": dictation.isLive, "dictationReconnects": dictation.reconnects,
         "probes": probes.map(\.fields)]
    }

    /// Establishes TLS/HTTP2 to the Messages API on the shared session the cleanup and writer clients use.
    /// A credential-free HEAD: no key leaves the device and nothing is billed.
    public nonisolated static func warmClaudeConnection() async {
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!, timeoutInterval: 10)
        request.httpMethod = "HEAD"
        _ = try? await MessagesStream.session.data(for: request)
    }
}
