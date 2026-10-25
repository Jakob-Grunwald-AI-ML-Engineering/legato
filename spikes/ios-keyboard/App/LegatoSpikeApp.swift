import AppIntents
import Combine
import AVFAudio
import SwiftUI

struct SpikeShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: ToggleDictationIntent(),
                    phrases: ["Toggle \(.applicationName) dictation"],
                    shortTitle: "Toggle dictation", systemImageName: "mic.fill")
    }
}

@main
struct LegatoSpikeApp: App {
    init() {
        // Registers the Darwin observer as early as possible, including on background launches.
        _ = SessionController.shared
        SpikeShortcuts.updateAppShortcutParameters()
    }

    var body: some Scene {
        WindowGroup { ContentView() }
    }
}

struct ContentView: View {
    @Bindable private var session = SessionController.shared

    var body: some View {
        if session.scratchVisible {
            ScratchView(session: session)
        } else {
            DebugView(session: session)
        }
    }
}

/// Opened by ToggleDictationIntent when no Legato keyboard is visible: dictated text streams here.
struct ScratchView: View {
    @Bindable var session: SessionController
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text("Scratch").font(.title2.bold())
                Spacer()
                Text(session.isActive ? "dictating (\(session.dictation.state))" : "stopped")
                    .font(.footnote.monospaced())
                Button("Close") { session.scratchVisible = false }
            }
            TextEditor(text: $session.scratchText)
                .focused($focused)
                .padding(6)
                .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 8))
            if let e = session.lastError { Text(e).foregroundStyle(.red).font(.footnote) }
            HStack {
                Button("Copy") { UIPasteboard.general.string = session.scratchText }
                ShareLink(item: session.scratchText)
                Button("Clear") { session.scratchText = "" }
                Spacer()
                Button(session.isActive ? "Stop" : "Dictate") {
                    Task { _ = try? await session.toggle(source: "scratch-ui") }
                }.buttonStyle(.borderedProminent)
            }
            .buttonStyle(.bordered)
        }
        .padding()
        .onAppear {
            SpikeLog.write("app", "Scratch screen appeared; appState=\(UIApplication.shared.applicationState.rawValue)")
            Task {
                try? await Task.sleep(for: .milliseconds(400))
                focused = true
            }
        }
    }
}

struct DebugView: View {
    let session: SessionController
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
                    Button("Toggle dictation (in-app)") {
                        Task { do { _ = try await session.toggle(source: "ui") } catch { status = describe(error) } }
                    }
                    Button("Scratch") { session.scratchVisible = true }
                }.buttonStyle(.borderedProminent)
                HStack {
                    Button("Mic permission") {
                        Task { let ok = await AVAudioApplication.requestRecordPermission(); status = "mic permission: \(ok)" }
                    }
                    Button("Prepare speech model") { Task { status = await session.dictation.prepareModel() } }
                }.buttonStyle(.bordered)
                Picker("Other audio", selection: Binding(
                    get: { Spike.defaults.string(forKey: "audio.mode") ?? "mix" },
                    set: { Spike.defaults.set($0, forKey: "audio.mode") })) {
                    ForEach(SessionController.audioModes, id: \.id) { Text($0.label).tag($0.id) }
                }.pickerStyle(.segmented)
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
