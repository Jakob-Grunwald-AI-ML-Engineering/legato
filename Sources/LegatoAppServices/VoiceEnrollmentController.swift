import AVFoundation
import Foundation
import Observation
import LegatoAudio
import LegatoVoiceIdentity

/// Settings-only capture. Samples stay in memory and are discarded after embedding or cancellation.
@MainActor @Observable public final class VoiceEnrollmentController {
    public static let shared = VoiceEnrollmentController()
    public private(set) var isBusy = false
    public private(set) var isRecording = false
    public private(set) var progress = 0.0
    public private(set) var message: String?
    public private(set) var hasProfile = VoiceIsolationSettings.hasProfile
    public private(set) var stage = ""
    @ObservationIgnored private var operation: Task<Void, Never>?
    @ObservationIgnored private var microphone: MicSource?
    @ObservationIgnored private var generation = 0

    public init() {}

    /// The guard is checked again after downloads and before touching microphone/session state.
    public func record(microphoneBusy: @escaping @MainActor () -> Bool) {
        guard !isBusy else { return }
        guard !microphoneBusy() else {
            message = "Stop dictation, meetings and the held microphone before recording your voice profile."
            return
        }
        generation += 1
        let token = generation
        isBusy = true; message = nil; progress = 0; stage = "Downloading and preparing voice model…"
        operation = Task { [weak self] in
            guard let self else { return }
            var ownsAudioSession = false
            do {
                try await VoiceIdentityService.shared.prepareModels()
                try Task.checkCancellation()
                guard token == generation else { return }
                guard !microphoneBusy() else { throw EnrollmentError.microphoneBusy }
                stage = "Requesting microphone access…"
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
                #endif
                let mic = MicSource()
                microphone = mic
                let stream = try await mic.start(format: .init(sampleRate: 16000, channelCount: 1))
                try Task.checkCancellation()
                stage = "Speak naturally for ten seconds…"; isRecording = true
                var samples: [Float] = []
                samples.reserveCapacity(160000)
                // Also terminate if capture stalls after an interruption or device disconnect.
                let timeout = Task { try? await Task.sleep(for: .seconds(15)); await mic.stop() }
                defer { timeout.cancel() }
                for await chunk in stream {
                    try Task.checkCancellation()
                    guard !microphoneBusy() else { throw EnrollmentError.microphoneBusy }
                    samples.append(contentsOf: chunk.samples.prefix(160000 - samples.count))
                    progress = Double(samples.count) / 160000
                    if samples.count == 160000 { break }
                }
                await mic.stop(); microphone = nil; isRecording = false
                #if os(iOS)
                try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
                ownsAudioSession = false
                #endif
                try Task.checkCancellation()
                guard samples.count == 160000 else { throw EnrollmentError.interrupted }
                stage = "Saving your voice profile…"
                try await VoiceIdentityService.shared.enroll(samples: samples)
                guard token == generation else { return }
                hasProfile = VoiceIsolationSettings.hasProfile
                message = "Voice profile saved. You can now enable Only my voice."
            } catch is CancellationError {
                if token == generation { message = "Recording cancelled." }
            } catch {
                if token == generation { message = error.localizedDescription }
            }
            await microphone?.stop(); microphone = nil
            #if os(iOS)
            // Release only the audio session owned by this enrollment operation.
            if ownsAudioSession { try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation) }
            #endif
            if token == generation { isBusy = false; isRecording = false; stage = ""; operation = nil }
        }
    }

    public func cancel() {
        operation?.cancel()
        let mic = microphone
        Task { await mic?.stop() }
    }

    public func deleteProfile() {
        guard !isBusy else { return }
        isBusy = true; message = nil; stage = "Deleting voice profile…"
        operation = Task {
            do {
                try await VoiceIdentityService.shared.deleteProfile()
                VoiceIsolationSettings.enabled = false
                hasProfile = false; message = "Voice profile deleted. Only my voice is off."
            } catch { message = error.localizedDescription }
            isBusy = false; stage = ""; operation = nil
        }
    }

    private enum EnrollmentError: LocalizedError {
        case permission, microphoneBusy, interrupted
        var errorDescription: String? {
            switch self {
            case .permission: "Allow microphone access in system Settings, then try recording again."
            case .microphoneBusy: "Stop dictation, meetings and the held microphone before recording your voice profile."
            case .interrupted: "The recording was interrupted. Keep Legato open and try again."
            }
        }
    }
}
