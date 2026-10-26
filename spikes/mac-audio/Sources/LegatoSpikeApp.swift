import SwiftUI

@main
struct LegatoSpikeApp: App {
    @State private var session = Session()
    @State private var monitor = ProcessMonitor()

    var body: some Scene {
        WindowGroup {
            ContentView(session: session, monitor: monitor)
                .frame(minWidth: 820, minHeight: 460)
                .task {
                    monitor.start()
                    // Headless check mode: `LegatoSpike --selftest --out=/abs/path/selftest.json [--seconds=15] [--lang=auto]`
                    let args = CommandLine.arguments
                    guard args.contains("--selftest") else { return }
                    func value(_ key: String) -> String? {
                        args.first { $0.hasPrefix("--\(key)=") }.map { String($0.dropFirst(key.count + 3)) }
                    }
                    let out = URL(fileURLWithPath: value("out") ?? FileManager.default.currentDirectoryPath + "/selftest.json")
                    session.language = value("lang") ?? "auto"
                    await session.runSelfTest(seconds: Double(value("seconds") ?? "15") ?? 15, outURL: out)
                }
        }
    }
}

struct ContentView: View {
    @Bindable var session: Session
    let monitor: ProcessMonitor

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Button(session.running ? "Stop" : "Start") {
                    Task { session.running ? await session.stop() : await session.start() }
                }
                .keyboardShortcut(.return)
                Picker("Language", selection: $session.language) {
                    Text("auto").tag("auto")
                    Text("Deutsch").tag("de-DE")
                    Text("English").tag("en-US")
                }
                .frame(width: 200)
                .disabled(session.running)
                Toggle("Voice processing", isOn: $session.voiceProcessing).disabled(session.running)
                Text(session.status).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                Spacer()
            }
            HStack(alignment: .top, spacing: 12) {
                Column(title: "Me (mic)", finals: session.meFinals, partial: session.mePartial)
                Column(title: "Them (system audio)", finals: session.themFinals, partial: session.themPartial)
            }
            if !session.micFormat.isEmpty { Text("Mic input: \(session.micFormat)").font(.caption.monospaced()).frame(maxWidth: .infinity, alignment: .leading) }
            ProcessPanel(monitor: monitor)
        }
        .padding(16)
    }
}

struct Column: View {
    let title: String
    let finals: [String]
    let partial: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(finals.enumerated()), id: \.offset) { _, line in
                        Text(line).textSelection(.enabled)
                    }
                    if !partial.isEmpty {
                        Text(partial).foregroundStyle(.secondary).italic()
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(8)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
        }
    }
}

struct ProcessPanel: View {
    let monitor: ProcessMonitor

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Process monitor (\(monitor.totalProcesses) audio processes; log: \(ProcessMonitor.logPath))")
                .font(.caption.bold()).textSelection(.enabled)
            if !monitor.lastError.isEmpty { Text(monitor.lastError).font(.caption).foregroundStyle(.red) }
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(monitor.active) { p in
                        Text("\(p.bundleID)  pid \(p.pid)  in:\(p.input ? "YES" : "-")  out:\(p.output ? "YES" : "-")")
                            .font(.caption.monospaced())
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 90)
        }
    }
}
