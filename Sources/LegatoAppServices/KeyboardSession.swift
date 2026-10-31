import Foundation
import Observation
import os
import LegatoClaude
import LegatoComposerDoc
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
@MainActor @Observable public final class KeyboardSession {
    public private(set) var isOpen = false
    public var surface: AudioRoute { gate.surface }
    public var route: AudioRoute { gate.route }
    /// The dictation route's uncommitted words.
    public private(set) var dictationTail = ""
    /// Mic tap → first live tail, newest last (bounded).
    public private(set) var probes: [TapLatencyProbe.Result] = []
    @ObservationIgnored private let composer: ComposerSession
    @ObservationIgnored private let sink: any DictationRouteSink
    @ObservationIgnored private let sonioxKey: @MainActor () -> String
    @ObservationIgnored private let makeSocket: @Sendable () -> any SonioxSocket
    @ObservationIgnored private let warmConnection: @Sendable () async -> Void
    @ObservationIgnored private let now: @MainActor () -> Double
    @ObservationIgnored private var gate = AudioGate()
    @ObservationIgnored private var desired: (visible: Bool, surface: AudioRoute) = (false, .agent)
    @ObservationIgnored private var reconciling: Task<Void, Never>?
    /// Presence transitions and gate operations run strictly one after another, in arrival order.
    @ObservationIgnored private var queue: Task<Void, Never>?
    @ObservationIgnored private var dictationRoom: Room?
    @ObservationIgnored private var dictationStream: WarmStream?
    /// The started stream of the current dictation take; nil while idle (only a held connection exists).
    @ObservationIgnored private var dictationActive: SonioxClient?
    @ObservationIgnored private var dictationEvents: Task<Void, Never>?
    /// Audio routed while the dictation stream reconnects, sent once it is live (bounded to ~3 s).
    @ObservationIgnored private var dictationBacklog: [Data] = []
    @ObservationIgnored private var dictationSending = false
    @ObservationIgnored private var lineSequence = 0
    @ObservationIgnored private var probe = TapLatencyProbe()
    @ObservationIgnored private var routeClosedAt: Double?
    private static let log = Logger(subsystem: "de.gruenwald.legato", category: "keyboard-session")

    public convenience init(composer: ComposerSession, sink: any DictationRouteSink = DiscardingDictationSink()) {
        self.init(composer: composer, sink: sink,
                  sonioxKey: { (try? KeychainKeyStore(service: "de.gruenwald.legato.soniox").apiKey()) ?? "" },
                  makeSocket: { URLSessionSonioxSocket() }, warmConnection: { await Self.warmClaudeConnection() })
    }
    init(composer: ComposerSession, sink: any DictationRouteSink, sonioxKey: @escaping @MainActor () -> String,
         makeSocket: @escaping @Sendable () -> any SonioxSocket, warmConnection: @escaping @Sendable () async -> Void,
         now: @escaping @MainActor () -> Double = { ProcessInfo.processInfo.systemUptime }) {
        self.composer = composer; self.sink = sink; self.sonioxKey = sonioxKey; self.makeSocket = makeSocket
        self.warmConnection = warmConnection; self.now = now
        composer.makeSocket = makeSocket
        composer.onTail = { [weak self] text in self?.observeTail(text, route: .agent) }
        composer.keyboardDiagnostics = { [weak self] in self?.diagnostics ?? [:] }
    }

    /// The keyboard's presence, read on every host link pass. Transitions run one at a time, in order.
    public func update(visible: Bool, surface: AudioRoute) {
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
            guard let self, self.isOpen, self.gate.surface == .agent else { return }
            await self.composer.prepareComposition()
        }
    }

    private func reconcileStep() async -> Bool {
        let target = desired
        if !target.visible { guard isOpen else { return false }; await close(); return true }
        if !isOpen { await open(surface: target.surface); return true }
        guard target.surface != gate.surface else { return false }
        if let action = gate.show(target.surface) { await perform(action) }
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
        await closeDictation()
        await sink.reset()
        lineSequence = 0
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
        guard isOpen else { return false }
        guard gate.route == .idle else { return true }
        let tapped = now() - max(0, tapAt.map { Date().timeIntervalSince($0) } ?? 0)
        if !composer.holdsWarmInput, !(await composer.holdWarmInput()) { return false }
        let surface = gate.surface
        let warmSince = surface == .agent ? composer.agentWarmSince : dictationStream?.liveSince
        probe.tapped(route: surface, at: tapped, warm: warmSince != nil,
                     idleS: warmSince.map { now() - max($0, routeClosedAt ?? $0) })
        _ = gate.tap()
        switch surface {
        case .agent:
            await composer.start()
            guard composer.isListening else { _ = gate.close(); probe.cancel(); return composer.error == nil }
        case .dictation:
            await activateDictation()
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
            await flushDictationBacklog()
            if let stream = dictationActive {
                dictationActive = nil
                try? await stream.sendAudio(Data(count: 6400))
                Task { try? await stream.finish(micOff: false) }
            }
        case .abandon(.agent): await composer.abandonTake()
        case .abandon(.dictation):
            composer.setRoute(.idle); dictationBacklog = []
            let active = dictationActive; dictationActive = nil
            await active?.close()
            // Drop half-spoken words: close without finalizing. Delivered lines stay with the sink.
            await closeDictation()
        case .finalize(.idle), .abandon(.idle): composer.setRoute(.idle)
        }
        probe.cancel()
    }

    // MARK: Dictation route

    private func openDictation() {
        guard dictationStream == nil else { dictationStream?.warm(); return }
        let room = Room(segmentRouting: .intercepted)
        dictationRoom = room
        dictationEvents = Task { [weak self] in
            let events = await room.subscribe(participant: .ui, channels: [.asrSegment, .asrRawTail], buffering: .unbounded)
            for await event in events {
                guard !Task.isCancelled, let self else { return }
                await self.receiveDictation(event, room: room)
            }
        }
        let socket = makeSocket, key = sonioxKey, vocabulary = composer.vocabularyURL
        let prompt = UserDefaults.standard.string(forKey: "composer.personalPrompt") ?? ""
        let stream = WarmStream(connect: { onDrop in
            let terms = (try? await VocabularyStore(fileURL: vocabulary).snapshot().entries.filter { !$0.blocked }.map(\.text)) ?? []
            let config = SonioxConfig(mode: "Dictation", personalPrompt: prompt, terms: terms)
            let client = SonioxClient(room: room, config: config, socket: socket(), quietFailure: .always, onDrop: onDrop)
            try await client.open(apiKey: key()); try await client.hold()
            return client
        }, now: now)
        dictationStream = stream; stream.warm()
    }
    /// Starts the take on the held connection (or a fresh one) and holds the next connection right away.
    private func activateDictation() async {
        if dictationStream == nil { openDictation() }
        guard dictationActive == nil, let stream = dictationStream else { return }
        guard let held = await stream.take() else { stream.warm(); return }
        stream.warm()
        do { try await held.begin(); dictationActive = held } catch { await held.close() }
    }
    private func closeDictation() async {
        let stream = dictationStream, room = dictationRoom, active = dictationActive
        dictationStream = nil; dictationRoom = nil; dictationBacklog = []; dictationActive = nil
        await active?.close()
        await stream?.close()
        dictationEvents?.cancel(); dictationEvents = nil
        try? await room?.cancel()
        if !dictationTail.isEmpty { dictationTail = "" }
    }
    private func receiveDictation(_ event: Envelope, room: Room) async {
        guard room === dictationRoom else { return }
        switch event.channel {
        case .asrSegment:
            await room.resolveSegment(event.id)
            guard let words = try? event.payload["words"]?.decode([Word].self), !words.isEmpty else { return }
            let reason = (try? event.payload["metadata"]?["reason"]?.decode(String.self)) ?? ""
            let line = DictationRouteLine(sequence: lineSequence, text: words.map(\.text).joined(separator: " "), words: words, reason: reason)
            lineSequence += 1
            await sink.receive(line)
        case .asrRawTail:
            let text = (try? event.payload["text"]?.decode(String.self)) ?? ""
            dictationTail = text
            observeTail(text, route: .dictation)
        default: break
        }
    }
    private func sendDictation(_ pcm: Data) async {
        guard gate.route == .dictation else { return }
        dictationBacklog.append(pcm)
        if dictationBacklog.count > 100 { dictationBacklog.removeFirst(dictationBacklog.count - 100) }
        if let rate = composer.routedAudioAt { probe.audioRouted(at: rate) }
        await flushDictationBacklog()
    }
    /// Audio goes out in order; a take whose stream dropped continues on the next held connection.
    private func flushDictationBacklog() async {
        guard !dictationSending else { return }
        dictationSending = true
        defer { dictationSending = false }
        while !dictationBacklog.isEmpty, dictationStream != nil {
            if dictationActive == nil { await activateDictation() }
            guard let stream = dictationActive else { return }
            let chunk = dictationBacklog.removeFirst()
            do { try await stream.sendAudio(chunk) } catch { dictationBacklog.insert(chunk, at: 0); dictationActive = nil; return }
        }
    }

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
        ["open": isOpen, "surface": gate.surface.rawValue, "route": gate.route.rawValue,
         "dictationStreamLive": dictationStream?.isLive ?? false, "dictationReconnects": dictationStream?.reconnects ?? 0,
         "probes": probes.map(\.fields)]
    }

    /// Establishes TLS/HTTP2 to the Messages API on the shared session the cleanup and writer clients use.
    /// A credential-free HEAD: no key leaves the device and nothing is billed.
    nonisolated static func warmClaudeConnection() async {
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!, timeoutInterval: 10)
        request.httpMethod = "HEAD"
        _ = try? await URLSession.shared.data(for: request)
    }
}
