import LegatoAudio
import LegatoCore
import SwiftUI
import UIKit

struct SettingsView: View {
    let controller: AppController
    @State private var policy = Settings.audioPolicy
    @State private var keepAlive = Settings.keepAlive
    @State private var haptics = Settings.keyboardHaptics
    @State private var clicks = Settings.keyboardClicks
    @State private var showPauseOthers = Settings.debugShowPauseOthers
    #if LEGATO_INTERNAL
    @State private var keepSessionActive = Settings.keepSessionActiveBetweenRuns
    @State private var forceTapToCopy = Settings.debugForceTapToCopy
    #endif

    /// What the picker offers: the package's offered policies (plus the debug one) the platform supports.
    private var policies: [AudioPolicy] {
        let supported = AudioSessionController().supportedPolicies
        return Settings.offeredPolicies.filter(supported.contains)
    }

    var body: some View {
        Form {
            Section {
                Picker("Other audio", selection: $policy) {
                    ForEach(policies, id: \.self) { Text(Self.title(for: $0)).tag($0) }
                }
            } header: {
                Text("Audio")
            } footer: {
                Text("How dictation treats music and other audio that is playing. iOS only lets an app record next to playing audio from the foreground, so with audio playing, Legato opens first when you start from the Action Button or Control Center.")
            }

            Section {
                Picker("Keep microphone ready", selection: $keepAlive) {
                    ForEach(KeepAlive.allCases) { Text($0.title).tag($0) }
                }
            } header: {
                Text("Keyboard")
            } footer: {
                Text("After a dictation with the Legato keyboard, the microphone stays ready for this long, so the next tap on the keyboard's mic key starts at once without opening Legato. While it is ready, the orange microphone indicator stays on. Off by default.")
            }

            Section {
                Toggle("Haptic feedback", isOn: $haptics)
                Toggle("Key clicks", isOn: $clicks)
                Button("Keyboard settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                }
            } header: {
                Text("Typing")
            } footer: {
                Text("Haptics and clicks need Allow Full Access for the Legato keyboard (Settings > Legato > Keyboards). Clicks also follow the system's Keyboard Clicks switch in Settings > Sounds & Haptics.")
            }

            #if LEGATO_INTERNAL
            Section {
                Toggle("Keep audio session active", isOn: $keepSessionActive)
                Toggle("Offer experimental audio options", isOn: $showPauseOthers)
                Toggle("Force tap-to-copy", isOn: $forceTapToCopy)
            } header: {
                Text("Debug")
            } footer: {
                Text("Keep audio session active: a stop leaves the session on, so music stays lowered (or paused) between dictations until an interruption or this switch ends it. Diagnostics: Library/Caches/audio-diag.jsonl in the app container.")
            }
            #endif
        }
        .navigationTitle("Settings")
        .onChange(of: policy) { _, new in Settings.audioPolicy = new }
        .onChange(of: keepAlive) { _, new in
            Settings.keepAlive = new
            if new == .off { Task { await controller.endKeepAlive() } }
        }
        .onChange(of: haptics) { _, new in Settings.keyboardHaptics = new }
        .onChange(of: clicks) { _, new in Settings.keyboardClicks = new }
        .onChange(of: showPauseOthers) { _, new in
            Settings.debugShowPauseOthers = new
            policy = Settings.audioPolicy // falls back to the default if the stored policy is no longer offered
        }
        #if LEGATO_INTERNAL
        .onChange(of: forceTapToCopy) { _, new in Settings.debugForceTapToCopy = new }
        .onChange(of: keepSessionActive) { _, new in
            Settings.keepSessionActiveBetweenRuns = new
            if !new { controller.releaseHeldSession() }
        }
        #endif
    }

    private static func title(for policy: AudioPolicy) -> String {
        switch policy {
        case .duckOthers: "Lower other audio"
        case .mixWithOthers: "Play alongside"
        case .pauseOthers: "Pause other audio"
        case .duckMusicPauseSpoken: "Lower music, pause podcasts"
        }
    }
}
