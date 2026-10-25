import AppIntents
import Combine
import AVFAudio
import SwiftUI

struct SpikeShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: StartSessionIntent(),
                    phrases: ["Start \(.applicationName) session"],
                    shortTitle: "Start session", systemImageName: "mic.fill")
        AppShortcut(intent: StopSessionIntent(),
                    phrases: ["Stop \(.applicationName) session"],
                    shortTitle: "Stop session", systemImageName: "mic.slash.fill")
    }
}

@main
struct LegatoSpikeApp: App {
    init() {
        // Registers the Darwin observers as early as possible, including on background launches.
        _ = SessionController.shared
        SpikeShortcuts.updateAppShortcutParameters()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .onOpenURL { url in
                    // Path (c), the hop baseline: the keyboard opened us via URL.
                    SpikeLog.write("app", "opened via URL \(url) (this is a visible hop)")
                    Task { try? await SessionController.shared.start(source: "url") }
                }
        }
    }
}

struct ContentView: View {
    private let session = SessionController.shared
    @State private var log = ""
    @State private var status = ""
    @State private var testText = ""
    @State private var hbAge: Double = -1
    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Legato keyboard spike").font(.title2.bold())
                Text("Session: \(session.isActive ? "ACTIVE" : "stopped")  level \(String(format: "%.2f", session.level))  heartbeat age \(hbAge < 0 ? "-" : String(format: "%.1fs", hbAge))")
                    .font(.footnote.monospaced())
                if let e = session.lastError { Text(e).foregroundStyle(.red).font(.footnote) }
                HStack {
                    Button("Start (foreground)") { Task { try? await session.start(source: "ui") } }
                    Button("Stop") { Task { await session.stop(reason: "ui") } }
                }.buttonStyle(.borderedProminent)
                HStack {
                    Button("Mic permission") {
                        Task { let ok = await AVAudioApplication.requestRecordPermission(); status = "mic permission: \(ok)" }
                    }
                    Button("Prepare speech model") { Task { status = await session.dictation.prepareModel() } }
                }.buttonStyle(.bordered)
                Text(status).font(.footnote)
                TextField("Tap here, switch to the Legato keyboard", text: $testText, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Button("Refresh log") { refresh() }
                    Button("Clear log") { SpikeLog.clear(); refresh() }
                }.buttonStyle(.bordered)
                Text(log).font(.system(size: 9, design: .monospaced)).textSelection(.enabled)
            }.padding()
        }
        .onAppear(perform: refresh)
        .onReceive(tick) { _ in
            let t = Spike.defaults.double(forKey: Spike.Key.heartbeat)
            hbAge = t > 0 ? Date().timeIntervalSince1970 - t : -1
        }
    }

    private func refresh() { log = SpikeLog.tail() }
}
