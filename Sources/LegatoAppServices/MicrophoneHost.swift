import AVFAudio
import Foundation
import Observation
import LegatoAudio
import LegatoCore

/// Owns microphone capture and routing independently of a writing session.
@MainActor @Observable public final class MicrophoneHost {
    public private(set) var status = "idle"
    public private(set) var error: String?
    public private(set) var errorDetail: String?
    public private(set) var isArmed = false
    public private(set) var microphoneRecovering = false
    public var isListening: Bool { route == .dictation }
    public var onChange: (@MainActor () -> Void)?
    public var inputRoute: InputRoutePolicy = .none
    public private(set) var route = AudioRoute.idle
    @ObservationIgnored private let mic: any AudioSource
    @ObservationIgnored private let activateAudioSession: @MainActor () async throws -> Void
    private var keepMicrophoneActive = true
    @ObservationIgnored private var microphoneEpoch = UUID()
    @ObservationIgnored private var microphonePreparation: (id: UUID, task: Task<AsyncStream<AudioChunk>, any Error>)?
    @ObservationIgnored private var microphoneMonitor: Task<Void, Never>?
    @ObservationIgnored private var warmInput: Task<Void, Never>?
    @ObservationIgnored private var warmInputToken: UUID?
    public var holdsWarmInput: Bool { warmInput != nil }
    @ObservationIgnored var dictationAudio: (@MainActor (Data) async -> Void)?
    @ObservationIgnored private(set) var routedAudioAt: Double?
    private var pendingAudioRoute: AudioRoute?
    private var takeAudioBuffer = TakeAudioBuffer()
    private(set) var takeBufferFailure: (any Error)?
    var bufferedTakeFrames: Int { takeAudioBuffer.frameCount }
    private(set) var consumedWarmInputChunks = 0
    let vocabularyURL: URL
    public init(vocabularyURL: URL = URL.applicationSupportDirectory.appending(path: "Legato/vocabulary.json"), keepMicrophoneActive: Bool = true) {
        self.vocabularyURL = vocabularyURL
        self.keepMicrophoneActive = keepMicrophoneActive
        mic = AutomaticInputSource()
        activateAudioSession = Self.activateMicrophoneSession
    }
    init(microphone: any AudioSource, activateAudioSession: @escaping @MainActor () async throws -> Void) {
        vocabularyURL = URL.applicationSupportDirectory.appending(path: "Legato/vocabulary.json")
        mic = microphone
        self.activateAudioSession = activateAudioSession
    }
    #if DEBUG || LEGATO_INTERNAL
    public var debugState: [String: Any] {
        ["status": status, "armed": isArmed, "recovering": microphoneRecovering, "route": route.rawValue,
         "warmInput": holdsWarmInput, "reserved": microphoneReserved, "error": error as Any]
    }
    public func interruptMicrophoneForDiagnostics() async { await mic.stop() }
    #endif
    /// Set by the host before handing the microphone to a meeting. Every admission path observes it.
    public var microphoneReserved = false

    /// Release capture and warm streams before handing the microphone to a meeting.
    public func suspendMicrophoneForMeeting() async {
        microphoneReserved = true
        invalidateMicrophoneAdmission()
        setRoute(.idle)
        isArmed = false
        await releaseWarmInput()
        await mic.stop()
        onChange?()
    }

    public func arm() async {
        guard !VoiceEnrollmentController.shared.isBusy else { error = "Finish or cancel voice profile setup first."; onChange?(); return }
        guard !microphoneReserved else { return }
        // A repeated ready request must not replace the stream of a running take.
        // The capture watchdog owns repair of an existing lease.
        guard !isArmed else { return }
        let epoch = microphoneEpoch
        status = "starting"; onChange?()
        do {
            _ = try await prepareMicrophoneStream()
            try checkMicrophoneEpoch(epoch)
            isArmed = true; error = nil; status = "ready"; onChange?()
            monitorMicrophone()
            await inputRoute.preferIdle()
        } catch is CancellationError {
            // A released/superseded admission must not become a visible failure.
        } catch { fail(error) }
    }
    private static func activateMicrophoneSession() async throws {
        #if os(iOS)
        guard await AVAudioApplication.requestRecordPermission() else {
            throw NSError(domain: "Composer", code: 2, userInfo: [NSLocalizedDescriptionKey: "Allow microphone access in iOS Settings."])
        }
        try AudioSessionController.configureMicrophoneCapture(combineInputs: ComposerMicrophonePreference.combineInputs())
        #endif
    }
    func prepareMicrophoneStream() async throws -> AsyncStream<AudioChunk> {
        guard !microphoneReserved else { throw CancellationError() }
        if let pending = microphonePreparation { return try await pending.task.value }
        let id = UUID(), epoch = microphoneEpoch
        let task = Task { try await self.acquireMicrophoneStream(epoch: epoch) }
        microphonePreparation = (id, task)
        defer { if microphonePreparation?.id == id { microphonePreparation = nil } }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: { task.cancel() }
    }
    private func acquireMicrophoneStream(epoch: UUID) async throws -> AsyncStream<AudioChunk> {
        let held = isArmed
        for attempt in 0..<3 {
            try checkMicrophoneEpoch(epoch)
            do {
                let stream: AsyncStream<AudioChunk>
                if held && attempt == 0 { stream = try await mic.route() }
                else {
                    // Rebuild on the existing active session first. Reconfiguring even the same
                    // category in the background can be refused by iOS.
                    if !held { try await activateAudioSession() }
                    #if os(iOS)
                    if held { try AudioSessionController().reactivate() }
                    #endif
                    try checkMicrophoneEpoch(epoch)
                    stream = try await mic.start(format: .init(sampleRate: 16000, channelCount: 1))
                }
                try checkMicrophoneEpoch(epoch)
                isArmed = held || keepMicrophoneActive
                microphoneRecovering = false
                monitorMicrophone()
                onChange?()
                return stream
            } catch {
                guard epoch == microphoneEpoch else { throw CancellationError() }
                await mic.stop()
                if Task.isCancelled { isArmed = false; microphoneRecovering = false; throw CancellationError() }
                try checkMicrophoneEpoch(epoch)
                guard attempt < 2, Self.transientMicrophoneFailure(error) else {
                    isArmed = false; microphoneRecovering = false; onChange?()
                    throw error is CancellationError ? AutomaticInputError.noPCM : error
                }
                microphoneRecovering = true; onChange?()
                try await Task.sleep(for: .milliseconds(150 * (attempt + 1)))
            }
        }
        throw AutomaticInputError.noPCM
    }
    private func checkMicrophoneEpoch(_ expected: UUID) throws {
        try Task.checkCancellation()
        guard !microphoneReserved, expected == microphoneEpoch else { throw CancellationError() }
    }
    private static func transientMicrophoneFailure(_ error: any Error) -> Bool {
        if error is CancellationError || error is AutomaticInputError { return true }
        if let mic = error as? MicSourceError { return mic == .notArmed || mic == .invalidInputFormat }
        let ns = error as NSError
        return (ns.domain == NSOSStatusErrorDomain || ns.domain == "com.apple.coreaudio.avfaudio")
            && [560_557_684, 561_015_905, 561_145_187, 2_003_329_396].contains(ns.code)
    }
    private func monitorMicrophone() {
        guard microphoneMonitor == nil, let automatic = mic as? AutomaticInputSource else { return }
        let epoch = microphoneEpoch
        microphoneMonitor = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
                guard let self, epoch == self.microphoneEpoch else { return }
                let health = automatic.diagnostics
                switch health.state {
                case "capturing":
                    let stale = health.lastBufferUptime.map { ProcessInfo.processInfo.systemUptime - $0 > 2.5 } ?? true
                    if self.microphoneRecovering != stale { self.microphoneRecovering = stale; self.onChange?() }
                case "starting", "recovering":
                    if !self.microphoneRecovering { self.microphoneRecovering = true; self.onChange?() }
                case "failed":
                    self.isArmed = false; self.microphoneRecovering = false
                    self.microphoneMonitor = nil
                    self.deactivateMicrophoneSession()
                    self.fail(AutomaticInputError.noPCM)
                    return
                default: break
                }
            }
        }
    }
    private func deactivateMicrophoneSession() {
        #if os(iOS)
        // In particular, dual-route capture is non-mixable. Stopping its engine alone
        // must not leave other apps' audio interrupted after the lease is released.
        AudioSessionController().deactivate()
        #endif
    }
    private func invalidateMicrophoneAdmission() {
        microphoneEpoch = UUID()
        microphonePreparation?.task.cancel(); microphonePreparation = nil

        microphoneMonitor?.cancel(); microphoneMonitor = nil
        microphoneRecovering = false
    }
    /// Changes retention only; enabling this setting never starts a microphone.
    public func setKeepMicrophoneActive(_ value: Bool) async {
        keepMicrophoneActive = value
        if !value, !isListening { invalidateMicrophoneAdmission(); isArmed = false; await mic.stop(); deactivateMicrophoneSession(); onChange?() }
    }
    /// Opting out stops capture on backgrounding.
    public func prepareForBackground() async {

        guard !keepMicrophoneActive else { return }
        setRoute(.idle)
        invalidateMicrophoneAdmission(); isArmed = false; await mic.stop(); deactivateMicrophoneSession(); onChange?()
    }
    public func releaseMicrophone() async {
        guard !microphoneReserved else { return }
        invalidateMicrophoneAdmission()
        isArmed = false
        discardTakeBuffer()
        await releaseWarmInput()
        await mic.stop()
        // A meeting can reserve and activate the shared audio session while capture is stopping.
        if !microphoneReserved { deactivateMicrophoneSession() }
        onChange?()
    }
    func holdWarmInput() async -> Bool {
        guard !VoiceEnrollmentController.shared.isBusy else { error = "Finish or cancel voice profile setup first."; onChange?(); return false }
        if warmInput != nil { return true }
        guard !microphoneReserved, isArmed, !isListening, status != "starting" else { return false }
        do {
            let stream = try await prepareMicrophoneStream()
            let token = UUID(); warmInputToken = token; route = .idle
            warmInput = Task { [weak self] in
                var converter = PCM16Converter()
                for await chunk in stream {
                    guard !Task.isCancelled, let self else { return }
                    await self.routeChunk(chunk, converter: &converter)
                    self.consumedWarmInputChunks += 1
                }
                self?.warmInputEnded(token)
            }
            await inputRoute.preferIdle()
            return true
        } catch { return false }
    }
    /// A take is about to route audio: the headset's mic, if one is connected. Never fails the take.
    func preferTakeInput() async { await inputRoute.preferTake() }
    /// The hold is idle again (hold established, take closed): the built-in mic.
    func preferIdleInput() async { await inputRoute.preferIdle() }
    /// Buffer capture while a take connection is preparing.
    func beginTakeBuffer(for target: AudioRoute) {
        pendingAudioRoute = target; takeAudioBuffer.removeAll(); takeBufferFailure = nil
    }
    func discardTakeBuffer() { pendingAudioRoute = nil; takeAudioBuffer.removeAll(); takeBufferFailure = nil }
    func setRoute(_ value: AudioRoute) {
        guard warmInput != nil || value == .idle else { return }
        if value != route { routedAudioAt = nil }
        if value == .idle { discardTakeBuffer() }
        else if pendingAudioRoute == value { pendingAudioRoute = nil }
        route = value; onChange?()
    }
    private func routeChunk(_ chunk: AudioChunk, converter: inout PCM16Converter) async {
        if route == .idle, pendingAudioRoute != nil {
            do { try takeAudioBuffer.append(chunk) }
            catch { discardTakeBuffer(); takeBufferFailure = error; fail(error) }
            return
        }
        let buffered = takeAudioBuffer.takeAll()
        let target = route
        for captured in buffered + [chunk] {
            guard route == target, route != .idle else { break }
            await routeCapturedChunk(captured, converter: &converter)
        }
    }
    private func routeCapturedChunk(_ chunk: AudioChunk, converter: inout PCM16Converter) async {
        switch route {
        case .idle: return
        case .dictation:
            guard let pcm = try? converter.convert(chunk) else { return }
            if routedAudioAt == nil { routedAudioAt = ProcessInfo.processInfo.systemUptime }
            await dictationAudio?(pcm)
        }
    }
    private func warmInputEnded(_ token: UUID) {
        guard warmInputToken == token else { return }
        warmInput = nil; warmInputToken = nil
        isArmed = false; microphoneRecovering = false
        let wasRouting = route != .idle
        route = .idle
        if wasRouting { fail(AutomaticInputError.noPCM) }
        onChange?()
    }
    func releaseWarmInput() async {
        discardTakeBuffer()
        route = .idle
        guard let task = warmInput else { return }
        warmInput = nil; warmInputToken = nil
        task.cancel()
        if isListening { return }
        if isArmed && keepMicrophoneActive { await mic.detach() } else { isArmed = false; await mic.stop(); deactivateMicrophoneSession() }
    }
    /// The keyboard went away: release its warm input stream.
    func endKeyboardSession() async {
        route = .idle
        await releaseWarmInput()
        onChange?()
    }
    private func fail(_ failure: any Error) {
        guard !(failure is CancellationError) else { return }
        errorDetail = String(describing: failure)
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
}
