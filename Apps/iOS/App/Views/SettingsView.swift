import LegatoAudio
import LegatoCore
import SwiftUI

struct SettingsView: View {
    let controller: AppController
    @State private var policy = Settings.audioPolicy
    @State private var showPauseOthers = Settings.debugShowPauseOthers
    #if LEGATO_INTERNAL
    @State private var restartAfterBackgroundStop = Settings.restartAfterBackgroundStop
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
                Text("How dictation treats music and other audio that is playing.")
            }

            #if LEGATO_INTERNAL
            Section {
                Toggle("Restart after background stop", isOn: $restartAfterBackgroundStop)
                Toggle("Keep audio session active", isOn: $keepSessionActive)
                Toggle("Offer pause others", isOn: $showPauseOthers)
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
        .onChange(of: showPauseOthers) { _, new in
            Settings.debugShowPauseOthers = new
            policy = Settings.audioPolicy // falls back to the default if the stored policy is no longer offered
        }
        #if LEGATO_INTERNAL
        .onChange(of: restartAfterBackgroundStop) { _, new in Settings.restartAfterBackgroundStop = new }
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
        }
    }
}
