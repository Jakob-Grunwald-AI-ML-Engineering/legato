import LegatoAudio
import LegatoCore
import SwiftUI

struct SettingsView: View {
    let controller: AppController
    @State private var policy = Settings.audioPolicy
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
                Text("How dictation treats music and other audio that is playing.")
            }

            Section {
                ForEach(Self.musicSteps.indices, id: \.self) { index in
                    Label {
                        Text(Self.musicSteps[index])
                    } icon: {
                        Image(systemName: "\(index + 1).circle.fill").foregroundStyle(.tint)
                    }
                }
            } header: {
                Text("Use with music")
            } footer: {
                Text("iOS only lets an app start the microphone from the background while no other audio plays, and apps can't pause music from there. A Shortcut can. Build this one, then choose it for the Action Button in Settings.")
            }

            #if LEGATO_INTERNAL
            Section {
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
        .onChange(of: forceTapToCopy) { _, new in Settings.debugForceTapToCopy = new }
        .onChange(of: keepSessionActive) { _, new in
            Settings.keepSessionActiveBetweenRuns = new
            if !new { controller.releaseHeldSession() }
        }
        #endif
    }

    /// The Shortcut recipe, in order. Pressing the Action Button again stops: the Shortcut pauses
    /// nothing (already quiet), stops dictation, and resumes the music.
    private static let musicSteps = [
        "Pause: the Play/Pause action, set to Pause.",
        "Toggle Legato dictation.",
        "If the result is Stopped (the If action, choose Dictation State).",
        "Play: the Play/Pause action, set to Play. Then End If.",
    ]

    private static func title(for policy: AudioPolicy) -> String {
        switch policy {
        case .duckOthers: "Lower other audio"
        case .mixWithOthers: "Play alongside"
        case .pauseOthers: "Pause other audio"
        }
    }
}
