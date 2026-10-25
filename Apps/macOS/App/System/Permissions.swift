import AppKit
import ApplicationServices
import AVFAudio
import Foundation
import LegatoAppleSpeech
import Observation
import Speech

/// What dictation needs from the system, as live state for the menu and onboarding.
@MainActor @Observable
final class Permissions {
    enum MicState: Equatable { case undetermined, granted, denied }
    enum ModelState: Equatable {
        case unknown
        case missing
        case downloading(Double)
        case installed
        case failed(String)
    }

    private(set) var mic = Permissions.currentMic()
    private(set) var accessibility = AXIsProcessTrusted()
    private(set) var model = ModelState.unknown
    /// The listen-only event tap exists. Set by the controller; Accessibility is usually enough
    /// for it, and when it is not, macOS wants Input Monitoring.
    var hotkeyTapActive = false

    var micGranted: Bool { mic == .granted }
    var modelInstalled: Bool { model == .installed }
    /// Accessibility is granted but the tap still cannot be created: Input Monitoring is missing.
    var needsInputMonitoring: Bool { accessibility && !hotkeyTapActive }

    @ObservationIgnored private let engine: AppleSpeechEngine
    @ObservationIgnored private var download: Task<Void, Never>?

    init(engine: AppleSpeechEngine) {
        self.engine = engine
    }

    // MARK: Refresh

    /// Cheap synchronous checks; called by the controller's poll.
    func refresh() {
        let newMic = Self.currentMic()
        if newMic != mic { mic = newMic }
        let trusted = AXIsProcessTrusted()
        if trusted != accessibility { accessibility = trusted }
    }

    func refreshModel() async {
        if case .downloading = model { return }
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: .current) else {
            model = .failed("Speech recognition does not support \(Locale.current.identifier) on this Mac.")
            return
        }
        let transcriber = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
        model = await AssetInventory.status(forModules: [transcriber]) == .installed ? .installed : .missing
    }

    // MARK: Actions

    func requestMicrophone() async {
        switch mic {
        case .undetermined:
            _ = await AVAudioApplication.requestRecordPermission()
            refresh()
        case .denied:
            Self.openSettings("Privacy_Microphone")
        case .granted:
            break
        }
    }

    /// Shows the system prompt and opens the pane; the controller's poll notices the grant.
    func requestAccessibility() {
        // The literal key: the imported `kAXTrustedCheckOptionPrompt` global is not concurrency-safe.
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        Self.openSettings("Privacy_Accessibility")
    }

    func requestInputMonitoring() {
        _ = CGRequestListenEventAccess()
        Self.openSettings("Privacy_ListenEvent")
    }

    func installModel() {
        guard download == nil else { return }
        model = .downloading(0)
        download = Task { [engine] in
            for await fraction in engine.installAssets(locale: nil) {
                model = .downloading(fraction)
            }
            download = nil
            model = .unknown
            await refreshModel()
            if model != .installed { model = .failed("The download did not finish. Check your connection and try again.") }
        }
    }

    // MARK: Helpers

    private static func currentMic() -> MicState {
        switch AVAudioApplication.shared.recordPermission {
        case .granted: .granted
        case .denied: .denied
        default: .undetermined
        }
    }

    private static func openSettings(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }
}
