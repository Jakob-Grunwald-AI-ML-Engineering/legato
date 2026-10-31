import AVFAudio
import Foundation
import Observation
import LegatoAudio
import LegatoCore
import LegatoClaude
import LegatoAgent
import LegatoComposerDoc
import LegatoRoom
import LegatoSoniox
import LegatoVocabulary

/// Which caller asked for an Insert; recorded in the session log so a disappearing draft can be traced.
public enum ComposerInsertOrigin: String, Sendable {
    case keyboardButton = "keyboard.button", instruction = "host.instruction"
    case macPanelButton = "mac.panel.button", macShortcut = "mac.panel.shortcut", debugBridge = "debug.bridge"
}

/// Host-only session shared by the phone app and Mac panel. The keyboard receives value snapshots.
@MainActor @Observable public final class ComposerSession {
    /// Emitted only by the successful external-delivery acknowledgement boundary.
    public private(set) var successfulInsertionID: String?
    public private(set) var topicContext: TopicContext?
    public private(set) var dictationRevision = 0
    public private(set) var dictationCommit: DictationCommit?
    private var pendingDictationWordIDs: [String] = []
    private var pendingDictationRevision: Int?
    public private(set) var snapshot = DocumentSnapshot(revision: 0, lines: [])
    public private(set) var tail = ""
    public private(set) var correctionDraft: String?
    public private(set) var correctionSubmitting = false
    public private(set) var correctionCountdownStart: Double?
    public private(set) var correctionCountdownDeadline: Double?
    public private(set) var status = "idle"
    public private(set) var error: String?
    public private(set) var pendingLineIDs: Set<String> = []
    public private(set) var busy = false
    public private(set) var isMuted = false
    public private(set) var instructionDraft = ""
    public private(set) var lastInstruction = ""
    public private(set) var instructionApplying = false
    private var lastInstructionID: String?
    private var instructionCompleted = false
    private var instructionFailed = false
    /// Raw provider/transport error behind `error`, kept for logs and `composer-state`; never shown.
    public private(set) var errorDetail: String?
    public var instructionPreview: String { instructionDraft.isEmpty ? lastInstruction : instructionDraft }
    public var instructionStatus: String {
        if let hostActionNotice { return hostActionNotice }
        if instructionFailed { return "Failed" }
        if instructionCompleted { return "Done" }
        if !instructionDraft.isEmpty { return "Listening" }
        if instructionApplying { return "Applying" }
        if !lastInstruction.isEmpty { return "Done" }
        return isListening ? "Listening" : "Ready"
    }
    public private(set) var mode = ComposerMode.message
    public private(set) var sessionID: String?
    public private(set) var inputSource = "microphone.soniox"
    public private(set) var audioOrigin: Double?
    public private(set) var hunks: [AnimationHunk] = []
    /// Platform adapters bind these to the same guarded Insert flow as the visible key.
    public var hostInsertionTarget: (@MainActor () -> String?)?
    public var hostInsertionUnavailableReason: (@MainActor () -> String)?
    public var hostClearComposer: (@MainActor () async -> Void)?
    public var hostInsertDraft: (@MainActor (String) async -> ComposerHostActionResult)?
    public private(set) var hostActionNotice: String?
    @ObservationIgnored private var consumedHostActionInstructions: Set<String> = []
    public var onChange: (@MainActor () -> Void)?
    public var renderedText: String { snapshot.lines.enumerated().map { i, line in
        switch line.kind {
        case .li: "• " + line.text
        case .oli: "\(i + 1). " + line.text
        case .quote: "> " + line.text
        default: line.text
        }
    }.joined(separator: "\n") }
    public private(set) var isArmed = false
    public var isListening: Bool { status == "listening" }
    /// Where microphone chunks go while a keyboard session holds the warm input (`holdWarmInput`).
    public private(set) var route = AudioRoute.idle
    /// One microphone stream held for a whole keyboard appearance; `route` picks each chunk's destination.
    @ObservationIgnored private var warmInput: Task<Void, Never>?
    @ObservationIgnored private var warmInputToken: UUID?
    public var holdsWarmInput: Bool { warmInput != nil }
    /// The keyboard session's dictation stream; dictation-route chunks never reach this composition.
    @ObservationIgnored var dictationAudio: (@MainActor (Data) async -> Void)?
    /// Every live tail the composition shows (the keyboard session's latency probe).
    @ObservationIgnored var onTail: (@MainActor (String) -> Void)?
    /// The first chunk routed since the gate last opened (host uptime).
    @ObservationIgnored private(set) var routedAudioAt: Double?
    @ObservationIgnored private var agentRecorder: ComposerAudioRecorder?
    @ObservationIgnored private var agentWarm: WarmStream?
    /// A finalized take's stream, ending in the background once its last words are final.
    @ObservationIgnored private var retiring: Task<Void, Never>?
    /// Built ahead of the first tap (keyboard pre-warm): Room and participants exist, no take has begun.
    private var prepared = false
    @ObservationIgnored var keyboardDiagnostics: (@MainActor () -> [String: Any])?
    @ObservationIgnored var makeSocket: @Sendable () -> any SonioxSocket = { URLSessionSonioxSocket() }
    public var canUndo: Bool { lastTransactionID != nil }
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var room: Room?
    @ObservationIgnored private var sessionLog: SessionLog?
    private var inputConfig = SonioxConfig()
    private var recordingTake = 0
    private var deliveredAudioChunks = 0
    private var deliveredAudioFrames = 0
    private var acceptedASRWords = 0
    private var resuming = false
    private var preparingInsertion = false
    @ObservationIgnored private var writer: AgentRunner?
    @ObservationIgnored private var transcriber: SonioxClient?
    @ObservationIgnored private let mic: any AudioSource
    @ObservationIgnored private let activateAudioSession: @MainActor () async throws -> Void
    private var keepMicrophoneActive = true
    @ObservationIgnored private var eventsTask: Task<Void, Never>?
    @ObservationIgnored private var audioTask: Task<Void, Never>?
    @ObservationIgnored private var binder: HintBinder?
    @ObservationIgnored private var alternatives: AlternativesParticipant?
    @ObservationIgnored private var lastTransactionID: String?
    @ObservationIgnored private var busyParticipants: Set<Participant> = []
    @ObservationIgnored private let history: (any HistoryStore)?
    @ObservationIgnored private var historyWrite: Task<Bool, Never>?
    /// Bumped after every successful History write or import, so views can refresh without polling.
    public private(set) var historyRevision = 0
    private var historyID = UUID()
    private var historyDate = Date()
    private var historyQueuedText: String?
    let vocabularyURL: URL
    public init(vocabularyURL: URL = URL.applicationSupportDirectory.appending(path: "Legato/vocabulary.json"), keepMicrophoneActive: Bool = true, history: (any HistoryStore)? = nil) {
        self.history = history
        self.vocabularyURL = vocabularyURL
        #if os(iOS)
        self.keepMicrophoneActive = keepMicrophoneActive
        #else
        self.keepMicrophoneActive = false
        #endif
        self.mic = AutomaticInputSource()
        self.activateAudioSession = Self.activateMicrophoneSession
    }
    init(microphone: any AudioSource, activateAudioSession: @escaping @MainActor () async throws -> Void) {
        self.history = nil
        self.vocabularyURL = URL.applicationSupportDirectory.appending(path: "Legato/vocabulary.json")
        self.mic = microphone
        self.activateAudioSession = activateAudioSession
    }
    init(room: Room, log: SessionLog? = nil, binder: HintBinder? = nil, history: (any HistoryStore)? = nil) {
        self.history = history
        self.binder = binder
        self.room = room
        self.sessionLog = log
        self.sessionID = log?.directory.lastPathComponent
        self.mic = AutomaticInputSource()
        self.activateAudioSession = Self.activateMicrophoneSession
        self.vocabularyURL = URL.applicationSupportDirectory.appending(path: "Legato/vocabulary.json")
    }
    /// Every accepted edit checkpoints to the existing History store; empty UI resets never erase it.
    @discardableResult public func flushHistory() async -> Bool {
        let token = generation
        if let room {
            let current = await room.documentSnapshot
            guard generation == token else { return false }
            if current.revision >= snapshot.revision { snapshot = current }
        }
        return await checkpointHistory()
    }
    private func checkpointHistory() async -> Bool { await enqueueCheckpoint()?.value ?? true }
    /// Queues one ordered write of the current text; identical text is never written twice, so event
    /// bursts and polling cannot duplicate writes. A blank draft queues nothing and cannot fail.
    private func enqueueCheckpoint() -> Task<Bool, Never>? {
        guard let history else { return nil }
        let text = renderedText
        let previous = historyWrite
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            guard let previous else { return nil }
            return Task { _ = await previous.value; return true }
        }
        if historyQueuedText == text { return previous }
        let id = historyID
        let entry = DictationEntry(id: id, date: historyDate, text: text,
            localeIdentifier: Locale.current.identifier, engineID: "composer", duration: max(0, Date().timeIntervalSince(historyDate)))
        historyQueuedText = text
        let write = Task { @MainActor [weak self] in
            // Serialize across actor suspension and composition changes: an older checkpoint
            // cannot finish after, and overwrite, a newer accepted edit.
            _ = await previous?.value
            do {
                try await history.upsert(entry)
                if let self {
                    self.historyRevision += 1
                    if self.historyID == id, self.error?.hasPrefix(Self.historyErrorPrefix) == true { self.error = nil; self.onChange?() }
                }
                return true
            }
            catch {
                // Only the failing composition may report; a rotated ID means its draft was already handled.
                if let self, self.historyID == id {
                    if self.historyQueuedText == text { self.historyQueuedText = nil }
                    self.error = Self.historyErrorPrefix + " Draft kept. Check available storage and try again."
                    self.onChange?()
                }
                return false
            }
        }
        historyWrite = write
        return write
    }
    private static let historyErrorPrefix = "Couldn’t save composition to History."
    /// Imports completed microphone sessions missing from History (once per install; see ``ComposerHistoryBackfill``).
    public func backfillHistory(sessionsRoot: URL = URL.documentsDirectory.appending(path: "sessions"), markerURL: URL?) async {
        guard let history else { return }
        let current = Set([sessionID, historyID.uuidString].compactMap { $0.flatMap(UUID.init(uuidString:)) })
        if await ComposerHistoryBackfill.run(sessionsRoot: sessionsRoot, history: history, excluding: current, markerURL: markerURL) > 0 {
            historyRevision += 1
        }
    }
    /// Appends an Insert trace event to the session log. Origin and acknowledgement kind only, never text.
    /// An acknowledgement reflects the delivery mechanism's own report (for the keyboard, executed UIKit proxy
    /// operations), not independently confirmed visible text in the target app.
    public func traceInsertion(_ stage: String, origin: ComposerInsertOrigin, detail: [String: String] = [:]) async {
        guard let room else { return }
        var fields: [String: JSONValue] = ["event": .string("insert." + stage), "origin": .string(origin.rawValue),
            "characters": .number(Double(renderedText.count))]
        for (key, value) in detail { fields[key] = .string(value) }
        _ = try? await room.publish(channel: .session, participant: .ui, payload: .object(fields))
    }
    /// Keyboard latency probe results also land in the composition's session log, when there is one.
    func traceProbe(_ result: TapLatencyProbe.Result) {
        guard let room else { return }
        var fields: [String: JSONValue] = ["event": .string("probe.tap.tail"), "route": .string(result.route.rawValue), "warm": .bool(result.warm),
            "tapToGateMs": .number(Double(result.tapToGateMs)), "tapToTailMs": .number(Double(result.tapToTailMs))]
        if let idle = result.idleS { fields["idleS"] = .number(idle) }
        if let audio = result.tapToAudioMs { fields["tapToAudioMs"] = .number(Double(audio)) }
        Task { _ = try? await room.publish(channel: .session, participant: .ui, payload: .object(fields)) }
    }
    private func beginHistoryComposition() {
        historyID = UUID(); historyDate = Date(); historyQueuedText = nil
    }
    public func arm() async {
        guard !isArmed else { return }
        do {
            _ = try await prepareMicrophoneStream()
            isArmed = true; error = nil; status = "ready"; onChange?()
        } catch { fail(error) }
    }
    private static func activateMicrophoneSession() async throws {
        #if os(iOS)
        guard await AVAudioApplication.requestRecordPermission() else {
            throw NSError(domain: "Composer", code: 2, userInfo: [NSLocalizedDescriptionKey: "Allow microphone access in iOS Settings."])
        }
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default, options: [.mixWithOthers, .defaultToSpeaker, .allowBluetoothHFP])
        try session.setActive(true)
        #endif
    }
    func prepareMicrophoneStream() async throws -> AsyncStream<AudioChunk> {
        do {
            // The keyboard starts while this host is backgrounded. Reconfiguring its
            // already-live AVAudioSession can be refused with '!int'; route the held mic.
            if isArmed { return try await mic.route() }
            try await activateAudioSession()
            let stream = try await mic.start(format: .init(sampleRate: 16000, channelCount: 1))
            isArmed = keepMicrophoneActive
            return stream
        } catch {
            // A route lost to interruption is no longer an honest background lease.
            isArmed = false
            await mic.stop()
            throw error
        }
    }
    /// Changes retention only; enabling this setting never starts a microphone.
    public func setKeepMicrophoneActive(_ value: Bool) async {
        keepMicrophoneActive = value
        if !value, !isListening { isArmed = false; await mic.stop(); onChange?() }
    }
    /// Opting out stops new input on backgrounding, preserving the draft and final agent work.
    public func prepareForBackground() async {
        _ = await flushHistory()
        guard !keepMicrophoneActive else { return }
        if isListening { await stop() }
        isArmed = false; await mic.stop(); onChange?()
    }
    public func releaseMicrophone() async { isArmed = false; await releaseWarmInput(); await cancel() }
    public func start() async { await startSession(debugMode: nil, microphoneLease: false) }
    /// Keyboard pre-warm: build the composition (Room, cleanup pipeline, writer) without starting a take,
    /// then open its Soniox stream so the first tap only opens the gate.
    func prepareComposition() async {
        if room == nil { await startSession(debugMode: nil, microphoneLease: false, beginsInput: false) }
        warmAgentStream()
    }
    private func startSession(debugMode: ComposerMode?, microphoneLease: Bool, beginsInput: Bool = true) async {
        guard !isListening, status != "starting", !resuming, !preparingInsertion else { return }
        if let room, sessionLog != nil, await room.state != .done {
            guard beginsInput else { return }
            if prepared, debugMode == nil { await beginPreparedInput(room: room); return }
            await resumeSession(debug: debugMode != nil)
            return
        }
        await cancel()
        guard room == nil else { return }
        inputSource = debugMode == nil ? "microphone.soniox" : "debug.transcriber"
        audioOrigin = nil
        if debugMode != nil {
            if !microphoneLease { isArmed = false; await mic.stop() }
            else if !isArmed { await arm(); guard isArmed else { return } }
        }
        let generation = UUID(); self.generation = generation
        pendingDictationRevision = nil; pendingDictationWordIDs = []; dictationCommit = nil; snapshot = .init(revision: 0, lines: []); tail = ""; error = nil; status = "starting"; hunks = []; pendingLineIDs = []; busyParticipants = []; busy = false
        let id = UUID().uuidString; sessionID = id; historyID = UUID(uuidString: id)!
        do {
            let soniox = debugMode == nil ? (try KeychainKeyStore(service: "de.gruenwald.legato.soniox").apiKey() ?? "") : ""
            let claude = try KeychainKeyStore().apiKey() ?? ""
            let log = try SessionLog(rootDirectory: URL.documentsDirectory.appending(path: "sessions"), sessionID: id, secrets: [soniox, claude])
            let room = Room(log: log, segmentRouting: .intercepted, resumable: true, drainOnly: true); self.room = room; sessionLog = log; recordingTake = 0
            _ = try await room.publish(channel: .session, participant: .ui, payload: .object(["event": .string("input.source"), "inputSource": .string(inputSource), "microphoneLeaseActive": .bool(isArmed)]))
            guard (debugMode != nil || !soniox.isEmpty), !claude.isEmpty else {
                throw NSError(domain: "Composer", code: 1, userInfo: [NSLocalizedDescriptionKey: debugMode == nil ? "Add Claude and Soniox API keys in Settings." : "Add a Claude API key in Settings for debug transcriber UAT."])
            }
            let store = VocabularyStore(fileURL: vocabularyURL)
            let learner = VocabularyLearner(store: store, spellChecker: PlatformSpellChecker(), tagger: NLEntityTagger(), languages: ["de", "en"])
            let terms = (try? await store.snapshot().entries.filter { !$0.blocked }.map(\.text)) ?? []
            let binder = HintBinder(room: room, learner: learner, onSend: { [weak self] in await self?.sendCorrection() },
                onInstructionQuiet: { [weak self] in await self?.finalizeInstructionChunk() }, requiresExplicitSubmission: true)
            self.binder = binder
            await binder.start()
            try requireGeneration(generation)
            let alternatives = AlternativesParticipant(room: room, store: store, learner: learner); self.alternatives = alternatives; await alternatives.start(); try requireGeneration(generation)
            let defaults = UserDefaults.standard
            let prompt = defaults.string(forKey: "composer.personalPrompt") ?? ""
            mode = debugMode ?? ComposerMode(rawValue: defaults.string(forKey: "composer.mode") ?? "message") ?? .message
            let writer = AgentRunner(room: room, client: MessagesStream(keyStore: KeychainKeyStore()), configuration: .init(
                liveModel: ModelChoice(rawValue: defaults.string(forKey: "composer.liveModel") ?? "") ?? .haiku,
                mode: mode, personalPrompt: prompt, topicContext: topicContext, vocabulary: { _ in terms }, validatedSentenceInput: true, // instructions only: speech never reaches the draft, so no pause turns
                hostActionContext: { [weak self] in await self?.captureHostActionContext() },
                performHostAction: { [weak self] action in
                    guard let self else { return .init(succeeded: false, message: "Composition closed. Action discarded.") }
                    return await self.performHostAction(action)
                }))
            self.writer = writer; await writer.start(); try requireGeneration(generation)
            let eventStream = await room.subscribe(participant: .ui, channels: Set(Channel.allCases), buffering: .unbounded)
            eventsTask = Task { [weak self] in for await event in eventStream { guard !Task.isCancelled else { break }; await self?.receive(event) } }
            inputConfig = .init(mode: mode.rawValue, personalPrompt: prompt, terms: terms)
            guard beginsInput else { prepared = true; status = "ready"; onChange?(); return }
            try await beginInput(room: room, log: log, debug: debugMode != nil, soniox: soniox, generation: generation)
        } catch {
            if self.generation == generation {
                fail(error)
                // A pre-warm that cannot build (missing keys) keeps the lease; the tap reports it again.
                if beginsInput { isArmed = false }
                try? await room?.cancel(); await cleanup()
            }
        }
    }
    private func beginPreparedInput(room: Room) async {
        guard let log = sessionLog else { return }
        let token = generation
        prepared = false; status = "starting"; onChange?()
        do {
            let soniox = try KeychainKeyStore(service: "de.gruenwald.legato.soniox").apiKey() ?? ""
            guard !soniox.isEmpty else { throw SonioxError.missingKey }
            try await beginInput(room: room, log: log, debug: false, soniox: soniox, generation: token)
        } catch {
            if generation == token { route = .idle; fail(error); if await room.state == .listening { try? await room.micOff(); await room.finishTranscription() } }
        }
    }
    /// Holds the next take's Soniox connection ahead of the tap (no start request, so nothing is billed),
    /// only while a keyboard session holds the input.
    func warmAgentStream() {
        guard warmInput != nil, let room, agentWarm == nil else { return }
        let config = inputConfig, socket = makeSocket
        let warm = WarmStream { onDrop in
            let soniox = try KeychainKeyStore(service: "de.gruenwald.legato.soniox").apiKey() ?? ""
            let client = SonioxClient(room: room, config: config, socket: socket(), quietFailure: .untilAudio, onDrop: onDrop)
            try await client.open(apiKey: soniox); try await client.hold()
            return client
        }
        agentWarm = warm; warm.warm()
    }
    /// The agent stream's warm age at a tap: nil when the next take would connect cold.
    var agentWarmSince: Double? { agentWarm?.liveSince }
    func closeAgentStream() async { let warm = agentWarm; agentWarm = nil; await warm?.close() }
    private func beginInput(room: Room, log: SessionLog, debug: Bool, soniox: String, generation: UUID) async throws {
        inputSource = debug ? "debug.transcriber" : "microphone.soniox"
        #if DEBUG || LEGATO_INTERNAL
        if debug {
            let origin = ProcessInfo.processInfo.systemUptime; audioOrigin = origin
            let transcriber = SonioxClient(room: room, config: inputConfig, audioOrigin: origin)
            self.transcriber = transcriber; try await transcriber.startDebug(); try requireGeneration(generation)
            status = "listening"; onChange?(); return
        }
        #endif
        deliveredAudioChunks = 0; deliveredAudioFrames = 0; acceptedASRWords = 0
        let audioOrigin = ProcessInfo.processInfo.systemUptime; self.audioOrigin = audioOrigin
        if warmInput != nil {
            // The held input loop forwards agent chunks once the gate opens; the warm stream skips the connect.
            let warm = agentWarm; agentWarm = nil
            var transcriber = await warm?.take()
            // The start request goes out on the held connection; audio follows without waiting for a reply.
            if let held = transcriber, (try? await held.begin()) == nil { await held.close(); transcriber = nil }
            if transcriber == nil {
                let fresh = SonioxClient(room: room, config: inputConfig, socket: makeSocket(), audioOrigin: nil)
                try await fresh.start(apiKey: soniox); transcriber = fresh
            }
            await warm?.close()
            guard let transcriber else { throw SonioxError.notConnected }
            self.transcriber = transcriber; try requireGeneration(generation)
            await transcriber.setAudioOrigin(audioOrigin)
            recordingTake += 1
            let audioURL = recordingTake == 1 ? log.audioURL : log.directory.appending(path: "audio-\(recordingTake).m4a")
            agentRecorder = try ComposerAudioRecorder(url: audioURL)
            _ = try await room.publish(channel: .session, participant: .ui, payload: .object(["event": .string("audio.take"), "file": .string(audioURL.lastPathComponent), "warm": .bool(warm != nil)]))
            routedAudioAt = nil; route = .agent
            status = "listening"; onChange?()
            return
        }
        let stream = try await prepareMicrophoneStream()
        try requireGeneration(generation)
        let transcriber = SonioxClient(room: room, config: inputConfig, audioOrigin: nil)
        self.transcriber = transcriber; try await transcriber.start(apiKey: soniox); try requireGeneration(generation)
        await transcriber.setAudioOrigin(audioOrigin)
        recordingTake += 1
        let audioURL = recordingTake == 1 ? log.audioURL : log.directory.appending(path: "audio-\(recordingTake).m4a")
        let recorder = try ComposerAudioRecorder(url: audioURL)
        _ = try await room.publish(channel: .session, participant: .ui, payload: .object(["event": .string("audio.take"), "file": .string(audioURL.lastPathComponent)]))
        status = "listening"; onChange?()
        audioTask = Task { [weak self] in
            var converter = PCM16Converter()
            do {
                for await chunk in stream {
                    try Task.checkCancellation()
                    // Keep the iOS background mic lease, but never record/forward muted speech.
                    guard let self, !self.isMuted else { continue }
                    try recorder.append(chunk)
                    try await transcriber.sendAudio(converter.convert(chunk))
                    self.deliveredAudioChunks += 1; self.deliveredAudioFrames += chunk.samples.count / max(1, chunk.format.channelCount)
                }
                if !Task.isCancelled, let self, self.generation == generation, self.isListening {
                    self.fail(AutomaticInputError.noPCM); self.isArmed = false
                    await self.mic.stop()
                }
            } catch is CancellationError {} catch {
                self?.fail(error)
                self?.isArmed = false
                await self?.mic.stop()
            }
        }
    }
    func resumeSession(debug: Bool) async {
        guard let room, let log = sessionLog else { return }
        let token = generation
        resuming = true
        defer { resuming = false }
        do {
            if await room.state == .listening, !isListening {
                route = .idle; agentRecorder = nil
                audioTask?.cancel(); await audioTask?.value; audioTask = nil
                await transcriber?.cancel(); transcriber = nil
                try requireGeneration(token)
                try await room.micOff()
            }
            // A quick second tap queues continuation until ASR drain and the final
            // writing turn retire; never race a new stream against an old final pass.
            while true {
                let state = await room.state
                if state != .trailing && state != .finalPass { break }
                try requireGeneration(token)
                try await Task.sleep(for: .milliseconds(30))
            }
            try requireGeneration(token)
            guard await room.state == .paused else { return }
            await transcriber?.cancel(); transcriber = nil
            try requireGeneration(token)
            let soniox = debug ? "" : (try KeychainKeyStore(service: "de.gruenwald.legato.soniox").apiKey() ?? "")
            guard debug || !soniox.isEmpty else { throw SonioxError.missingKey }
            inputConfig = .init(mode: mode.rawValue, personalPrompt: UserDefaults.standard.string(forKey: "composer.personalPrompt") ?? "", terms: inputConfig.terms)
            try await room.resume()
            isMuted = false; error = nil; status = "starting"; onChange?()
            try await beginInput(room: room, log: log, debug: debug, soniox: soniox, generation: token)
        } catch is CancellationError {
        } catch {
            if generation == token {
                fail(error); isArmed = false; await mic.stop()
                // Retain the composition after a failed reconnect; its next Record
                // tap can retry without discarding the draft or conversation.
                if await room.state == .listening { try? await room.micOff(); await room.finishTranscription() }
            }
        }
    }
    #if DEBUG || LEGATO_INTERNAL
    /// Deterministic local draft for native UI acceptance; no provider, key or microphone.
    public func seedDebugDraft(_ text: String) async throws {
        await cancel()
        guard room == nil else { throw insertionFailure(error ?? "Could not preserve the current composition.") }
        let room = Room(resumable: true)
        self.room = room; historyID = UUID(); sessionID = historyID.uuidString; inputSource = "debug.seed"
        for line in text.components(separatedBy: "\n") where !line.isEmpty {
            _ = try await room.appendSegment(words: line.split(whereSeparator: \.isWhitespace).map { .init(text: String($0)) })
        }
        try await room.micOff(); try await room.finishFinalPass()
        snapshot = await room.documentSnapshot; status = "paused"; _ = await checkpointHistory(); onChange?()
    }
    /// Provider-free visual fixtures may edit only their own seeded Room, never a live draft.
    public func applyDebugDocumentEdits(_ json: String) async throws {
        guard inputSource == "debug.seed", let room else { throw SonioxError.notConnected }
        let ops = try JSONDecoder().decode([DocOp].self, from: Data(json.utf8))
        let before = await room.documentSnapshot
        let versions = Dictionary(uniqueKeysWithValues: before.lines.map { ($0.id, $0.version) })
        let transaction = try await room.applyDocument(ops, origin: .agent, versions: versions)
        hunks = transaction.hunks; lastTransactionID = transaction.id
        snapshot = await room.documentSnapshot
        _ = await checkpointHistory()
        onChange?()
    }
    public func startDebug(mode: ComposerMode = .message, microphoneLease: Bool = false) async {
        await startSession(debugMode: mode, microphoneLease: microphoneLease)
    }
    public func injectDebugFrame(_ json: String) async throws {
        guard inputSource == "debug.transcriber", isListening, let transcriber else { throw SonioxError.notConnected }
        try await transcriber.injectDebugFrame(json)
        // The binder owns visible partial text, including suppressing targeted speech.
        await refreshDebugState()
    }
    /// Text convenience still enters as provider tokens; it never mutates the document.
    public func injectDebugText(_ text: String, isFinal: Bool, startMs: Double, durationMs: Double = 200, confidence: Double = 0.95, language: String = "de") async throws {
        guard startMs.isFinite, startMs >= 0, durationMs.isFinite, durationMs >= 0, confidence.isFinite, (0...1).contains(confidence) else { throw SonioxError.invalidResponse }
        let words = text.split(whereSeparator: { $0.isWhitespace })
        let tokens = words.enumerated().map { index, word in SonioxToken(text: " " + word, confidence: confidence, isFinal: isFinal, startMs: startMs + Double(index) * durationMs, endMs: startMs + Double(index + 1) * durationMs, language: language) }
        let frame: JSONValue = .object(["tokens": try .encoding(tokens)])
        try await injectDebugFrame(String(decoding: JSONEncoder().encode(frame), as: UTF8.self))
    }
    public func refreshDebugState() async {
        if let room { snapshot = await room.documentSnapshot }
        onChange?()
    }
    public var debugState: [String: Any] {
        var state: [String: Any] = ["uptime": ProcessInfo.processInfo.systemUptime, "status": status, "dictating": isListening, "muted": isMuted, "microphoneLeaseActive": isArmed, "inputSource": inputSource, "instructionDraft": instructionDraft, "instructionPreview": instructionPreview, "instructionStatus": instructionStatus, "errorDetail": errorDetail ?? NSNull(),
         "sessionID": sessionID ?? "", "successfulInsertionID": successfulInsertionID as Any? ?? NSNull(), "hasTopicContext": topicContext != nil, "topicContextCharacters": (topicContext?.deliveredText.count ?? 0) + (topicContext?.pastRequests.count ?? 0), "audioOrigin": audioOrigin as Any? ?? NSNull(), "revision": snapshot.revision,
         "document": (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot))) ?? [:],
         "correctionDraft": correctionDraft as Any? ?? NSNull(),
         "correctionCountdownStart": correctionCountdownStart as Any? ?? NSNull(),
         "correctionCountdownDeadline": correctionCountdownDeadline as Any? ?? NSNull(),
         "tail": tail, "text": renderedText, "mode": mode.rawValue, "busy": busy, "pendingLineIDs": Array(pendingLineIDs), "error": error ?? ""]
        state["audioPlatform"] = (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(AutomaticInputSource.platformStatus()))) ?? [:]
        if let automatic = mic as? AutomaticInputSource {
            state["audioInput"] = (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(automatic.diagnostics))) ?? [:]
        }
        state["audioDelivery"] = ["chunks": deliveredAudioChunks, "frames": deliveredAudioFrames, "acceptedFinalWords": acceptedASRWords]
        state["audioRoute"] = route.rawValue; state["holdsWarmInput"] = warmInput != nil; state["prepared"] = prepared
        state["agentStreamWarm"] = agentWarm?.isLive ?? false
        if let keyboardDiagnostics { state["keyboardSession"] = keyboardDiagnostics() }
        return state
    }
    #endif
    private func finalizeInstructionChunk() async {
        guard isListening else { return }
        do { _ = try await transcriber?.finalizeChunk() } catch { fail(error) }
    }
    /// Logical voice mute: keep the mic lease, Room and agent work alive while dropping new input.
    public func setMuted(_ value: Bool) async {
        guard isListening, room != nil, isMuted != value else { return }
        isMuted = value; onChange?()
        let generation = self.generation
        do { try await transcriber?.setMuted(value) }
        catch { if self.generation == generation { fail(error) } }
    }
    public func stop() async {
        guard isListening else { return }
        let token = generation
        let transcriber = self.transcriber
        let room = self.room
        status = "trailing"; onChange?()
        try? await room?.micOff(transcriberDraining: true)
        if warmInput != nil { route = .idle; agentRecorder = nil }
        else { if isArmed && keepMicrophoneActive { await mic.detach() } else { isArmed = false; await mic.stop() }; audioTask?.cancel(); await audioTask?.value; audioTask = nil }
        guard generation == token else { return }
        do {
            if let transcriber { try await transcriber.finish() }
            else { await room?.finishTranscription() }
        } catch {
            guard generation == token else { return }
            fail(error)
            // A failed socket must not leave continuation waiting forever for drain.
            await room?.finishTranscription()
        }
        // The next take within this keyboard appearance starts on a stream opened now.
        if generation == token { warmAgentStream() }
    }
    /// Keyboard tap-again: stop routing and finalize. The composition stays listening for the next tap;
    /// the stream ends in the background once its words are final, and a held connection replaces it.
    func finalizeTake() async {
        guard isListening, warmInput != nil, let transcriber else { await stop(); return }
        route = .idle; agentRecorder = nil
        self.transcriber = nil
        prepared = true; status = "ready"; onChange?()
        // Soniox advises ~200 ms of silence before finalize.
        try? await transcriber.sendAudio(Data(count: 6400))
        let previous = retiring
        retiring = Task {
            await previous?.value
            try? await transcriber.finish(micOff: false)
        }
        warmAgentStream()
    }
    /// Surface switch mid-take: stop routing, drop the provider's unfinished words, and drain only what
    /// was already final, so nothing spoken here reaches another route.
    func abandonTake() async {
        guard isListening, let room else { route = .idle; return }
        let token = generation
        route = .idle; agentRecorder = nil
        status = "trailing"; onChange?()
        try? await room.micOff(transcriberDraining: true)
        let transcriber = self.transcriber; self.transcriber = nil
        await transcriber?.close()
        guard generation == token else { return }
        // Half an instruction is not an instruction: drop it rather than send it on the closing boundary.
        await binder?.discardInstruction(timestamp: ProcessInfo.processInfo.systemUptime)
        _ = try? await room.publish(channel: .asrBoundary, participant: .segmenter, payload: .object(["reason": .string("finalize")]))
        await room.finishTranscription()
    }
    /// Drain voice and authoring before the surface captures text for external delivery.
    /// A failed delivery can leave this paused composition available for continuation.
    public func prepareForInsertion(timeout: Duration = .seconds(45)) async throws -> String {
        guard !preparingInsertion else { throw insertionFailure("Insertion is already being prepared.") }
        let token = generation
        let deadline = ContinuousClock.now.advanced(by: timeout)
        preparingInsertion = true
        defer { preparingInsertion = false }
        while resuming {
            try requireGeneration(token)
            guard ContinuousClock.now < deadline else { throw insertionFailure("Writing is still finishing. Try Insert again.") }
            try await Task.sleep(for: .milliseconds(30))
        }
        try requireGeneration(token)
        if isListening { await stop() }
        try requireGeneration(token)
        guard let room else { throw insertionFailure("There is no composition to insert.") }
        if prepared, await room.state == .listening {
            // Between finalized keyboard takes the Room still listens: let the last stream retire, then drain.
            await retiring?.value; retiring = nil
            try requireGeneration(token)
            prepared = false
            try? await room.micOff()
        }
        while true {
            try requireGeneration(token)
            if let error, !error.hasPrefix(Self.historyErrorPrefix) { throw insertionFailure(error) }
            let state = await room.state
            if (state == .paused || state == .done) && !busy && !instructionApplying { break }
            // Offline debug seeds intentionally have no writer or provider.
            if writer == nil, state == .finalPass { try await room.finishFinalPass(); continue }
            guard ContinuousClock.now < deadline else { throw insertionFailure("Writing is still finishing. Try Insert again.") }
            try await Task.sleep(for: .milliseconds(30))
        }
        try requireGeneration(token)
        snapshot = await room.documentSnapshot
        guard await checkpointHistory() else { throw insertionFailure(error ?? "Could not save composition to History. Draft kept.") }
        try requireGeneration(token)
        onChange?()
        return renderedText
    }
    private func insertionFailure(_ message: String) -> NSError {
        NSError(domain: "Composer", code: 3, userInfo: [NSLocalizedDescriptionKey: message])
    }
    /// Call only after the surface has successfully delivered its rendered value. A keyboard session
    /// retains the composition: the draft, writer conversation and History entry continue until it closes.
    public func insert(retainingComposition: Bool = false) async {
        if retainingComposition, room != nil {
            if !renderedText.isEmpty { successfulInsertionID = UUID().uuidString }
            hostActionNotice = nil; error = nil; onChange?()
            warmAgentStream()
            return
        }
        // The caller acknowledges external delivery before reaching this boundary.
        let token = UUID(); generation = token
        let delivered = renderedText
        let requests = await writer?.recentTopicInstructions() ?? (lastInstruction.isEmpty ? [] : [lastInstruction])
        guard generation == token else { return }
        if let context = TopicContext(deliveredText: delivered, recentInstructions: requests) { topicContext = context }
        if !delivered.isEmpty { successfulInsertionID = UUID().uuidString }
        if let room, await room.state == .paused, await binder?.hasUnsentInstruction == true {
            // Keep the explicit unsent comment usable without recording or dispatching it.
            await binder?.clearSelection(timestamp: ProcessInfo.processInfo.systemUptime)
            let deliveredSnapshot = await room.documentSnapshot
            if !deliveredSnapshot.lines.isEmpty {
                _ = try? await room.applyDocument([.deleteLines(ids: deliveredSnapshot.lines.map(\.id))], origin: .system,
                    versions: Dictionary(uniqueKeysWithValues: deliveredSnapshot.lines.map { ($0.id, $0.version) }))
            }
            snapshot = await room.documentSnapshot; tail = ""; hunks = []; lastTransactionID = nil
            beginHistoryComposition()
            pendingLineIDs = []; error = nil; hostActionNotice = nil; status = "paused"; onChange?()
            return
        }
        _ = try? await room?.insert(); await cleanup()
        beginHistoryComposition()
        room = nil; sessionLog = nil; sessionID = nil; audioOrigin = nil
        pendingDictationRevision = nil; pendingDictationWordIDs = []; dictationCommit = nil; snapshot = .init(revision: 0, lines: []); tail = ""; hunks = []; error = nil; hostActionNotice = nil
        busyParticipants = []; status = "idle"; onChange?()
    }
    /// Discard the composition; Pause deliberately retains the rendered text.
    public func cancel() async {
        guard await flushHistory() else { return }
        generation = UUID(); try? await room?.cancel(); await cleanup()
        beginHistoryComposition()
        room = nil; sessionLog = nil; sessionID = nil; audioOrigin = nil
        pendingDictationRevision = nil; pendingDictationWordIDs = []; dictationCommit = nil; snapshot = .init(revision: 0, lines: []); tail = ""; hunks = []; error = nil; hostActionNotice = nil
        busyParticipants = []; status = "idle"; onChange?()
    }
    /// Explicitly discard both this draft and the volatile reference from earlier delivered work.
    public func startNewTopic() async {
        await cancel()
        if room == nil { topicContext = nil }
    }
    /// Keyboard sessions hold one microphone stream for the whole appearance. Never starts a microphone:
    /// without a lease the keyboard's hop path applies. False when no input could be held.
    func holdWarmInput() async -> Bool {
        if warmInput != nil { return true }
        guard isArmed, !isListening, status != "starting", !resuming else { return false }
        do {
            let stream = try await prepareMicrophoneStream()
            let token = UUID(); warmInputToken = token; route = .idle
            warmInput = Task { [weak self] in
                var converter = PCM16Converter()
                for await chunk in stream {
                    guard !Task.isCancelled, let self else { return }
                    await self.routeChunk(chunk, converter: &converter)
                }
                self?.warmInputEnded(token)
            }
            return true
        } catch { return false }
    }
    /// The gate. Opening `agent` happens through `start`, which begins the take; `idle` only stops routing.
    func setRoute(_ value: AudioRoute) {
        guard warmInput != nil || value == .idle else { return }
        if value != route { routedAudioAt = nil }
        route = value; onChange?()
    }
    private func routeChunk(_ chunk: AudioChunk, converter: inout PCM16Converter) async {
        switch route {
        case .idle: return
        case .dictation:
            guard let pcm = try? converter.convert(chunk) else { return }
            if routedAudioAt == nil { routedAudioAt = ProcessInfo.processInfo.systemUptime }
            await dictationAudio?(pcm)
        case .agent:
            // Keep the lease, but never record/forward muted speech.
            guard !isMuted, let transcriber, let recorder = agentRecorder else { return }
            do {
                try recorder.append(chunk)
                try await transcriber.sendAudio(converter.convert(chunk))
                if routedAudioAt == nil { routedAudioAt = ProcessInfo.processInfo.systemUptime }
                deliveredAudioChunks += 1; deliveredAudioFrames += chunk.samples.count / max(1, chunk.format.channelCount)
            } catch { route = .idle; agentRecorder = nil; fail(error) }
        }
    }
    private func warmInputEnded(_ token: UUID) {
        guard warmInputToken == token else { return }
        warmInput = nil; warmInputToken = nil
        let wasRouting = route != .idle
        route = .idle; agentRecorder = nil
        if wasRouting, isListening { fail(AutomaticInputError.noPCM) }
        onChange?()
    }
    func releaseWarmInput() async {
        route = .idle; agentRecorder = nil
        await closeAgentStream()
        guard let task = warmInput else { return }
        warmInput = nil; warmInputToken = nil
        task.cancel()
        if isListening { return }
        if isArmed && keepMicrophoneActive { await mic.detach() } else { isArmed = false; await mic.stop() }
    }
    /// The keyboard went away: end the composition (History keeps it), its writer conversation, cleanup
    /// context and delivered-topic reference, and release the held input.
    func endKeyboardSession() async {
        route = .idle
        await cancel()
        if room == nil { topicContext = nil }
        await releaseWarmInput()
        onChange?()
    }
    func captureHostActionContext() -> ComposerHostActionContext? {
        guard room != nil else { return nil }
        let target = hostInsertionTarget?()
        return ComposerHostActionContext(sessionToken: generation.uuidString, targetToken: target,
            insertionUnavailableReason: target == nil ? (hostInsertionUnavailableReason?() ?? "No bound text field. Draft will be kept.") : nil)
    }
    func performHostAction(_ action: ComposerHostAction) async -> ComposerHostActionResult {
        guard !Task.isCancelled, action.context.sessionToken == generation.uuidString, room != nil else {
            return .init(succeeded: false, message: "Composition changed. Stale app action discarded.")
        }
        guard consumedHostActionInstructions.insert(action.instructionID).inserted else {
            return .init(succeeded: false, message: "This instruction was already handled; action not repeated.")
        }
        switch action.kind {
        case .clearComposer:
            if let clear = hostClearComposer { await clear() } else { await cancel() }
            instructionCompleted = true; onChange?()
            guard room == nil else { return .init(succeeded: false, message: error ?? "Couldn’t clear composition. Draft kept.") }
            return .init(succeeded: true, message: "Composer cleared.")
        case .insertDraft:
            guard let target = action.context.targetToken, target == hostInsertionTarget?(), let insert = hostInsertDraft else {
                let reason = hostInsertionUnavailableReason?() ?? "No bound text field."
                hostActionNotice = reason + " Draft kept."; instructionApplying = false; onChange?()
                return .init(succeeded: false, message: hostActionNotice!)
            }
            let result = await insert(target)
            if action.context.sessionToken == generation.uuidString {
                hostActionNotice = result.succeeded ? nil : result.message
                instructionApplying = false
                if result.succeeded { lastInstruction = ""; instructionDraft = "" }
                onChange?()
            }
            return result
        }
    }
    public func setMode(_ value: ComposerMode) async { mode = value; UserDefaults.standard.set(value.rawValue, forKey: "composer.mode"); try? await writer?.setMode(value); onChange?() }
    public func tap(lineID: String, wordID: String, timestamp: Double = ProcessInfo.processInfo.systemUptime) async {
        await select(lineID: lineID, wordID: wordID, timestamp: timestamp)
    }
    public func select(lineID: String, wordID: String, endLineID: String? = nil, endWordID: String? = nil,
                       timestamp: Double = ProcessInfo.processInfo.systemUptime) async {
        try? await binder?.select(lineID: lineID, wordID: wordID, endLineID: endLineID, endWordID: endWordID, timestamp: timestamp)
    }
    public func clearSelection(timestamp: Double = ProcessInfo.processInfo.systemUptime) async {
        await binder?.clearSelection(timestamp: timestamp)
    }
    public func discardInstruction(timestamp: Double = ProcessInfo.processInfo.systemUptime) async {
        await binder?.discardInstruction(timestamp: timestamp)
        instructionDraft = ""; lastInstruction = ""; instructionCompleted = true; instructionFailed = false
        hostActionNotice = nil; onChange?()
    }
    public func sendCorrection() async {
        guard await binder?.requestSend(timestamp: ProcessInfo.processInfo.systemUptime) == true else { return }
        do {
            if try await transcriber?.finalizeChunk() != true { await binder?.completeSend() }
        } catch { fail(error) }
    }
    public func pick(lineID: String, wordID: String, text: String) async { do { try await binder?.pick(lineID: lineID, wordID: wordID, text: text) } catch { fail(error) } }
    public func undo() async {
        guard let id = lastTransactionID else { return }
        // Consume the selection before yielding: repeated taps must never invert this Undo.
        lastTransactionID = nil
        do { _ = try await room?.undoDocument(transactionID: id) } catch { fail(error) }
    }
    func receive(_ event: Envelope) async {
        switch event.channel {
        case .docSnapshot:
            if let value = try? event.payload.decode(DocumentSnapshot.self) {
                snapshot = value
                _ = enqueueCheckpoint()
                if pendingDictationRevision == value.revision {
                    dictationRevision += 1; pendingDictationRevision = nil
                    dictationCommit = .init(sequence: dictationRevision, wordIDs: pendingDictationWordIDs)
                    pendingDictationWordIDs = []
                }
            }
        case .docOps:
            if let value = try? event.payload.decode(Transaction.self) {
                hunks = value.hunks
                if value.origin == .asr {
                    pendingDictationRevision = value.revision
                    pendingDictationWordIDs = value.hunks.flatMap { hunk -> [String] in
                        if case .lineInserted(let line, _) = hunk { return line.words.map(\.id) }
                        return []
                    }
                }
                if value.origin != .undo { lastTransactionID = value.id }
            }
        case .asrSegment:
            if let words = try? event.payload["words"]?.decode([Word].self) { acceptedASRWords += words.count }
        case .asrTail: if case .string(let value) = event.payload["text"] { tail = value; onTail?(value) }
        case .writingInstruction:
            hostActionNotice = nil; instructionCompleted = false; instructionFailed = false
            lastInstructionID = try? event.payload["captureID"]?.decode(String.self)
            lastInstruction = (try? event.payload["text"]?.decode(String.self)) ?? ""
            instructionApplying = true
        case .instructionDraft:
            if case .string(let draft) = event.payload["text"], !draft.isEmpty { instructionCompleted = false; instructionFailed = false; hostActionNotice = nil }
            instructionDraft = (try? event.payload["text"]?.decode(String.self)) ?? ""
            // The live instruction is this route's tail; the tap-to-first-words probe reads it.
            if !instructionDraft.isEmpty { onTail?(instructionDraft) }
        case .correctionDraft:
            correctionDraft = try? event.payload["text"]?.decode(String.self)
            correctionSubmitting = (try? event.payload["submitting"]?.decode(Bool.self)) ?? false
            correctionCountdownStart = try? event.payload["countdownStart"]?.decode(Double.self)
            correctionCountdownDeadline = try? event.payload["countdownDeadline"]?.decode(Double.self)
        case .agentStatus:
            if event.payload["event"] == .string("instruction.notice") { hostActionNotice = try? event.payload["message"]?.decode(String.self) }
            if event.payload["event"] == .string("host.action.queued") { instructionApplying = true }
            if event.payload["event"] == .string("host.action.result") {
                instructionApplying = false
                if event.payload["succeeded"] == .bool(false) { hostActionNotice = try? event.payload["message"]?.decode(String.self) }
                else { instructionCompleted = instructionDraft.isEmpty; hostActionNotice = nil; lastInstruction = "" }
            }
            if event.payload["event"] == .string("turn.phase"), event.payload["phase"] == .string("instruction") { instructionApplying = true }
            if event.payload["event"] == .string("instruction.completed"),
               (try? event.payload["instructionID"]?.decode(String.self)) == lastInstructionID { instructionApplying = false; instructionCompleted = instructionDraft.isEmpty && !instructionFailed }
            if case .bool(let value) = event.payload["busy"] { if value { busyParticipants.insert(event.participant) } else { busyParticipants.remove(event.participant) }; busy = !busyParticipants.isEmpty }
            if event.payload["event"] == .string("pending.edit"), let ids = try? event.payload["lines"]?.decode([String].self) { pendingLineIDs = Set(ids) }
            if event.payload["event"] == .string("error"), case .string(let message) = event.payload["message"] {
                error = Self.writerFailureMessage(message); errorDetail = message
                if instructionApplying || !lastInstruction.isEmpty { instructionFailed = true; instructionApplying = false; instructionCompleted = false }
            }
        case .session:
            if case .string(let value) = event.payload["state"] {
                // Room reopens before the new provider connects. Expose listening
                // only when beginInput has established its actual input stream.
                if value == "listening", resuming { break }
                status = value
                if value == "done" { busyParticipants = []; busy = false; pendingLineIDs = [] }
            }
            if event.payload["event"] == .string("asr.error"), case .string(let message) = event.payload["message"] { error = message; status = "error"; isArmed = false; await mic.stop() }
        default: break
        }
        if case .string(let value) = event.payload["mode"], let mode = ComposerMode(rawValue: value) { self.mode = mode }
        onChange?()
    }
    /// Short, human wording for a writer failure; the raw text stays in `errorDetail` and the room log.
    public nonisolated static func writerFailureMessage(_ raw: String) -> String {
        let lower = raw.lowercased()
        if raw.contains("http(401") || raw.contains("http(403") || lower.contains("authentication_error") { return "Claude key rejected" }
        if raw.contains("missingKey") { return "Add your Claude key in Legato" }
        if raw.contains("http(429") || lower.contains("rate_limit") { return "Claude is busy — try again" }
        if raw.contains("NSURLErrorDomain") || raw.contains("URLError") || lower.contains("offline") || lower.contains("network connection") { return "Network unavailable" }
        return "Writer failed — try again"
    }
    private func requireGeneration(_ expected: UUID) throws { try Task.checkCancellation(); if generation != expected { throw CancellationError() } }
    private func fail(_ failure: any Error) {
        var underlying: NSError? = failure as NSError
        var refusal = failure as? MicSourceError == .notArmed
        for _ in 0..<5 {
            guard let current = underlying else { break }
            if [560_557_684, 561_015_905, 561_145_187, 2_003_329_396].contains(current.code),
               current.domain == NSOSStatusErrorDomain || current.domain == "com.apple.coreaudio.avfaudio" { refusal = true }
            underlying = current.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        error = refusal ? "Open Legato and tap the microphone to ready it again, then return to your keyboard." : failure.localizedDescription
        status = "error"; onChange?()
    }
    private func cleanup() async {
        route = .idle; agentRecorder = nil; prepared = false
        retiring?.cancel(); retiring = nil
        await closeAgentStream()
        // A held keyboard input outlives compositions; only the keyboard session releases it.
        if warmInput == nil {
            audioTask?.cancel(); if isArmed && keepMicrophoneActive { await mic.detach() } else { isArmed = false; await mic.stop() }; audioTask?.cancel(); await audioTask?.value; audioTask = nil
        }
        await transcriber?.cancel(); transcriber = nil
        await writer?.stop(); writer = nil
        await binder?.stop(); binder = nil; await alternatives?.stop(); alternatives = nil
        isMuted = false; instructionDraft = ""; lastInstruction = ""; instructionApplying = false; instructionFailed = false; errorDetail = nil
        correctionDraft = nil; correctionSubmitting = false; correctionCountdownStart = nil; correctionCountdownDeadline = nil
        eventsTask?.cancel(); eventsTask = nil; busy = false; pendingLineIDs = []; lastTransactionID = nil
    }
}

/// AAC is written from the same chunks forwarded to Soniox, keeping diagnostic audio aligned.
final class ComposerAudioRecorder {
    private let file: AVAudioFile
    private let format: AVAudioFormat
    init(url: URL) throws {
        format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
        // 64 kb/s exceeds Apple AAC's supported rate for 16 kHz mono ('!dat').
        file = try AVAudioFile(forWriting: url, settings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 16000, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 32000], commonFormat: .pcmFormatFloat32, interleaved: false)
    }
    func append(_ chunk: AudioChunk) throws {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(chunk.samples.count)) else { return }
        buffer.frameLength = buffer.frameCapacity
        chunk.samples.withUnsafeBufferPointer { pointer in if let base = pointer.baseAddress { buffer.floatChannelData![0].update(from: base, count: pointer.count) } }
        try file.write(from: buffer)
    }
}
