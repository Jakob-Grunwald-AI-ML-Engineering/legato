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
    public private(set) var status = "idle"
    public private(set) var error: String?
    public private(set) var pendingLineIDs: Set<String> = []
    public private(set) var busy = false
    public private(set) var mode = ComposerMode.message
    public private(set) var sessionID: String?
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
    public var isListening: Bool { status == "listening" }
    @ObservationIgnored private var room: Room?
    @ObservationIgnored private var agents: AgentRunner?
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
    public func start() async {
        await cancel()
        snapshot = .init(revision: 0, lines: []); tail = ""; error = nil; status = "starting"; hunks = []; pendingLineIDs = []; busyParticipants = []; busy = false
        let id = UUID().uuidString; sessionID = id
        do {
            let soniox = try KeychainKeyStore(service: "de.gruenwald.legato.soniox").apiKey() ?? ""
            let claude = try KeychainKeyStore().apiKey() ?? ""
            let log = try SessionLog(rootDirectory: URL.documentsDirectory.appending(path: "sessions"), sessionID: id, secrets: [soniox, claude])
            let room = Room(log: log, segmentRouting: .intercepted); self.room = room
            guard !soniox.isEmpty, !claude.isEmpty else {
                throw NSError(domain: "Composer", code: 1, userInfo: [NSLocalizedDescriptionKey: "Add Claude and Soniox API keys in Settings."])
            }
            let store = VocabularyStore(fileURL: vocabularyURL)
            let learner = VocabularyLearner(store: store, spellChecker: PlatformSpellChecker(), tagger: NLEntityTagger(), languages: ["de", "en"])
            let binder = HintBinder(room: room, learner: learner); self.binder = binder; await binder.start()
            let alternatives = AlternativesParticipant(room: room, store: store, learner: learner); self.alternatives = alternatives; await alternatives.start()
            let defaults = UserDefaults.standard
            let prompt = defaults.string(forKey: "composer.personalPrompt") ?? ""
            mode = ComposerMode(rawValue: defaults.string(forKey: "composer.mode") ?? "message") ?? .message
            let terms = (try? await store.snapshot().entries.filter { !$0.blocked }.map(\.text)) ?? []
            let agents = AgentRunner(room: room, client: MessagesStream(keyStore: KeychainKeyStore()), configuration: .init(
                liveModel: ModelChoice(rawValue: defaults.string(forKey: "composer.liveModel") ?? "") ?? .haiku,
                restructureModel: ModelChoice(rawValue: defaults.string(forKey: "composer.restructureModel") ?? "") ?? .sonnet,
                mode: mode, personalPrompt: prompt, vocabulary: { _ in terms }))
            self.agents = agents; await agents.start()
            let stream = await room.subscribe(participant: .ui, channels: Set(Channel.allCases), buffering: .unbounded)
            eventsTask = Task { [weak self] in for await event in stream { guard !Task.isCancelled else { break }; await self?.receive(event) } }
            #if os(iOS)
            guard await AVAudioApplication.requestRecordPermission() else { throw NSError(domain: "Composer", code: 2, userInfo: [NSLocalizedDescriptionKey: "Allow microphone access in iOS Settings."]) }
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.playAndRecord, mode: .default, options: [.mixWithOthers, .defaultToSpeaker, .allowBluetoothHFP])
            try audioSession.setActive(true)
            #endif
            let transcriber = SonioxClient(room: room, config: .init(mode: mode.rawValue, personalPrompt: prompt, terms: terms), audioOrigin: ProcessInfo.processInfo.systemUptime)
            self.transcriber = transcriber; try await transcriber.start(apiKey: soniox)
            let stream = try await mic.start(format: .init(sampleRate: 16000, channelCount: 1))
            let recorder = try ComposerAudioRecorder(url: log.audioURL)
            status = "listening"; onChange?()
            audioTask = Task { [weak self] in
                var converter = PCM16Converter()
                do {
                    for await chunk in stream { try Task.checkCancellation(); try recorder.append(chunk); try await transcriber.sendAudio(converter.convert(chunk)) }
                } catch is CancellationError {} catch { self?.fail(error) }
            }
        } catch { fail(error); try? await room?.cancel(); await cleanup() }
    }
    public func stop() async {
        guard isListening else { return }; status = "trailing"; onChange?()
        await mic.stop(); await audioTask?.value; audioTask = nil
        do { try await transcriber?.finish() } catch { fail(error) }
    }
    /// The surface inserts its currently rendered value synchronously, then calls this to cancel work.
    public func insert() async { _ = try? await room?.insert(); await cleanup(); status = "done"; onChange?() }
    public func cancel() async { try? await room?.cancel(); await cleanup(); status = "idle"; onChange?() }
    public func setMode(_ value: ComposerMode) async { mode = value; UserDefaults.standard.set(value.rawValue, forKey: "composer.mode"); try? await agents?.setMode(value); onChange?() }
    public func tap(lineID: String, wordID: String, timestamp: Double = ProcessInfo.processInfo.systemUptime) async { try? await binder?.tap(lineID: lineID, wordID: wordID, timestamp: timestamp) }
    public func pick(lineID: String, wordID: String, text: String) async { do { try await binder?.pick(lineID: lineID, wordID: wordID, text: text) } catch { fail(error) } }
    public func undo() async { guard let id = lastTransactionID else { return }; do { _ = try await room?.undoDocument(transactionID: id) } catch { fail(error) } }
    private func receive(_ event: Envelope) async {
        switch event.channel {
        case .docSnapshot: if let value = try? event.payload.decode(DocumentSnapshot.self) { snapshot = value }
        case .docOps: if let value = try? event.payload.decode(Transaction.self) { hunks = value.hunks; lastTransactionID = value.id }
        case .asrTail: if case .string(let value) = event.payload["text"] { tail = value }
        case .agentStatus:
            if case .bool(let value) = event.payload["busy"] { if value { busyParticipants.insert(event.participant) } else { busyParticipants.remove(event.participant) }; busy = !busyParticipants.isEmpty }
            if event.payload["event"] == .string("pending.edit"), let ids = try? event.payload["lines"]?.decode([String].self) { pendingLineIDs = Set(ids) }
            if event.payload["event"] == .string("error"), case .string(let message) = event.payload["message"] { error = message }
        case .session:
            if case .string(let value) = event.payload["state"] { status = value }
            if event.payload["event"] == .string("asr.error"), case .string(let message) = event.payload["message"] { error = message; status = "error"; await mic.stop() }
        default: break
        }
        if case .string(let value) = event.payload["mode"], let mode = ComposerMode(rawValue: value) { self.mode = mode }
        onChange?()
    }
    private func fail(_ failure: any Error) { error = failure.localizedDescription; status = "error"; onChange?() }
    private func cleanup() async {
        audioTask?.cancel(); await mic.stop(); await audioTask?.value; audioTask = nil
        await transcriber?.cancel(); transcriber = nil; await agents?.stop(); agents = nil
        await binder?.stop(); binder = nil; await alternatives?.stop(); alternatives = nil
        eventsTask?.cancel(); eventsTask = nil; busy = false; pendingLineIDs = []
    }
}

/// AAC is written from the same chunks forwarded to Soniox, keeping diagnostic audio aligned.
private final class ComposerAudioRecorder {
    private let file: AVAudioFile
    private let format: AVAudioFormat
    init(url: URL) throws {
        format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
        file = try AVAudioFile(forWriting: url, settings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 16000, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 64000], commonFormat: .pcmFormatFloat32, interleaved: false)
    }
    func append(_ chunk: AudioChunk) throws {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(chunk.samples.count)) else { return }
        buffer.frameLength = buffer.frameCapacity
        chunk.samples.withUnsafeBufferPointer { pointer in if let base = pointer.baseAddress { buffer.floatChannelData![0].update(from: base, count: pointer.count) } }
        try file.write(from: buffer)
    }
}
