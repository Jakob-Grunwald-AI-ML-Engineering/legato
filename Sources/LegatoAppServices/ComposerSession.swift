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

/// Host-only session shared by the phone app and Mac panel. The keyboard receives value snapshots.
@MainActor @Observable public final class ComposerSession {
    public private(set) var topicContext: TopicContext?
    public private(set) var dictationRevision = 0
    private var pendingDictationRevision: Int?
    public private(set) var snapshot = DocumentSnapshot(revision: 0, lines: [])
    public private(set) var tail = ""
    public private(set) var correctionDraft: String?
    public private(set) var correctionCountdownStart: Double?
    public private(set) var correctionCountdownDeadline: Double?
    public private(set) var status = "idle"
    public private(set) var error: String?
    public private(set) var pendingLineIDs: Set<String> = []
    public private(set) var busy = false
    public private(set) var isMuted = false
    public private(set) var inputMode = ComposerInputMode.dictation
    public private(set) var instructionDraft = ""
    public private(set) var lastInstruction = ""
    public private(set) var instructionApplying = false
    private var lastInstructionID: String?
    private var instructionCompleted = false
    public var instructionPreview: String { instructionDraft.isEmpty ? lastInstruction : instructionDraft }
    public var instructionStatus: String {
        if let hostActionNotice { return hostActionNotice }
        if instructionCompleted { return "Done" }
        if !instructionDraft.isEmpty { return "Listening" }
        if instructionApplying { return "Applying" }
        if !lastInstruction.isEmpty { return "Done" }
        return isListening && inputMode == .instructions ? "Listening" : "Ready"
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
    @ObservationIgnored private var sentencePipeline: OrderedSentencePipeline?
    public private(set) var sentenceCleanupPending = 0
    private var sentenceCleanupFailed = false
    @ObservationIgnored private var binder: HintBinder?
    @ObservationIgnored private var alternatives: AlternativesParticipant?
    @ObservationIgnored private var lastTransactionID: String?
    @ObservationIgnored private var busyParticipants: Set<Participant> = []
    private let vocabularyURL: URL
    public init(vocabularyURL: URL = URL.applicationSupportDirectory.appending(path: "Legato/vocabulary.json"), keepMicrophoneActive: Bool = true) {
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
        self.vocabularyURL = URL.applicationSupportDirectory.appending(path: "Legato/vocabulary.json")
        self.mic = microphone
        self.activateAudioSession = activateAudioSession
    }
    init(room: Room, log: SessionLog? = nil) {
        self.room = room
        self.sessionLog = log
        self.sessionID = log?.directory.lastPathComponent
        self.mic = AutomaticInputSource()
        self.activateAudioSession = Self.activateMicrophoneSession
        self.vocabularyURL = URL.applicationSupportDirectory.appending(path: "Legato/vocabulary.json")
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
        guard !keepMicrophoneActive else { return }
        if isListening { await stop() }
        isArmed = false; await mic.stop(); onChange?()
    }
    public func releaseMicrophone() async { isArmed = false; await cancel() }
    public func start() async { await startSession(debugMode: nil, microphoneLease: false) }
    private func startSession(debugMode: ComposerMode?, microphoneLease: Bool) async {
        if let sentencePipeline, await sentencePipeline.hasFailure {
            error = nil; sentenceCleanupFailed = false
            await sentencePipeline.retryFailed()
        }
        guard !isListening, status != "starting", !resuming, !preparingInsertion else { return }
        if let room, sessionLog != nil, await room.state != .done {
            await resumeSession(debug: debugMode != nil)
            return
        }
        await cancel()
        inputSource = debugMode == nil ? "microphone.soniox" : "debug.transcriber"
        audioOrigin = nil
        if debugMode != nil {
            if !microphoneLease { isArmed = false; await mic.stop() }
            else if !isArmed { await arm(); guard isArmed else { return } }
        }
        let generation = UUID(); self.generation = generation
        pendingDictationRevision = nil; snapshot = .init(revision: 0, lines: []); tail = ""; error = nil; status = "starting"; hunks = []; pendingLineIDs = []; busyParticipants = []; busy = false
        let id = UUID().uuidString; sessionID = id
        do {
            let soniox = debugMode == nil ? (try KeychainKeyStore(service: "de.gruenwald.legato.soniox").apiKey() ?? "") : ""
            let claude = try KeychainKeyStore().apiKey() ?? ""
            let log = try SessionLog(rootDirectory: URL.documentsDirectory.appending(path: "sessions"), sessionID: id, secrets: [soniox, claude])
            let room = Room(log: log, segmentRouting: .intercepted, resumable: true, validateDictation: true, drainOnly: true); self.room = room; sessionLog = log; recordingTake = 0
            _ = try await room.publish(channel: .session, participant: .ui, payload: .object(["event": .string("input.source"), "inputSource": .string(inputSource), "microphoneLeaseActive": .bool(isArmed)]))
            guard (debugMode != nil || !soniox.isEmpty), !claude.isEmpty else {
                throw NSError(domain: "Composer", code: 1, userInfo: [NSLocalizedDescriptionKey: debugMode == nil ? "Add Claude and Soniox API keys in Settings." : "Add a Claude API key in Settings for debug transcriber UAT."])
            }
            let store = VocabularyStore(fileURL: vocabularyURL)
            let learner = VocabularyLearner(store: store, spellChecker: PlatformSpellChecker(), tagger: NLEntityTagger(), languages: ["de", "en"])
            let terms = (try? await store.snapshot().entries.filter { !$0.blocked }.map(\.text)) ?? []
            let binder = HintBinder(room: room, learner: learner, onSend: { [weak self] in await self?.sendCorrection() },
                onInstructionQuiet: { [weak self] in await self?.finalizeInstructionChunk() },
                onDictation: { [weak self] sentence in await self?.sentencePipeline?.enqueue(sentence) })
            self.binder = binder
            sentencePipeline = OrderedSentencePipeline(cleaner: SentenceCleanupClient(client: MessagesStream(keyStore: KeychainKeyStore()), onUsage: { id, sequence, usage in
                _ = try? await room.publish(channel: .sentenceCleanup, participant: .sentenceAgent, payload: .object([
                    "event": .string("sentence.usage"), "sentenceID": .string(id), "sequence": .number(Double(sequence)),
                    "model": .string(ModelChoice.haiku.rawValue), "usage": usage]))
            }), vocabulary: terms,
                accept: { [weak binder] value in
                    guard let binder else { throw CancellationError() }
                    try await binder.acceptValidatedDictation(value)
                }, status: { value in
                    _ = try? await room.publish(channel: .sentenceCleanup, participant: .sentenceAgent, payload: .object([
                        "event": .string("sentence.status"), "pending": .number(Double(value.pending)), "inFlight": .number(Double(value.inFlight)),
                        "failed": .bool(value.failed), "message": value.message.map(JSONValue.string) ?? .null]))
                }, diagnostic: { fields in
                    _ = try? await room.publish(channel: .sentenceCleanup, participant: .sentenceAgent, payload: .object(fields))
                })
            await binder.start()
            if inputMode != .dictation { await binder.setInputMode(inputMode, timestamp: ProcessInfo.processInfo.systemUptime) }
            try requireGeneration(generation)
            let alternatives = AlternativesParticipant(room: room, store: store, learner: learner); self.alternatives = alternatives; await alternatives.start(); try requireGeneration(generation)
            let defaults = UserDefaults.standard
            let prompt = defaults.string(forKey: "composer.personalPrompt") ?? ""
            mode = debugMode ?? ComposerMode(rawValue: defaults.string(forKey: "composer.mode") ?? "message") ?? .message
            let writer = AgentRunner(room: room, client: MessagesStream(keyStore: KeychainKeyStore()), configuration: .init(
                liveModel: ModelChoice(rawValue: defaults.string(forKey: "composer.liveModel") ?? "") ?? .haiku,
                mode: mode, personalPrompt: prompt, topicContext: topicContext, vocabulary: { _ in terms }, validatedSentenceInput: true,
                hostActionContext: { [weak self] in await self?.captureHostActionContext() },
                performHostAction: { [weak self] action in
                    guard let self else { return .init(succeeded: false, message: "Composition closed. Action discarded.") }
                    return await self.performHostAction(action)
                }))
            self.writer = writer; await writer.start(); try requireGeneration(generation)
            let eventStream = await room.subscribe(participant: .ui, channels: Set(Channel.allCases), buffering: .unbounded)
            eventsTask = Task { [weak self] in for await event in eventStream { guard !Task.isCancelled else { break }; await self?.receive(event) } }
            inputConfig = .init(mode: mode.rawValue, personalPrompt: prompt, terms: terms)
            try await beginInput(room: room, log: log, debug: debugMode != nil, soniox: soniox, generation: generation)
        } catch {
            if self.generation == generation {
                fail(error)
                isArmed = false
                try? await room?.cancel(); await cleanup()
            }
        }
    }
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
                if sentenceCleanupFailed { throw insertionFailure("Sentence cleanup failed. Pending speech is kept; tap the microphone to retry.") }
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
        let room = Room(resumable: true)
        self.room = room; sessionID = UUID().uuidString; inputSource = "debug.seed"
        for line in text.components(separatedBy: "\n") where !line.isEmpty {
            _ = try await room.appendSegment(words: line.split(whereSeparator: \.isWhitespace).map { .init(text: String($0)) })
        }
        try await room.micOff(); try await room.finishFinalPass()
        snapshot = await room.documentSnapshot; status = "paused"; onChange?()
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
        var state: [String: Any] = ["uptime": ProcessInfo.processInfo.systemUptime, "status": status, "dictating": isListening, "muted": isMuted, "microphoneLeaseActive": isArmed, "inputSource": inputSource, "inputMode": inputMode.rawValue, "instructionDraft": instructionDraft, "instructionPreview": instructionPreview, "instructionStatus": instructionStatus,
         "sessionID": sessionID ?? "", "hasTopicContext": topicContext != nil, "topicContextCharacters": (topicContext?.deliveredText.count ?? 0) + (topicContext?.pastRequests.count ?? 0), "audioOrigin": audioOrigin as Any? ?? NSNull(), "revision": snapshot.revision,
         "document": (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot))) ?? [:],
         "correctionDraft": correctionDraft as Any? ?? NSNull(),
         "correctionCountdownStart": correctionCountdownStart as Any? ?? NSNull(),
         "correctionCountdownDeadline": correctionCountdownDeadline as Any? ?? NSNull(),
         "tail": tail, "text": renderedText, "mode": mode.rawValue, "busy": busy, "sentenceCleanupPending": sentenceCleanupPending, "sentenceCleanupFailed": sentenceCleanupFailed, "pendingLineIDs": Array(pendingLineIDs), "error": error ?? ""]
        state["audioPlatform"] = (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(AutomaticInputSource.platformStatus()))) ?? [:]
        if let automatic = mic as? AutomaticInputSource {
            state["audioInput"] = (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(automatic.diagnostics))) ?? [:]
        }
        state["audioDelivery"] = ["chunks": deliveredAudioChunks, "frames": deliveredAudioFrames, "acceptedFinalWords": acceptedASRWords]
        return state
    }
    #endif
    public func setInputMode(_ value: ComposerInputMode, timestamp: Double = ProcessInfo.processInfo.systemUptime) async {
        guard value != inputMode else { return }
        inputMode = value; instructionCompleted = false; onChange?()
        await binder?.setInputMode(value, timestamp: timestamp)
        // Finalize the old acoustic chunk without reconnecting or stopping microphone input.
        if isListening { try? await transcriber?.finalizeChunk() }
    }
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
        if isArmed && keepMicrophoneActive { await mic.detach() } else { isArmed = false; await mic.stop() }; audioTask?.cancel(); await audioTask?.value; audioTask = nil
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
        while true {
            try requireGeneration(token)
            if let error { throw insertionFailure(error) }
            let state = await room.state
            if state == .paused || state == .done { break }
            // Offline debug seeds intentionally have no writer or provider.
            if writer == nil, state == .finalPass { try await room.finishFinalPass(); continue }
            guard ContinuousClock.now < deadline else { throw insertionFailure("Writing is still finishing. Try Insert again.") }
            try await Task.sleep(for: .milliseconds(30))
        }
        try requireGeneration(token)
        snapshot = await room.documentSnapshot
        onChange?()
        return renderedText
    }
    private func insertionFailure(_ message: String) -> NSError {
        NSError(domain: "Composer", code: 3, userInfo: [NSLocalizedDescriptionKey: message])
    }
    /// Call only after the surface has successfully delivered its rendered value.
    public func insert() async {
        // The caller acknowledges external delivery before reaching this boundary.
        let token = UUID(); generation = token
        let delivered = renderedText
        let requests = await writer?.recentTopicInstructions() ?? (lastInstruction.isEmpty ? [] : [lastInstruction])
        guard generation == token else { return }
        if let context = TopicContext(deliveredText: delivered, recentInstructions: requests) { topicContext = context }
        _ = try? await room?.insert(); await cleanup()
        room = nil; sessionLog = nil; sessionID = nil; audioOrigin = nil
        pendingDictationRevision = nil; snapshot = .init(revision: 0, lines: []); tail = ""; hunks = []; error = nil; hostActionNotice = nil
        busyParticipants = []; status = "idle"; onChange?()
    }
    /// Discard the composition; Pause deliberately retains the rendered text.
    public func cancel() async {
        generation = UUID(); try? await room?.cancel(); await cleanup()
        room = nil; sessionLog = nil; sessionID = nil; audioOrigin = nil
        pendingDictationRevision = nil; snapshot = .init(revision: 0, lines: []); tail = ""; hunks = []; error = nil; hostActionNotice = nil
        busyParticipants = []; status = "idle"; onChange?()
    }
    /// Explicitly discard both this draft and the volatile reference from earlier delivered work.
    public func startNewTopic() async {
        topicContext = nil
        await cancel()
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
        case .sentenceCleanup:
            if case .number(let count) = event.payload["pending"] { sentenceCleanupPending = Int(count) }
            if case .bool(let failed) = event.payload["failed"] {
                sentenceCleanupFailed = failed
                if failed { error = (try? event.payload["message"]?.decode(String.self)) ?? "Sentence cleanup failed. Pending speech kept." }
                else if sentenceCleanupPending == 0, error?.hasPrefix("Sentence cleanup") == true { error = nil }
            }
            busy = !busyParticipants.isEmpty || sentenceCleanupPending > 0
        case .docSnapshot:
            if let value = try? event.payload.decode(DocumentSnapshot.self) {
                snapshot = value
                if pendingDictationRevision == value.revision {
                    dictationRevision += 1; pendingDictationRevision = nil
                }
            }
        case .docOps:
            if let value = try? event.payload.decode(Transaction.self) {
                hunks = value.hunks
                if value.origin == .asr { pendingDictationRevision = value.revision }
                if value.origin != .undo { lastTransactionID = value.id }
            }
        case .asrSegment:
            if let words = try? event.payload["words"]?.decode([Word].self) { acceptedASRWords += words.count }
        case .asrTail: if case .string(let value) = event.payload["text"] { tail = value }
        case .writingInstruction:
            hostActionNotice = nil; instructionCompleted = false
            lastInstructionID = try? event.payload["captureID"]?.decode(String.self)
            lastInstruction = (try? event.payload["text"]?.decode(String.self)) ?? ""
            instructionApplying = true
        case .instructionDraft:
            if case .string(let draft) = event.payload["text"], !draft.isEmpty { instructionCompleted = false; hostActionNotice = nil }
            instructionDraft = (try? event.payload["text"]?.decode(String.self)) ?? ""
        case .correctionDraft:
            correctionDraft = try? event.payload["text"]?.decode(String.self)
            correctionCountdownStart = try? event.payload["countdownStart"]?.decode(Double.self)
            correctionCountdownDeadline = try? event.payload["countdownDeadline"]?.decode(Double.self)
        case .agentStatus:
            if event.payload["event"] == .string("instruction.notice") { hostActionNotice = try? event.payload["message"]?.decode(String.self) }
            if event.payload["event"] == .string("host.action.queued") { instructionApplying = true }
            if event.payload["event"] == .string("host.action.result") {
                instructionApplying = false
                if event.payload["succeeded"] == .bool(false) { hostActionNotice = try? event.payload["message"]?.decode(String.self) }
                else { instructionCompleted = true; hostActionNotice = nil; lastInstruction = ""; instructionDraft = "" }
            }
            if event.payload["event"] == .string("turn.phase"), event.payload["phase"] == .string("instruction") { instructionApplying = true }
            if event.payload["event"] == .string("instruction.completed"),
               (try? event.payload["instructionID"]?.decode(String.self)) == lastInstructionID { instructionApplying = false; instructionCompleted = true }
            if case .bool(let value) = event.payload["busy"] { if value { busyParticipants.insert(event.participant) } else { busyParticipants.remove(event.participant) }; busy = !busyParticipants.isEmpty || sentenceCleanupPending > 0 }
            if event.payload["event"] == .string("pending.edit"), let ids = try? event.payload["lines"]?.decode([String].self) { pendingLineIDs = Set(ids) }
            if event.payload["event"] == .string("error"), case .string(let message) = event.payload["message"] { error = message }
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
        audioTask?.cancel(); if isArmed && keepMicrophoneActive { await mic.detach() } else { isArmed = false; await mic.stop() }; audioTask?.cancel(); await audioTask?.value; audioTask = nil
        await transcriber?.cancel(); transcriber = nil
        await sentencePipeline?.cancel(); sentencePipeline = nil; sentenceCleanupPending = 0; sentenceCleanupFailed = false
        await writer?.stop(); writer = nil
        await binder?.stop(); binder = nil; await alternatives?.stop(); alternatives = nil
        isMuted = false; inputMode = .dictation; instructionDraft = ""; lastInstruction = ""; instructionApplying = false
        correctionDraft = nil; correctionCountdownStart = nil; correctionCountdownDeadline = nil
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
