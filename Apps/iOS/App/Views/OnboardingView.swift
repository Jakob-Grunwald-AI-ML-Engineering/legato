import AVFAudio
import Speech
import SwiftUI
import UIKit

/// First-run setup: microphone, speech recognition, the on-device model, and Live Activities.
struct OnboardingView: View {
    let controller: AppController

    @State private var speechStatus = SFSpeechRecognizer.authorizationStatus()
    @State private var installProgress: Double?
    @State private var installFailed = false

    var body: some View {
        Form {
            Section {
                Text("Legato turns speech into text on this device. A few things need setting up first.")
            }

            Section("Microphone") {
                if controller.status.micGranted {
                    Label("Allowed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                } else if controller.status.micDenied {
                    Text("Microphone access is off. Turn it on in Settings.")
                    Button("Open Settings", action: openSettings)
                } else {
                    Button("Allow microphone") {
                        Task {
                            _ = await AVAudioApplication.requestRecordPermission()
                            await controller.refreshReadiness()
                        }
                    }
                }
            }

            Section("Speech recognition") {
                if speechStatus == .authorized {
                    Label("Allowed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                } else if speechStatus == .notDetermined {
                    Button("Allow speech recognition") {
                        Task { speechStatus = await Self.requestSpeechAuthorization() }
                    }
                } else {
                    Text("Speech recognition is off. Turn it on in Settings.")
                    Button("Open Settings", action: openSettings)
                }
            }

            Section("Speech model") {
                if controller.status.assetsInstalled {
                    Label("Installed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                } else if let installProgress {
                    ProgressView(value: installProgress) { Text("Downloading…") }
                } else {
                    Button("Download speech model") { Task { await install() } }
                    if installFailed { Text("The download didn't finish. Try again.").foregroundStyle(.red) }
                }
            }

            Section("Live Activities") {
                if controller.status.activitiesEnabled {
                    Label("On", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                } else {
                    Text("Legato shows the live text in a Live Activity. Turn on Live Activities for Legato in Settings.")
                    Button("Open Settings", action: openSettings)
                }
            }
        }
        .task { await controller.refreshReadiness() }
    }

    private func install() async {
        installFailed = false
        installProgress = 0
        for await fraction in controller.engine.installAssets(locale: nil) {
            installProgress = fraction
        }
        installProgress = nil
        await controller.refreshReadiness()
        installFailed = !controller.status.assetsInstalled
    }

    private func openSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
    }

    private static func requestSpeechAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
    }
}
