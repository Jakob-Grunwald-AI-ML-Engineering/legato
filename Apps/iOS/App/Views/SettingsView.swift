import LegatoAudio
import LegatoCore
import SwiftUI

struct SettingsView: View {
    let controller: AppController
    @State private var policy = Settings.audioPolicy
    @State private var showPauseOthers = Settings.debugShowPauseOthers
    #if LEGATO_INTERNAL
    @State private var restartAfterBackgroundStop = Settings.restartAfterBackgroundStop
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
            Section("Debug") {
                Toggle("Restart after background stop", isOn: $restartAfterBackgroundStop)
                Toggle("Offer pause others", isOn: $showPauseOthers)
                Toggle("Force tap-to-copy", isOn: $forceTapToCopy)
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
