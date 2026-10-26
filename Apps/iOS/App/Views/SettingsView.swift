import LegatoAudio
import LegatoCore
import LegatoKeyboardCore
import SwiftUI
import UIKit

struct SettingsView: View {
    let controller: AppController
    @State private var policy = Settings.audioPolicy
    @State private var keepAlive = Settings.keepAlive
    @State private var haptics = Settings.keyboardHaptics
    @State private var clicks = Settings.keyboardClicks
    @State private var strip = Settings.keyboardStrip
    #if DEBUG
    @State private var stripHeight = Settings.keyboardStripHeight
    #endif
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
                Text("How dictation treats music and other audio that is playing. It applies when the microphone starts fresh, not while it is kept ready (see Microphone); changing it releases a kept-ready microphone. iOS only lets an app record next to playing audio from the foreground, so with audio playing, Legato opens first when you start from the Action Button or Control Center.")
            }

            Section {
                Picker("Keep microphone ready", selection: $keepAlive) {
                    ForEach(KeepAliveChoice.allCases, id: \.self) { Text($0.title).tag($0) }
                }
            } header: {
                Text("Microphone")
            } footer: {
                Text("After a dictation, the microphone stays ready for this long, so the next one from the Action Button, Control Center or the Legato keyboard starts at once, even with music playing, and without opening Legato. While it is ready, the orange microphone indicator stays on and other audio plays alongside: it is not lowered or paused. With Off, each dictation lowers or pauses audio as set under Audio, and with music playing, a start from the background opens Legato first. Indefinitely keeps it until a call or another app takes the microphone, or you turn this off. Off by default. With Off, the keyboard's microphone key still opens Legato once to ready the microphone for 60 seconds, so your next tap dictates; then it is released.")
            }

            Section {
                Toggle("Haptic feedback", isOn: $haptics)
                Toggle("Key clicks", isOn: $clicks)
                Toggle("Compact keyboard (strip)", isOn: $strip)
                #if DEBUG
                Picker("Strip height", selection: $stripHeight) {
                    ForEach(StripHeight.candidates, id: \.self) { Text("\(Int($0)) pt").tag($0) }
                }
                #endif
                Button("Keyboard settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                }
            } header: {
                Text("Typing")
            } footer: {
                Text("Haptics and clicks need Allow Full Access for the Legato keyboard (Settings > Legato > Keyboards). Clicks also follow the system's Keyboard Clicks switch in Settings > Sounds & Haptics. The compact keyboard is one row with the dictation status and the mic key; its chevron opens the full keyboard.")
            }

            #if LEGATO_INTERNAL
            Section {
                Toggle("Keep audio session active", isOn: $keepSessionActive)
                Toggle("Offer experimental audio options", isOn: $showPauseOthers)
                Toggle("Force tap-to-copy", isOn: $forceTapToCopy)
            } header: {
                Text("Debug")
            } footer: {
                Text("Keep audio session active: a stop leaves the session on, so the session, and any lowering or pausing of music from its last start, stays in place between dictations, and the Audio setting does not apply until an interruption or this switch ends it. Diagnostics: Library/Caches/audio-diag.jsonl in the app container.")
            }
            #endif
        }
        .navigationTitle("Settings")
        .onChange(of: policy) { _, new in
            guard new != Settings.audioPolicy else { return }
            Settings.audioPolicy = new
            Task { await controller.audioPolicySettingChanged() }
        }
        .onChange(of: keepAlive) { _, new in
            Settings.keepAlive = new
            Task { await controller.keepAliveSettingChanged(new.linger) }
        }
        .onChange(of: haptics) { _, new in Settings.keyboardHaptics = new }
        .onChange(of: clicks) { _, new in Settings.keyboardClicks = new }
        .onChange(of: strip) { _, new in Settings.keyboardStrip = new }
        #if DEBUG
        .onChange(of: stripHeight) { _, new in Settings.keyboardStripHeight = new }
        #endif
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
