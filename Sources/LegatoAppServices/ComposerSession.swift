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
    public private(set) var mode = ComposerMode.message
    public private(set) var sessionID: String?
    public private(set) var inputSource = "microphone.soniox"
    public private(set) var audioOrigin: Double?
    public private(set) var hunks: [AnimationHunk] = []
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
    @ObservationIgnored private var writer: AgentRunner?
    @ObservationIgnored private var transcriber: SonioxClient?
    @ObservationIgnored private let mic = MicSource()
    @ObservationIgnored private var eventsTask: Task<Void, Never>?
    @ObservationIgnored private var audioTask: Task<Void, Never>?
    @ObservationIgnored private var binder: HintBinder?
    @ObservationIgnored private var alternatives: AlternativesParticipant?
    @ObservationIgnored private var lastTransactionID: String?
    @ObservationIgnored private var busyParticipants: Set<Participant> = []
    private let vocabularyURL: URL
    public init(vocabularyURL: URL = URL.applicationSupportDirectory.appending(path: "Legato/vocabulary.json")) { self.vocabularyURL = vocabularyURL }
    init(room: Room) {
        self.room = room
        self.vocabularyURL = URL.applicationSupportDirectory.appending(path: "Legato/vocabulary.json")
    }
    public func arm() async {
        guard !isArmed else { return }
        do {
            #if os(iOS)
            guard await AVAudioApplication.requestRecordPermission() else { throw NSError(domain: "Composer", code: 2, userInfo: [NSLocalizedDescriptionKey: "Allow microphone access in iOS Settings."]) }
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .default, options: [.mixWithOthers, .defaultToSpeaker, .allowBluetoothHFP])
            try session.setActive(true)
            #endif
            _ = try await mic.start(format: .init(sampleRate: 16000, channelCount: 1))
            isArmed = true; status = "ready"; onChange?()
        } catch { fail(error) }
    }
    public func releaseMicrophone() async { isArmed = false; await cancel() }
    public func start() async { await startSession(debugMode: nil, microphoneLease: false) }
    private func startSession(debugMode: ComposerMode?, microphoneLease: Bool) async {
        await cancel()
        inputSource = debugMode == nil ? "microphone.soniox" : "debug.transcriber"
        audioOrigin = nil
        if debugMode != nil {
            if !microphoneLease { isArmed = false; await mic.stop() }
            else if !isArmed { await arm(); guard isArmed else { return } }
        }
        let generation = UUID(); self.generation = generation
        snapshot = .init(revision: 0, lines: []); tail = ""; error = nil; status = "starting"; hunks = []; pendingLineIDs = []; busyParticipants = []; busy = false
        let id = UUID().uuidString; sessionID = id
        do {
            let soniox = debugMode == nil ? (try KeychainKeyStore(service: "de.gruenwald.legato.soniox").apiKey() ?? "") : ""
            let claude = try KeychainKeyStore().apiKey() ?? ""
            let log = try SessionLog(rootDirectory: URL.documentsDirectory.appending(path: "sessions"), sessionID: id, secrets: [soniox, claude])
            let room = Room(log: log, segmentRouting: .intercepted); self.room = room
            _ = try await room.publish(channel: .session, participant: .ui, payload: .object(["event": .string("input.source"), "inputSource": .string(inputSource), "microphoneLeaseActive": .bool(isArmed)]))
            guard (debugMode != nil || !soniox.isEmpty), !claude.isEmpty else {
                throw NSError(domain: "Composer", code: 1, userInfo: [NSLocalizedDescriptionKey: debugMode == nil ? "Add Claude and Soniox API keys in Settings." : "Add a Claude API key in Settings for debug transcriber UAT."])
            }
            let store = VocabularyStore(fileURL: vocabularyURL)
            let learner = VocabularyLearner(store: store, spellChecker: PlatformSpellChecker(), tagger: NLEntityTagger(), languages: ["de", "en"])
            let binder = HintBinder(room: room, learner: learner, onSend: { [weak self] in await self?.sendCorrection() }); self.binder = binder; await binder.start(); try requireGeneration(generation)
            let alternatives = AlternativesParticipant(room: room, store: store, learner: learner); self.alternatives = alternatives; await alternatives.start(); try requireGeneration(generation)
            let defaults = UserDefaults.standard
            let prompt = defaults.string(forKey: "composer.personalPrompt") ?? ""
            mode = debugMode ?? ComposerMode(rawValue: defaults.string(forKey: "composer.mode") ?? "message") ?? .message
            let terms = (try? await store.snapshot().entries.filter { !$0.blocked }.map(\.text)) ?? []
            let writer = AgentRunner(room: room, client: MessagesStream(keyStore: KeychainKeyStore()), configuration: .init(
                liveModel: ModelChoice(rawValue: defaults.string(forKey: "composer.liveModel") ?? "") ?? .haiku,
                mode: mode, personalPrompt: prompt, vocabulary: { _ in terms }))
            self.writer = writer; await writer.start(); try requireGeneration(generation)
            let eventStream = await room.subscribe(participant: .ui, channels: Set(Channel.allCases), buffering: .unbounded)
            eventsTask = Task { [weak self] in for await event in eventStream { guard !Task.isCancelled else { break }; await self?.receive(event) } }
            #if DEBUG || LEGATO_INTERNAL
            if debugMode != nil {
                let origin = ProcessInfo.processInfo.systemUptime; audioOrigin = origin
                let transcriber = SonioxClient(room: room, config: .init(mode: mode.rawValue, personalPrompt: prompt, terms: terms), audioOrigin: origin)
                self.transcriber = transcriber; try await transcriber.startDebug(); try requireGeneration(generation)
                status = "listening"; onChange?(); return
            }
            #endif
            #if os(iOS)
            guard await AVAudioApplication.requestRecordPermission() else { throw NSError(domain: "Composer", code: 2, userInfo: [NSLocalizedDescriptionKey: "Allow microphone access in iOS Settings."]) }
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.playAndRecord, mode: .default, options: [.mixWithOthers, .defaultToSpeaker, .allowBluetoothHFP])
            try audioSession.setActive(true)
            #endif
            let transcriber = SonioxClient(room: room, config: .init(mode: mode.rawValue, personalPrompt: prompt, terms: terms), audioOrigin: nil)
            self.transcriber = transcriber; try await transcriber.start(apiKey: soniox); try requireGeneration(generation)
            try requireGeneration(generation)
            let audioOrigin = ProcessInfo.processInfo.systemUptime; self.audioOrigin = audioOrigin
            let stream = try await (isArmed ? mic.route() : mic.start(format: .init(sampleRate: 16000, channelCount: 1)))
            try requireGeneration(generation)
            await transcriber.setAudioOrigin(audioOrigin)
            let recorder = try ComposerAudioRecorder(url: log.audioURL)
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
                    }
                } catch is CancellationError {} catch { self?.fail(error) }
            }
        } catch { if self.generation == generation { fail(error); try? await room?.cancel(); await cleanup() } }
    }
    #if DEBUG || LEGATO_INTERNAL
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
        ["uptime": ProcessInfo.processInfo.systemUptime, "status": status, "dictating": isListening, "muted": isMuted, "microphoneLeaseActive": isArmed, "inputSource": inputSource,
         "sessionID": sessionID ?? "", "audioOrigin": audioOrigin as Any? ?? NSNull(), "revision": snapshot.revision,
         "document": (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot))) ?? [:],
         "correctionDraft": correctionDraft as Any? ?? NSNull(),
         "correctionCountdownStart": correctionCountdownStart as Any? ?? NSNull(),
         "correctionCountdownDeadline": correctionCountdownDeadline as Any? ?? NSNull(),
         "tail": tail, "text": renderedText, "mode": mode.rawValue, "busy": busy, "pendingLineIDs": Array(pendingLineIDs), "error": error ?? ""]
    }
    #endif
    /// Logical voice mute: keep the mic lease, Room and agent work alive while dropping new input.
    public func setMuted(_ value: Bool) async {
        guard isListening, room != nil, isMuted != value else { return }
        isMuted = value; onChange?()
        let generation = self.generation
        do { try await transcriber?.setMuted(value) }
        catch { if self.generation == generation { fail(error) } }
    }
    public func stop() async {
        guard isListening else { return }; status = "trailing"; onChange?()
        if isArmed { await mic.detach() } else { await mic.stop() }; audioTask?.cancel(); await audioTask?.value; audioTask = nil
        do { try await transcriber?.finish() } catch { fail(error) }
    }
    /// The surface inserts its currently rendered value synchronously, then calls this to cancel work.
    public func insert() async { generation = UUID(); _ = try? await room?.insert(); await cleanup(); status = "done"; onChange?() }
    /// Discard the composition; Stop and Insert deliberately retain the rendered text.
    public func cancel() async {
        generation = UUID(); try? await room?.cancel(); await cleanup()
        room = nil; sessionID = nil; audioOrigin = nil
        snapshot = .init(revision: 0, lines: []); tail = ""; hunks = []; error = nil
        busyParticipants = []; status = "idle"; onChange?()
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
        case .docSnapshot: if let value = try? event.payload.decode(DocumentSnapshot.self) { snapshot = value }
        case .docOps: if let value = try? event.payload.decode(Transaction.self) { hunks = value.hunks; if value.origin != .undo { lastTransactionID = value.id } }
        case .asrTail: if case .string(let value) = event.payload["text"] { tail = value }
        case .correctionDraft:
            correctionDraft = try? event.payload["text"]?.decode(String.self)
            correctionCountdownStart = try? event.payload["countdownStart"]?.decode(Double.self)
            correctionCountdownDeadline = try? event.payload["countdownDeadline"]?.decode(Double.self)
        case .agentStatus:
            if case .bool(let value) = event.payload["busy"] { if value { busyParticipants.insert(event.participant) } else { busyParticipants.remove(event.participant) }; busy = !busyParticipants.isEmpty }
            if event.payload["event"] == .string("pending.edit"), let ids = try? event.payload["lines"]?.decode([String].self) { pendingLineIDs = Set(ids) }
            if event.payload["event"] == .string("error"), case .string(let message) = event.payload["message"] { error = message }
        case .session:
            if case .string(let value) = event.payload["state"] {
                status = value
                if value == "done" { busyParticipants = []; busy = false; pendingLineIDs = [] }
            }
            if event.payload["event"] == .string("asr.error"), case .string(let message) = event.payload["message"] { error = message; status = "error"; await mic.stop() }
        default: break
        }
        if case .string(let value) = event.payload["mode"], let mode = ComposerMode(rawValue: value) { self.mode = mode }
        onChange?()
    }
    private func requireGeneration(_ expected: UUID) throws { try Task.checkCancellation(); if generation != expected { throw CancellationError() } }
    private func fail(_ failure: any Error) { error = failure.localizedDescription; status = "error"; onChange?() }
    private func cleanup() async {
        audioTask?.cancel(); if isArmed { await mic.detach() } else { await mic.stop() }; audioTask?.cancel(); await audioTask?.value; audioTask = nil
        await transcriber?.cancel(); transcriber = nil; await writer?.stop(); writer = nil
        await binder?.stop(); binder = nil; await alternatives?.stop(); alternatives = nil
        isMuted = false
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
