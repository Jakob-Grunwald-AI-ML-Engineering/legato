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

/// One keyboard appearance owns a pre-warmed ASR connection and a dictation gate.
/// MicrophoneHost owns capture; the speech-mode switch sends words to dictation or Magic.
@MainActor @Observable public final class KeyboardSession {
    public private(set) var isOpen = false
    public private(set) var meetingSuspended = false

    /// Serialize a microphone handoff after queued presence and take operations. Keep the draft intact.
    public func suspendForMeeting() async {
        meetingSuspended = true
        microphone.microphoneReserved = true
        desired.visible = false
        await settle()
        await serial { [self] in
            if gate.route != .idle { await perform(gate.close()) }
            await takeFinish?.value
            await closeDictation()
            isOpen = false
            microphone.dictationAudio = nil
            await microphone.suspendMicrophoneForMeeting()
        }
    }

    /// A stopped meeting never implicitly rearms the microphone. A new explicit arm is required.
    public func finishMeeting() { meetingSuspended = false; microphone.microphoneReserved = false }
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
    @ObservationIgnored private let microphone: MicrophoneHost
    @ObservationIgnored private let sink: any DictationRouteSink
    /// In front of `sink`: speech in instruction mode goes to `instruction` instead.
    @ObservationIgnored private let speechRoute: DictationRouteSession
    /// The keyboard's instruction mode (the magic toggle's speech, its run, the strip).
    @ObservationIgnored public let instruction: InstructionSession
    /// The magic toggle as the keyboard last reported it: only a change acts (a debug override then stays).
    @ObservationIgnored private var reportedMagic = MagicToggle.off
    public var speechMode: SpeechMode { speechRoute.speechMode }
    @ObservationIgnored private let sonioxKey: @MainActor () -> String
    @ObservationIgnored private let makeSocket: @Sendable () -> any SonioxSocket
    @ObservationIgnored private let warmConnection: @Sendable () async -> Void
    @ObservationIgnored private let now: @MainActor () -> Double
    @ObservationIgnored private var gate = AudioGate()
    @ObservationIgnored private var desired: (visible: Bool, surface: AudioRoute) = (false, .dictation)
    @ObservationIgnored private var reconciling: Task<Void, Never>?
    /// Presence transitions and gate operations run strictly one after another, in arrival order.
    @ObservationIgnored private var queue: Task<Void, Never>?
    /// The dictation route's Soniox side (Room, held connection, take, lines into the sink).
    private var dictation: DictationEngine { speechRoute.engine }
    @ObservationIgnored private var probe = TapLatencyProbe()
    @ObservationIgnored private var routeClosedAt: Double?
    /// Waits for the stopped take's last words, then has the sink clean and write the take once.
    @ObservationIgnored private var takeFinish: Task<Void, Never>?
    /// Counts session closes: a take end still on its way from before one does nothing.
    @ObservationIgnored private var takeGeneration = 0
    #if DEBUG || LEGATO_INTERNAL
    /// Debug bridge: its lines stand for a take since the last stop (the first line after one begins a take).
    @ObservationIgnored private var debugTakeOpen = false
    #endif
    private static let log = Logger(subsystem: "de.gruenwald.legato", category: "keyboard-session")

    public convenience init(microphone: MicrophoneHost, sink: any DictationRouteSink = DiscardingDictationSink(), instruction: InstructionSession? = nil) {
        self.init(microphone: microphone, sink: sink, instruction: instruction ?? InstructionSession(vocabularyURL: microphone.vocabularyURL),
                  sonioxKey: { (try? KeychainKeyStore(service: "de.gruenwald.legato.soniox").apiKey()) ?? "" },
                  makeSocket: { URLSessionSonioxSocket() }, warmConnection: { await Self.warmClaudeConnection() })
    }
    #if DEBUG || LEGATO_INTERNAL
    /// Native keyboard acceptance with synthetic speech and an injected instruction runner. Neither provider can connect.
    public static func offlineFixture(microphone: MicrophoneHost, sink: any DictationRouteSink, instruction: InstructionSession) -> KeyboardSession {
        KeyboardSession(microphone: microphone, sink: sink, instruction: instruction, sonioxKey: { "" },
                        makeSocket: { OfflineKeyboardSocket() }, warmConnection: {})
    }
    #endif

    init(microphone: MicrophoneHost, sink: any DictationRouteSink, instruction: InstructionSession? = nil, sonioxKey: @escaping @MainActor () -> String,
         makeSocket: @escaping @Sendable () -> any SonioxSocket, warmConnection: @escaping @Sendable () async -> Void,
         now: @escaping @MainActor () -> Double = { ProcessInfo.processInfo.systemUptime }) {
        self.microphone = microphone; self.sink = sink; self.sonioxKey = sonioxKey; self.makeSocket = makeSocket
        self.warmConnection = warmConnection; self.now = now
        self.instruction = instruction ?? InstructionSession(runner: InstructionRunner(client: MessagesStream(keyStore: KeychainKeyStore()), model: { .haiku }))
        speechRoute = DictationRouteSession(sink: sink, instruction: self.instruction, sonioxKey: sonioxKey,
                                           makeSocket: makeSocket, vocabularyURL: microphone.vocabularyURL, now: now)
        // The keyboard's field link needs time to observe the settled run before Magic reads it.
        speechRoute.afterDictationSettled = { try? await Task.sleep(for: .milliseconds(150)) }
        dictation.onTail = { [weak self] text in self?.observeTail(text, route: .dictation) }
    }

    /// The keyboard's presence, read on every host link pass. Transitions run one at a time, in order.
    public func update(visible: Bool, surface: AudioRoute) {
        guard !meetingSuspended else { return }
        desired = (visible, surface == .idle ? .dictation : surface)
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
        microphone.dictationAudio = { [weak self] pcm in await self?.sendDictation(pcm) }
        let warmConnection = self.warmConnection
        Task.detached { await warmConnection() }
        _ = await microphone.holdWarmInput()
        await warm(surface)
        Self.log.info("keyboard.session.open surface=\(surface.rawValue, privacy: .public) input=\(self.microphone.holdsWarmInput ? 1 : 0)")
    }

    private func close() async {
        if let action = gate.abandon() { await perform(action) }
        isOpen = false; probe.cancel()
        // The take is the keyboard appearance's: closing mid-take drops what was not sent.
        takeFinish?.cancel(); takeFinish = nil; takeGeneration += 1
        #if DEBUG || LEGATO_INTERNAL
        debugTakeOpen = false
        #endif
        reportedMagic = .off
        await closeDictation()
        await speechRoute.reset()
        dictation.resetSequence()
        microphone.dictationAudio = nil
        await microphone.endKeyboardSession()
        Self.log.info("keyboard.session.close")
    }

    private func warm(_ surface: AudioRoute) async {
        switch surface {
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
        guard !meetingSuspended, !microphone.microphoneReserved, isOpen else { return false }
        guard gate.route == .idle else { return true }
        let tapped = now() - max(0, tapAt.map { Date().timeIntervalSince($0) } ?? 0)
        if !microphone.holdsWarmInput, !(await microphone.holdWarmInput()) { return false }
        let surface = gate.surface
        let warmSince = dictation.liveSince
        probe.tapped(route: surface, at: tapped, warm: warmSince != nil,
                     idleS: warmSince.map { now() - max($0, routeClosedAt ?? $0) })
        _ = gate.tap()
        microphone.beginTakeBuffer(for: surface)
        // Before any chunk routes: the headset's mic for this take (the idle hold prefers the built-in one).
        await microphone.preferTakeInput()
        switch surface {
        case .dictation:
            // A take of its own: its words never join the previous take's run (which may still be ending).
            speechRoute.beginTake()
            await dictation.activate()
            if let failure = microphone.takeBufferFailure {
                await dictation.abandonTake()
                microphone.discardTakeBuffer(); _ = gate.close(); probe.cancel()
                dictationNotice = failure.localizedDescription; dictationNoticeID += 1
                return true
            }
            guard dictation.hasActiveTake else {
                // No stream to talk to (no or unreachable Soniox): do not pretend to listen.
                microphone.discardTakeBuffer()
                _ = gate.close(); probe.cancel(); await microphone.preferIdleInput()
                dictationNotice = sonioxKey().isEmpty
                    ? "Add your Soniox key in the Legato app to dictate."
                    : "Can't reach Soniox. Check your connection and key, then try again."
                dictationNoticeID += 1
                return true
            }
            microphone.setRoute(.dictation)
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
        case .finalize(.dictation):
            microphone.setRoute(.idle)
            await dictation.finalizeTake()
            finishDictationTake(waitingForWords: true)
        case .abandon(.dictation):
            microphone.setRoute(.idle)
            // Drop half-spoken words: close without finalizing. Delivered lines stay with the sink.
            await dictation.abandonTake()
        case .finalize(.idle), .abandon(.idle): microphone.setRoute(.idle)
        }
        // Closing (or abandoning) a take: back to the built-in mic so the headset leaves call mode.
        if case .open = action {} else { await microphone.preferIdleInput() }
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
        let cut = gate.route == .dictation || dictation.hasActiveTake || dictation.isReplaying
        speechRoute.setMagic(toggle.isOn, cut: cut)
    }

    /// A tap on the instruction strip.
    public func handle(_ intent: InstructionIntent) { instruction.handle(intent) }

    // MARK: Dictation route

    private func openDictation() { dictation.open() }
    /// Ends a take: after its last words (bounded), the sink cleans and writes it. Ends run in take order, and a later
    /// stop never cancels an earlier take's end (that take would never complete); only closing the session does.
    private func finishDictationTake(waitingForWords: Bool) {
        let dictation = self.dictation, sink = self.sink
        let previous = takeFinish, generation = takeGeneration
        takeFinish = Task { [weak self] in
            if waitingForWords { await dictation.waitForFinish(timeout: .seconds(3)) }
            await previous?.value
            guard !Task.isCancelled, self?.takeGeneration == generation else { return }
            await sink.finishTake()
        }
    }
    private func closeDictation() async { await dictation.close() }
    private func sendDictation(_ pcm: Data) async {
        guard gate.route == .dictation else { return }
        if let rate = microphone.routedAudioAt { probe.audioRouted(at: rate) }
        await dictation.send(pcm)
    }

    #if DEBUG || LEGATO_INTERNAL
    /// Debug bridge: a finalized line enters the dictation route exactly where a Soniox segment does
    /// (the sink), so cleanup, the link and keyboard typing run for real. Requires the open dictation surface.
    /// The first line or tail after a stop begins a take, as the mic key does before real speech.
    public func debugDictationLine(_ text: String) async throws {
        guard isOpen, gate.surface == .dictation else { throw DebugDictationError.notOnDictationSurface }
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { throw DebugDictationError.empty }
        beginDebugTake()
        guard await dictation.debugLine(text) else { throw DebugDictationError.empty }
    }
    /// Debug bridge: sets (or with empty text clears) the dictation route's live partial.
    public func debugDictationTail(_ text: String) throws {
        guard isOpen, gate.surface == .dictation else { throw DebugDictationError.notOnDictationSurface }
        if !text.trimmingCharacters(in: .whitespaces).isEmpty { beginDebugTake() }
        dictation.debugTail(text)
    }
    /// Debug bridge: ends the take as the mic key's stop does (no microphone is involved), so the held take is
    /// cleaned and written now. The next line begins a new take.
    public func debugDictationStop() throws {
        guard isOpen, gate.surface == .dictation else { throw DebugDictationError.notOnDictationSurface }
        dictation.debugTail("")
        debugTakeOpen = false
        finishDictationTake(waitingForWords: false)
    }
    private func beginDebugTake() {
        guard !debugTakeOpen else { return }
        debugTakeOpen = true
        speechRoute.beginTake()
    }
    /// Debug bridge: replays a recorded Soniox token timeline into the dictation route (no microphone), then ends the
    /// take as the mic key's stop does. Returns when the take is written.
    public func debugDictationReplay(_ timeline: DictationReplayTimeline, speed: Double = 1, pcm: DictationReplayPCM? = nil) async throws {
        guard isOpen, gate.surface == .dictation else { throw DebugDictationError.notOnDictationSurface }
        speechRoute.beginTake()
        debugTakeOpen = false
        try await dictation.debugReplay(timeline, speed: speed, pcm: pcm)
        try Task.checkCancellation()
        await dictation.waitForFinish(timeout: .seconds(3))
        try Task.checkCancellation()
        await sink.finishTake()
    }
    /// Joins only the synthetic input clock; an already-started downstream cleanup retains its own lifetime.
    public func cancelDebugDictationReplay() async { await dictation.cancelDebugReplay() }
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
        if let audio = microphone.routedAudioAt { probe.audioRouted(at: audio) }
        guard let result = probe.tail(text, route: route, at: now()) else { return }
        probes.append(result)
        if probes.count > 20 { probes.removeFirst(probes.count - 20) }
        Self.log.info("probe.tap.tail route=\(result.route.rawValue, privacy: .public) warm=\(result.warm ? 1 : 0) idleS=\(result.idleS ?? -1) tapToGateMs=\(result.tapToGateMs) tapToAudioMs=\(result.tapToAudioMs ?? -1) tapToTailMs=\(result.tapToTailMs)")
    }

    public var diagnostics: [String: Any] {
        ["open": isOpen, "surface": gate.surface.rawValue, "route": gate.route.rawValue, "speechMode": speechRoute.speechMode.rawValue,
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

#if DEBUG || LEGATO_INTERNAL
private actor OfflineKeyboardSocket: SonioxSocket {
    func connect(request: URLRequest) async throws { throw CancellationError() }
    func send(_ frame: SonioxFrame) async throws { throw CancellationError() }
    func receive() async throws -> SonioxFrame { throw CancellationError() }
    func close() async {}
}
#endif
