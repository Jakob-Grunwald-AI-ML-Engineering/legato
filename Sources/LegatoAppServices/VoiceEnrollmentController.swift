import AVFoundation
import Foundation
import Observation
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

/// What the guided recording sheet shows. Nil on the controller when no guided recording runs.
public struct VoiceGuide: Equatable, Sendable {
    public var title: String
    public var isFirstSetup: Bool
    /// Preparing or saving, while nothing is being recorded.
    public var status: String
    public var isCapturing = false
    public var prompt: String?
    public var isQuiet = false
    public var quietRemaining = 0
    public var sentence = 0
    public var sentenceCount = 0
    public var stepProgress = 0.0
    public var progress = 0.0
    public var routeName: String?
    public var introduction: String {
        isFirstSetup ? "Find a quiet room where you are alone. Read each sentence aloud as it appears, in your normal voice."
            : "Speak as you normally would here. Read each sentence aloud as it appears; when asked, stay quiet and let the room be as it is."
    }
}

/// The voice setup flow behind Settings → Background voices (iPhone) and Settings → Voice (Mac): the guided first setup,
/// recorded settings, kept test recordings and deleting the voice. Capture reserves the microphone (dictation, the held
/// microphone and meetings refuse to start meanwhile). Audio stays in memory and is discarded after the profile is
/// computed, unless "Keep recordings for testing" is on.
@MainActor @Observable public final class VoiceEnrollmentController {
    public static let shared = VoiceEnrollmentController()
    public private(set) var isBusy = false
    public private(set) var isRecording = false
    public private(set) var progress = 0.0
    public private(set) var message: String?
    public private(set) var hasProfile = VoiceIsolationSettings.hasProfile
    public private(set) var stage = ""
    public private(set) var guide: VoiceGuide?
    public private(set) var situations: [VoiceSituationRow] = []
    public private(set) var recordings: [VoiceRecordingStore.Entry] = []
    public var keepRecordings = VoiceIsolationSettings.keepRecordings {
        didSet { VoiceIsolationSettings.keepRecordings = keepRecordings }
    }
    @ObservationIgnored private let service: VoiceIdentityService
    @ObservationIgnored private var operation: Task<Void, Never>?
    @ObservationIgnored private var microphone: (any AudioSource)?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var advanceRequested = false
    private static let cursorKey = "voiceIsolation.promptCursor"

    public init(service: VoiceIdentityService = .shared) { self.service = service }

    /// Reloads the settings list and the kept recordings (Settings calls this when it appears).
    public func refresh() {
        hasProfile = VoiceIsolationSettings.hasProfile
        let store = service.recordings
        Task {
            let set = (try? await service.profileSet()) ?? VoiceProfileSet()
            situations = Self.rows(set)
            recordings = store.list()
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

    // MARK: Recording

    /// The guided first setup: about a minute of reading in a quiet room. Saves the Alone setting and turns the option on.
    public func startFirstSetup(microphoneBusy: @escaping @MainActor () -> Bool) {
        run(situation: .alone, firstSetup: true, microphoneBusy: microphoneBusy)
    }
    /// Records one setting (about 40 s of reading with two quiet pauses) on the current microphone.
    public func record(situationID: String, microphoneBusy: @escaping @MainActor () -> Bool) {
        Task {
            guard let situation = ((try? await service.profileSet()) ?? VoiceProfileSet()).situations.first(where: { $0.id == situationID }) else { return }
            run(situation: situation, firstSetup: false, microphoneBusy: microphoneBusy)
        }
    }
    /// The user finished the sentence early: move on to the next step.
    public func advance() { if guide?.prompt != nil { advanceRequested = true } }

    private func run(situation: VoiceSituation, firstSetup: Bool, microphoneBusy: @escaping @MainActor () -> Bool) {
        guard !isBusy else { return }
        guard !microphoneBusy() else {
            message = "Stop dictation, meetings and the held microphone before recording your voice."
            return
        }
        let language = VoiceReadingPrompts.language()
        let script = firstSetup ? VoiceReadingScript.firstSetup(language: language)
            : VoiceReadingScript.setting(language: language, cursor: UserDefaults.standard.integer(forKey: Self.cursorKey))
        generation += 1
        let token = generation
        isBusy = true; message = nil; progress = 0; advanceRequested = false
        stage = "Downloading and preparing voice model…"
        guide = VoiceGuide(title: firstSetup ? "Set up your voice" : situation.name, isFirstSetup: firstSetup, status: stage,
                           sentenceCount: script.sentenceCount)
        operation = Task { [weak self] in
            guard let self else { return }
            var ownsAudioSession = false
            do {
                try await service.prepareModels()
                try Task.checkCancellation()
                guard token == generation else { return }
                guard !microphoneBusy() else { throw EnrollmentError.microphoneBusy }
                setStage("Requesting microphone access…")
                #if os(iOS)
                guard await AVAudioApplication.requestRecordPermission() else { throw EnrollmentError.permission }
                #else
                guard await AVCaptureDevice.requestAccess(for: .audio) else { throw EnrollmentError.permission }
                #endif
                try Task.checkCancellation()
                guard token == generation else { return }
                guard !microphoneBusy() else { throw EnrollmentError.microphoneBusy }
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
                try Task.checkCancellation()
                let route = Self.currentRoute(mic)
                let capture = try await capture(stream, script: script, route: route, microphoneBusy: microphoneBusy, mic: mic)
                await mic.stop(); microphone = nil; isRecording = false
                #if os(iOS)
                try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
                ownsAudioSession = false
                #endif
                try Task.checkCancellation()
                setStage("Saving your voice…")
                guide?.isCapturing = false
                var recordingID: String?
                if keepRecordings {
                    let sidecar = VoiceRecordingSidecar(kind: firstSetup ? .setup : .setting, situationID: situation.id,
                                                        situationName: situation.name, route: route,
                                                        language: script.language, intervals: capture.intervals)
                    try service.recordings.save(samples: capture.samples, sidecar: sidecar)
                    recordingID = sidecar.id
                }
                let segments = capture.intervals.filter { $0.kind == .reading }.map { interval in
                    Array(capture.samples[Int(interval.startMs * 16)..<min(capture.samples.count, Int(interval.endMs * 16))])
                }
                try await service.enroll(reading: segments, situation: situation, route: route, recordingID: recordingID)
                guard token == generation else { return }
                if !firstSetup { UserDefaults.standard.set(script.nextCursor, forKey: Self.cursorKey) }
                hasProfile = VoiceIsolationSettings.hasProfile
                if firstSetup {
                    VoiceIsolationSettings.enabled = true
                    message = "Your voice is set up and Reduce background voices is on. Record the places where you often dictate to help it further."
                } else {
                    message = "Saved \(situation.name) with \(route.displayName)."
                }
            } catch is CancellationError {
                if token == generation { message = "Recording cancelled." }
            } catch {
                if token == generation { message = error.localizedDescription }
            }
            await microphone?.stop(); microphone = nil
            #if os(iOS)
            // Release only the audio session owned by this recording.
            if ownsAudioSession { try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation) }
            #endif
            if token == generation {
                isBusy = false; isRecording = false; stage = ""; guide = nil; operation = nil
                refresh()
            }
        }
    }

    private struct Capture { var samples: [Float]; var intervals: [VoiceRecordingInterval] }

    /// Walks the script against the sample clock: each step ends after its planned length (a reading step also on
    /// `advance()`), and its interval is labelled from the samples actually recorded.
    private func capture(_ stream: AsyncStream<AudioChunk>, script: VoiceReadingScript, route: VoiceInputRoute,
                         microphoneBusy: @MainActor () -> Bool, mic: any AudioSource) async throws -> Capture {
        let rate = 16000.0
        var samples: [Float] = []
        samples.reserveCapacity(Int((script.plannedSeconds + 5) * rate))
        var intervals: [VoiceRecordingInterval] = []
        var index = 0, stepStart = 0
        isRecording = true
        guide?.isCapturing = true; guide?.routeName = route == .unknown ? nil : route.displayName
        updateGuide(script: script, index: 0, elapsed: 0, total: 0)
        // Ends the stream if capture stalls after an interruption or a device disconnect.
        let timeout = Task { try? await Task.sleep(for: .seconds(script.plannedSeconds + 20)); await mic.stop() }
        defer { timeout.cancel() }
        for await chunk in stream {
            try Task.checkCancellation()
            guard !microphoneBusy() else { throw EnrollmentError.microphoneBusy }
            samples.append(contentsOf: chunk.samples)
            while index < script.steps.count {
                let step = script.steps[index]
                let ended = samples.count - stepStart >= Int(step.seconds * rate) || (advanceRequested && step.prompt != nil)
                guard ended else { break }
                let start = Double(stepStart) / rate * 1000, end = Double(samples.count) / rate * 1000
                if let prompt = step.prompt {
                    intervals.append(.init(kind: .reading, startMs: start, endMs: end, prompt: prompt))
                } else {
                    intervals.append(.init(kind: .quiet, startMs: min(end, start + VoiceReadingScript.quietSettleSeconds * 1000), endMs: end))
                }
                advanceRequested = false; index += 1; stepStart = samples.count
            }
            if index == script.steps.count { break }
            updateGuide(script: script, index: index, elapsed: Double(samples.count - stepStart) / rate, total: Double(samples.count) / rate)
        }
        isRecording = false
        try Task.checkCancellation()
        guard index == script.steps.count else { throw EnrollmentError.interrupted }
        return Capture(samples: samples, intervals: intervals)
    }

    private func updateGuide(script: VoiceReadingScript, index: Int, elapsed: Double, total: Double) {
        let step = script.steps[index]
        let planned = script.plannedSeconds
        let done = script.steps.prefix(index).reduce(0) { $0 + $1.seconds } + min(elapsed, step.seconds)
        progress = min(1, done / max(1, planned))
        guide?.prompt = step.prompt
        guide?.isQuiet = step.prompt == nil
        guide?.quietRemaining = max(0, Int((step.seconds - elapsed).rounded(.up)))
        guide?.sentence = script.steps.prefix(index + 1).filter { $0.prompt != nil }.count
        guide?.stepProgress = min(1, elapsed / step.seconds)
        guide?.progress = progress
    }
    private func setStage(_ text: String) { stage = text; guide?.status = text }

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

    public func cancel() {
        operation?.cancel()
        let mic = microphone
        Task { await mic?.stop() }
    }

    // MARK: Settings and voice

    /// Adds the user's own setting; it is recorded like the suggested ones.
    public func addSituation(named name: String) {
        Task {
            do {
                if try await service.addSituation(named: name) == nil { message = "Choose a name that is not in the list yet." }
            } catch { message = error.localizedDescription }
            refresh()
        }
    }
    /// Deletes one of the user's own settings and its profiles.
    public func deleteSituation(id: String) {
        guard !isBusy else { return }
        Task {
            do { try await service.deleteSituation(id: id) } catch { message = error.localizedDescription }
            refresh()
        }
    }

    /// "Delete voice": every profile and kept recording; turns Reduce background voices off.
    public func deleteProfile() {
        guard !isBusy else { return }
        isBusy = true; message = nil; stage = "Deleting your voice…"
        operation = Task {
            do {
                try await service.deleteProfile()
                VoiceIsolationSettings.enabled = false
                hasProfile = false; message = "Your voice and its recordings are deleted. Reduce background voices is off."
            } catch { message = error.localizedDescription }
            isBusy = false; stage = ""; operation = nil
            refresh()
        }
    }

    // MARK: Kept recordings

    /// Every kept recording and the profiles, as one zip for the share sheet (AirDrop to the Mac replay tool).
    public func exportAll() -> VoiceRecordingExport {
        let store = service.recordings, folders = recordings.map(\.folder), profiles = service.profilesURL
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyy-MM-dd HHmm"
        let name = "Legato voice recordings \(formatter.string(from: Date()))"
        return VoiceRecordingExport(name: name) { try store.archive(folders, extras: [profiles], name: name) }
    }
    /// One recording (audio and its JSON) as a zip.
    public func export(_ entry: VoiceRecordingStore.Entry) -> VoiceRecordingExport {
        let store = service.recordings, folder = entry.folder
        return VoiceRecordingExport(name: folder.lastPathComponent) { try store.archive([folder], name: folder.lastPathComponent) }
    }

    private enum EnrollmentError: LocalizedError {
        case permission, microphoneBusy, interrupted
        var errorDescription: String? {
            switch self {
            case .permission: "Allow microphone access in system Settings, then try recording again."
            case .microphoneBusy: "Stop dictation, meetings and the held microphone before recording your voice."
            case .interrupted: "The recording was interrupted. Keep Legato open and try again."
            }
        }
    }
}
