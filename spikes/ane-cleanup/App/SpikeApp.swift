import AppIntents
import SwiftUI

struct SpikeShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: SpikeToggleIntent(), phrases: ["Toggle \(.applicationName) dictation"],
                    shortTitle: "Toggle spike dictation", systemImageName: "mic")
        AppShortcut(intent: SpikeFixtureIntent(), phrases: ["Run \(.applicationName) fixture"],
                    shortTitle: "Run spike fixture", systemImageName: "checkmark.circle")
    }
}
@main struct SpikeApp: App {
    @State private var host = SpikeHost.shared
    init() { SpikeShortcuts.updateAppShortcutParameters() }
    var body: some Scene {
        WindowGroup { SpikeView(host: host).onOpenURL { url in Task { await host.handle(url) } } }
    }
}
struct SpikeView: View {
    @Bindable var host: SpikeHost
    var body: some View {
        VStack(spacing: 24) {
            Text("ANE cleanup #39").font(.title2.bold())
            Text(host.status).multilineTextAlignment(.center).accessibilityIdentifier("spike.status")
            if host.busy { ProgressView().accessibilityLabel("Test in progress") }
            if !host.setupComplete {
                Button("Allow microphone and speech access") { Task { await host.setup() } }
                    .disabled(host.busy)
            }
            if host.recording {
                Button("Stop recording") { Task { await host.toggle(trigger: "foregroundStopButton") } }
                    .disabled(host.busy)
            }
            if host.busy {
                Button("Cancel run", role: .destructive) { host.cancel() }
            }
            Text("Tests are controlled from the computer. Keep this app open for foreground checks; background tests follow when requested.")
                .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .padding(28)
        .task { await host.runLaunchArguments() }
    }
}
