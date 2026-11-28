import AVFoundation
import Foundation
import Observation
import Synchronization
import LegatoAudio
import LegatoCore
import LegatoVoiceIdentity

/// One row of the settings list: a setting (a place or situation, only a name) and the microphones it was recorded on.
public struct VoiceSituationRow: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let isCustom: Bool
    /// Display names of the routes recorded for this setting, oldest first.
    public let routes: [String]
    public let lastRecorded: Date?
    public var isRecorded: Bool { lastRecorded != nil }
    /// "AirPods Pro · iPhone Microphone", or "Not recorded yet".
    public var detail: String { routes.isEmpty ? "Not recorded yet" : routes.joined(separator: " · ") }
}

/// What the guided recording sheet shows; it changes only from step to step. The fast-changing progress and
/// countdown live in ``VoiceCaptureMeter``, so they redraw only the views that show them.
public struct VoiceGuide: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        /// Downloading the model or asking for the microphone (`status`).
        case preparing
        /// The first sentence is shown; recording starts when the user presses Start.
        case ready
        /// Start was pressed and the microphone is starting.
        case starting
        case reading, quiet
        /// Computing and saving the profile (`status`).
        case saving
        /// The outcome is `status`.
        case saved, failed
    }
    public var title: String
    public var isFirstSetup: Bool
    public var phase: Phase = .preparing
    /// The status while preparing or saving; the outcome once saved or failed.
    public var status: String
    /// The sentence to read: the first one before Start, then the current one.
    public var prompt: String?
    public var sentence = 1
    public var sentenceCount = 0
    public var routeName: String?
    public var isActive: Bool { phase != .saved && phase != .failed }
    public var introduction: String { VoiceSetupCopy.introduction(firstSetup: isFirstSetup) }
}

/// The progress of a guided recording, updated about ten times a second while it runs.
@MainActor @Observable public final class VoiceCaptureMeter {
    public private(set) var progress = 0.0
    public private(set) var stepProgress = 0.0
    public private(set) var quietRemaining = 0
    /// Assigns only what changed visibly, so an unchanged value redraws nothing.
    func show(progress: Double, stepProgress: Double, quietRemaining: Int) {
        if progress != self.progress, abs(progress - self.progress) >= 0.005 || progress == 0 || progress == 1 { self.progress = progress }
        if stepProgress != self.stepProgress, abs(stepProgress - self.stepProgress) >= 0.01 || stepProgress == 0 || stepProgress == 1 {
            self.stepProgress = stepProgress
        }
        if quietRemaining != self.quietRemaining { self.quietRemaining = quietRemaining }
    }
}

/// An outcome shown next to what the user acted on; the next action clears it. Recording outcomes are shown in the
/// recording sheet instead.
public struct VoiceNotice: Equatable, Sendable {
    public enum Place: Sendable { case voice, settings, recordings }
    public var place: Place
    public var text: String
}

/// Collects a guided recording off the main actor: the microphone's chunks go straight into the samples and the
/// schedule, so a busy main thread neither drops audio nor slows the recording's clock. The main actor reads a
/// snapshot about ten times a second. The recording counts as stalled only when no audio arrived for
/// `stallSeconds`: the schedule runs on audio time, so wall time alone never ends it.
final class VoiceCaptureRecorder: Sendable {
    enum State: Equatable, Sendable { case running, finished, stalled, ended }
    struct Snapshot: Equatable, Sendable {
        var state: State
        var stepIndex: Int
        var sentence: Int
        var progress: Double
        var stepProgress: Double
        var quietRemaining: Int
    }
    private struct Box {
        var schedule: VoiceCaptureSchedule
        var samples: [Float]
        var lastAudio: Double
        var ended = false
    }
    private let box: Mutex<Box>
    private let clock: @Sendable () -> Double
    let stallSeconds: Double

    init(script: VoiceReadingScript, sampleRate: Double = 16000, stallSeconds: Double = 6,
         clock: @escaping @Sendable () -> Double = { ProcessInfo.processInfo.systemUptime }) {
        var samples: [Float] = []
        samples.reserveCapacity(Int((script.steps.reduce(0) { $0 + $1.maximumSeconds } + 2) * sampleRate))
        box = Mutex(Box(schedule: VoiceCaptureSchedule(script: script, sampleRate: sampleRate), samples: samples, lastAudio: clock()))
        self.clock = clock; self.stallSeconds = stallSeconds
    }

    /// Takes a chunk into the recording; false once the script is finished (later audio is not part of it).
    @discardableResult
    func append(_ chunk: [Float]) -> Bool {
        let now = clock()
        return box.withLock { box in
            let taken = box.schedule.consume(chunk)
            box.samples.append(contentsOf: chunk.prefix(taken))
            box.lastAudio = now
            return !box.schedule.isFinished
        }
    }
    func requestAdvance() { box.withLock { $0.schedule.requestAdvance() } }
    /// The microphone's stream ended.
    func markEnded() { box.withLock { $0.ended = true } }

    func snapshot() -> Snapshot {
        let now = clock()
        return box.withLock { box in
            let schedule = box.schedule
            let state: State = schedule.isFinished ? .finished : box.ended ? .ended
                : now - box.lastAudio > stallSeconds ? .stalled : .running
            return Snapshot(state: state, stepIndex: schedule.stepIndex, sentence: schedule.sentence, progress: schedule.progress,
                            stepProgress: schedule.stepProgress, quietRemaining: schedule.quietRemaining)
        }
    }
    func result() -> (samples: [Float], intervals: [VoiceRecordingInterval]) {
        box.withLock { ($0.samples, $0.schedule.intervals) }
    }
}

/// The voice setup flow behind Settings → Background voices (iPhone) and Settings → Voice (Mac): the guided first setup,
/// recorded settings, kept test recordings and deleting the voice. Capture reserves the microphone (dictation, the held
/// microphone and meetings refuse to start meanwhile). Audio stays in memory and is discarded after the profile is
/// computed, unless "Keep recordings for testing" is on.
@MainActor @Observable public final class VoiceEnrollmentController {
    public static let shared = VoiceEnrollmentController()
    public private(set) var isBusy = false
    public private(set) var hasProfile = VoiceIsolationSettings.hasProfile
    public private(set) var guide: VoiceGuide?
    /// Whether the recording sheet is shown; changes only when it opens or closes.
    public private(set) var isGuidePresented = false
    public private(set) var notice: VoiceNotice?
    public private(set) var situations: [VoiceSituationRow] = []
    public private(set) var recordings: [VoiceRecordingStore.Entry] = []
    public var keepRecordings = VoiceIsolationSettings.keepRecordings {
        didSet { VoiceIsolationSettings.keepRecordings = keepRecordings }
    }
    public let meter = VoiceCaptureMeter()
    @ObservationIgnored private let service: VoiceIdentityService
    @ObservationIgnored private var operation: Task<Void, Never>?
    @ObservationIgnored private var microphone: (any AudioSource)?
    @ObservationIgnored private var recorder: VoiceCaptureRecorder?
    @ObservationIgnored private var startSignal: AsyncStream<Void>.Continuation?
    @ObservationIgnored private var lastRequest: (situation: VoiceSituation, firstSetup: Bool, microphoneBusy: @MainActor () -> Bool)?
    @ObservationIgnored private var generation = 0

    public init(service: VoiceIdentityService = .shared) { self.service = service }

    /// Reloads the settings list and the kept recordings (Settings calls this when it appears).
    public func refresh() {
        hasProfile = VoiceIsolationSettings.hasProfile
        let store = service.recordings
        Task {
            let set = (try? await service.profileSet()) ?? VoiceProfileSet()
            let rows = Self.rows(set)
            if rows != situations { situations = rows }
            let kept = store.list()
            if kept != recordings { recordings = kept }
        }
    }
    static func rows(_ set: VoiceProfileSet) -> [VoiceSituationRow] {
        set.situations.map { situation in
            let profiles = set.profiles.filter { $0.situationID == situation.id }.sorted { $0.date < $1.date }
            var routes: [String] = []
            for name in profiles.map(\.route.displayName) where !routes.contains(name) { routes.append(name) }
            return VoiceSituationRow(id: situation.id, name: situation.name, isCustom: situation.isCustom,
                                     routes: routes, lastRecorded: profiles.map(\.date).max())
        }
    }

    /// The text of the current notice, if it belongs at `place`.
    public func notice(for place: VoiceNotice.Place) -> String? { notice?.place == place ? notice?.text : nil }
    /// The option was touched before a voice was set up.
    public func explainSetupFirst() { notice = .init(place: .voice, text: VoiceSetupCopy.setUpFirst) }
    public func clearNotice() { if notice != nil { notice = nil } }

    // MARK: Recording

    /// The guided first setup: about a minute of reading in a quiet room. Saves the Alone setting and turns the option on.
    public func startFirstSetup(microphoneBusy: @escaping @MainActor () -> Bool) {
        run(situation: .alone, firstSetup: true, microphoneBusy: microphoneBusy)
    }
    /// Records one setting (about 40 s of reading with two quiet pauses) on the current microphone.
    public func record(situationID: String, microphoneBusy: @escaping @MainActor () -> Bool) {
        clearNotice()
        Task {
            guard let situation = ((try? await service.profileSet()) ?? VoiceProfileSet()).situations.first(where: { $0.id == situationID }) else { return }
            run(situation: situation, firstSetup: false, microphoneBusy: microphoneBusy)
        }
    }
    /// Start: the user has seen the first sentence and begins reading.
    public func start() { if guide?.phase == .ready { startSignal?.yield(()) } }
    /// Next sentence: the user finished the sentence early.
    public func advance() { recorder?.requestAdvance() }
    /// Try again after a failed recording, with the same setting.
    public func retry() {
        guard let request = lastRequest, !isBusy else { return }
        run(situation: request.situation, firstSetup: request.firstSetup, microphoneBusy: request.microphoneBusy)
    }
    /// Done, or the sheet was dismissed: cancels a recording that still runs.
    public func closeGuide() {
        if isBusy { cancel() } else { guide = nil; isGuidePresented = false }
    }

    private func run(situation: VoiceSituation, firstSetup: Bool, microphoneBusy: @escaping @MainActor () -> Bool) {
        guard !isBusy else { return }
        clearNotice()
        lastRequest = (situation, firstSetup, microphoneBusy)
        let language = VoiceReadingPrompts.language()
        let script = firstSetup ? VoiceReadingScript.firstSetup(language: language)
            : VoiceReadingScript.setting(language: language, cursor: VoiceIsolationSettings.promptCursor)
        generation += 1
        let token = generation
        meter.show(progress: 0, stepProgress: 0, quietRemaining: 0)
        guide = VoiceGuide(title: firstSetup ? VoiceSetupCopy.setupButton : situation.name, isFirstSetup: firstSetup,
                           status: VoiceSetupCopy.preparing, prompt: script.steps.first?.prompt, sentenceCount: script.sentenceCount)
        isGuidePresented = true
        guard !microphoneBusy() else {
            guide?.phase = .failed; guide?.status = VoiceSetupCopy.microphoneBusy
            return
        }
        isBusy = true
        let (starts, startContinuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        startSignal = startContinuation
        operation = Task { [weak self] in
            await self?.perform(token: token, situation: situation, firstSetup: firstSetup, script: script, starts: starts,
                                microphoneBusy: microphoneBusy)
        }
    }

    private func check(_ token: Int) throws {
        try Task.checkCancellation()
        guard token == generation else { throw CancellationError() }
    }

    private func perform(token: Int, situation: VoiceSituation, firstSetup: Bool, script: VoiceReadingScript,
                         starts: AsyncStream<Void>, microphoneBusy: @escaping @MainActor () -> Bool) async {
        var ownsAudioSession = false
        do {
            try await service.prepareModels()
            try check(token)
            setStatus(VoiceSetupCopy.requestingMicrophone)
            #if os(iOS)
            guard await AVAudioApplication.requestRecordPermission() else { throw EnrollmentError.permission }
            #else
            guard await AVCaptureDevice.requestAccess(for: .audio) else { throw EnrollmentError.permission }
            #endif
            try check(token)
            guide?.phase = .ready
            var waiting = starts.makeAsyncIterator()
            guard await waiting.next() != nil else { throw CancellationError() }
            try check(token)
            guard !microphoneBusy() else { throw EnrollmentError.microphoneBusy }
            // Every started recording moves the rotation on, so the next one reads other sentences even if this fails.
            if !firstSetup { VoiceIsolationSettings.promptCursor = script.nextCursor }
            guide?.phase = .starting
            #if os(iOS)
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .default, options: [.mixWithOthers, .defaultToSpeaker, .allowBluetoothHFP])
            try session.setActive(true)
            ownsAudioSession = true
            let mic = MicSource()
            #else
            // The Mac records from the microphone dictation uses, so the profile belongs to that route.
            let mic = AutomaticInputSource(preference: { MicrophonePreference.dictation() })
            #endif
            microphone = mic
            let stream = try await mic.start(format: .init(sampleRate: 16000, channelCount: 1))
            try check(token)
            let route = Self.currentRoute(mic)
            guide?.routeName = route == .unknown ? nil : route.displayName
            let capture = try await capture(stream, script: script, microphoneBusy: microphoneBusy)
            await mic.stop(); microphone = nil
            #if os(iOS)
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            ownsAudioSession = false
            #endif
            try check(token)
            guide?.phase = .saving
            setStatus(VoiceSetupCopy.saving(firstSetup: firstSetup, name: situation.name))
            let segments = capture.intervals.filter { $0.kind == .reading }.map { interval in
                Array(capture.samples[min(capture.samples.count, Int(interval.startMs * 16))..<min(capture.samples.count, Int(interval.endMs * 16))])
            }
            let kept = keepRecordings ? (samples: capture.samples, sidecar: VoiceRecordingSidecar(
                kind: firstSetup ? .setup : .setting, situationID: situation.id, situationName: situation.name, route: route,
                language: script.language, intervals: capture.intervals)) : nil
            try await service.enroll(reading: segments, situation: situation, route: route, keeping: kept)
            try check(token)
            hasProfile = VoiceIsolationSettings.hasProfile
            if firstSetup { VoiceIsolationSettings.enabled = true }
            guide?.phase = .saved
            guide?.status = VoiceSetupCopy.recorded(firstSetup: firstSetup, name: situation.name, route: route.displayName)
        } catch is CancellationError {
            // Cancel closed the sheet; nothing to report.
        } catch {
            if token == generation {
                guide?.phase = .failed
                guide?.status = Self.failure(error, firstSetup: firstSetup, name: situation.name)
            }
        }
        await microphone?.stop(); microphone = nil
        #if os(iOS)
        // Release only the audio session owned by this recording.
        if ownsAudioSession { try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation) }
        #endif
        if token == generation {
            isBusy = false; operation = nil; recorder = nil; startSignal = nil
            refresh()
        }
    }

    /// Feeds the microphone into a ``VoiceCaptureRecorder`` off the main actor, and shows its progress here.
    private func capture(_ stream: AsyncStream<AudioChunk>, script: VoiceReadingScript,
                         microphoneBusy: @MainActor () -> Bool) async throws -> (samples: [Float], intervals: [VoiceRecordingInterval]) {
        let recorder = VoiceCaptureRecorder(script: script)
        self.recorder = recorder
        let consumer = Task.detached(priority: .userInitiated) {
            for await chunk in stream {
                guard recorder.append(chunk.samples) else { break }
            }
            recorder.markEnded()
        }
        defer { consumer.cancel() }
        var shownStep = -1
        while true {
            let snapshot = recorder.snapshot()
            if snapshot.stepIndex != shownStep, snapshot.stepIndex < script.steps.count {
                shownStep = snapshot.stepIndex
                let step = script.steps[snapshot.stepIndex]
                guide?.phase = step.prompt == nil ? .quiet : .reading
                if let prompt = step.prompt { guide?.prompt = prompt }
                guide?.sentence = max(1, snapshot.sentence)
            }
            meter.show(progress: snapshot.progress, stepProgress: snapshot.stepProgress, quietRemaining: snapshot.quietRemaining)
            switch snapshot.state {
            case .finished: return recorder.result()
            case .stalled, .ended: throw EnrollmentError.interrupted
            case .running: break
            }
            try await Task.sleep(for: .milliseconds(100))
            try Task.checkCancellation()
            guard !microphoneBusy() else { throw EnrollmentError.microphoneBusy }
        }
    }

    private func setStatus(_ text: String) { guide?.status = text }

    /// The input the recording actually uses, as LegatoAudio classifies it.
    private static func currentRoute(_ mic: any AudioSource) -> VoiceInputRoute {
        #if os(iOS)
        let status = AutomaticInputSource.platformStatus()
        let candidate = status.available.first { $0.kind == .combined } ?? status.available.first { status.currentIDs.contains($0.id) }
        #else
        let candidate = (mic as? AutomaticInputSource)?.diagnostics.selected
        #endif
        guard let candidate else { return .unknown }
        return VoiceInputRoute(kind: candidate.kind.rawValue, name: candidate.name)
    }

    /// Stops a running recording and closes the sheet.
    public func cancel() {
        operation?.cancel()
        startSignal?.finish()
        let mic = microphone
        Task { await mic?.stop() }
        if guide != nil { guide = nil }
        if isGuidePresented { isGuidePresented = false }
    }

    // MARK: Settings and voice

    /// Adds the user's own setting; it is recorded like the suggested ones.
    public func addSituation(named name: String) {
        clearNotice()
        Task {
            do {
                if try await service.addSituation(named: name) == nil { notice = .init(place: .settings, text: VoiceSetupCopy.nameTaken) }
            } catch { notice = .init(place: .settings, text: error.localizedDescription) }
            refresh()
        }
    }
    /// Deletes one of the user's own settings and its profiles.
    public func deleteSituation(id: String) {
        guard !isBusy else { return }
        clearNotice()
        Task {
            do { try await service.deleteSituation(id: id) } catch { notice = .init(place: .settings, text: error.localizedDescription) }
            refresh()
        }
    }

    /// "Delete voice": every profile and kept recording; turns Reduce background voices off.
    public func deleteProfile() {
        guard !isBusy else { return }
        clearNotice()
        isBusy = true
        operation = Task {
            do {
                try await service.deleteProfile()
                VoiceIsolationSettings.enabled = false
                hasProfile = false
                notice = .init(place: .voice, text: VoiceSetupCopy.deleted)
            } catch { notice = .init(place: .voice, text: error.localizedDescription) }
            isBusy = false; operation = nil
            refresh()
        }
    }

    // MARK: Kept recordings

    /// Every kept recording and the profiles, as one zip for the share sheet (AirDrop to the Mac replay tool).
    public func exportAll() -> VoiceRecordingExport {
        let store = service.recordings, folders = recordings.map(\.folder), profiles = service.profilesURL
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyy-MM-dd HHmm"
        let name = "Legato voice recordings \(formatter.string(from: Date()))"
        return VoiceRecordingExport(name: name, title: VoiceSetupCopy.exportAll) { try store.archive(folders, extras: [profiles], name: name) }
    }
    /// One recording (audio and its JSON) as a zip.
    public func export(_ entry: VoiceRecordingStore.Entry) -> VoiceRecordingExport {
        let store = service.recordings, folder = entry.folder, name = "Legato voice recording " + folder.lastPathComponent
        return VoiceRecordingExport(name: name, title: VoiceSetupCopy.recordingTitle(entry)) { try store.archive([folder], name: name) }
    }
    /// Writes an export to a file the user chose (the Mac's Save to folder…).
    public func save(_ export: VoiceRecordingExport, to destination: URL) {
        clearNotice()
        Task {
            do {
                try await Task.detached(priority: .userInitiated) { try export.write(to: destination) }.value
                notice = .init(place: .recordings, text: VoiceSetupCopy.savedFile(destination))
            } catch { notice = .init(place: .recordings, text: VoiceSetupCopy.saveFailed) }
        }
    }

    private enum EnrollmentError: Error { case permission, microphoneBusy, interrupted }

    /// What a failed recording says, worded for the first setup or the setting.
    static func failure(_ error: any Error, firstSetup: Bool, name: String) -> String {
        switch error as? EnrollmentError {
        case .permission: return VoiceSetupCopy.microphonePermission
        case .microphoneBusy: return VoiceSetupCopy.microphoneBusy
        case .interrupted: return VoiceSetupCopy.interrupted
        case nil: break
        }
        if case .invalidEnrollment? = error as? VoiceIdentityError { return VoiceSetupCopy.tooLittleSpeech(firstSetup: firstSetup, name: name) }
        return error.localizedDescription
    }
}
