import AppKit
import SwiftUI
import LegatoClaude
import LegatoAgent

struct SettingsView: View {
    private enum Page: String, CaseIterable, Identifiable {
        case overview = "Overview", writing = "Writing", keys = "API Keys", shortcut = "Shortcut"
        var id: Self { self }
        var symbol: String {
            switch self {
            case .overview: "sparkles"
            case .writing: "text.alignleft"
            case .keys: "key.horizontal"
            case .shortcut: "command"
            }
        }
        var subtitle: String {
            switch self {
            case .overview: "Your voice, ready to write."
            case .writing: "Make every composition sound like you."
            case .keys: "Connect the services that power your composer."
            case .shortcut: "Bring up the composer from anywhere on your Mac."
            }
        }
    }
    @Environment(MacAppController.self) private var controller
    @AppStorage("composer.liveModel") private var liveModel = ModelChoice.haiku.rawValue
    @AppStorage("composer.personalPrompt") private var personalPrompt = ""
    @State private var page: Page? = .overview
    @State private var claudeKey = ""
    @State private var sonioxKey = ""
    @State private var claudeSaved = false
    @State private var sonioxSaved = false
    @State private var keyNotice = ""
    @State private var keyError = false
    private var currentPage: Page { page ?? .overview }
    private var inputMonitoringGranted: Bool { CGPreflightListenEventAccess() }

    var body: some View {
        NavigationSplitView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 10) {
                    Image(systemName: "waveform").font(.title2.weight(.semibold)).foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Legato").font(.headline)
                        Text("Voice composer").font(.caption).foregroundStyle(.secondary)
                    }
                }.padding(.horizontal, 16).padding(.top, 24)
                List(Page.allCases, selection: $page) { item in
                    Label(item.rawValue, systemImage: item.symbol).padding(.vertical, 5).tag(item)
                }.listStyle(.sidebar)
                Text("Made for your flow.").font(.caption).foregroundStyle(.secondary)
                    .padding(.horizontal, 16).padding(.bottom, 20)
            }.navigationSplitViewColumnWidth(min: 170, ideal: 185, max: 220)
        } detail: {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 7) {
                        Text(currentPage.rawValue).font(.largeTitle.weight(.bold))
                        Text(currentPage.subtitle).foregroundStyle(.secondary)
                    }
                    switch currentPage {
                    case .overview: overview
                    case .writing: writing
                    case .keys: keys
                    case .shortcut: shortcut
                    }
                }.frame(maxWidth: 640, alignment: .leading).padding(32).frame(maxWidth: .infinity)
            }.background(Color(nsColor: .windowBackgroundColor))
        }
        .tint(.purple)
        .frame(minWidth: 740, maxWidth: .infinity, minHeight: 560, maxHeight: .infinity)
        .task { refreshKeys(); controller.permissions.refresh() }
        .onChange(of: page) { _, _ in controller.cancelRecording(); controller.permissions.refresh() }
        .onDisappear { controller.cancelRecording() }
    }

    private var overview: some View {
        VStack(alignment: .leading, spacing: 20) {
            card {
                HStack(alignment: .top, spacing: 14) {
                    Image(systemName: "waveform.circle.fill").font(.system(size: 38)).foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 7) {
                        Text("Speak. Shape. Send.").font(.title2.weight(.semibold))
                        Text("Open the composer with your shortcut, speak your draft, then insert it where you’re writing.")
                            .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            card {
                VStack(alignment: .leading, spacing: 16) {
                    Text("SETUP").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    readiness("Writing & transcription", detail: "Claude writes your text. Soniox transcribes your voice.", ready: claudeSaved && sonioxSaved, action: "Manage keys") { page = .keys }
                    Divider()
                    readiness("Global shortcut", detail: controller.settings.hotkey?.displayName ?? "Choose how to open Legato.", ready: controller.settings.hotkey != nil, action: "Edit shortcut") { page = .shortcut }
                }
            }
            permissions
        }
    }
    private var writing: some View {
        VStack(alignment: .leading, spacing: 20) {
            card {
                VStack(alignment: .leading, spacing: 14) {
                    Label("Writing model", systemImage: "sparkles").font(.headline)
                    Picker("Writing model", selection: $liveModel) {
                        ForEach(ModelChoice.allCases, id: \.rawValue) { model in
                            Text(modelName(model)).tag(model.rawValue)
                        }
                    }.labelsHidden().frame(maxWidth: .infinity, alignment: .leading)
                    Text("One writing agent handles quick corrections, restructuring after a pause, and final cleanup.")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            card {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Personal instructions").font(.headline)
                    Text("Add your preferred tone, spelling, or formatting. These instructions apply across writing modes.")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    ZStack(alignment: .topLeading) {
                        if personalPrompt.isEmpty {
                            Text("For example: Use British spelling and keep sentences concise.")
                                .foregroundStyle(.tertiary).padding(.horizontal, 8).padding(.vertical, 8).allowsHitTesting(false)
                        }
                        TextEditor(text: $personalPrompt).font(.body).scrollContentBackground(.hidden)
                            .padding(4).accessibilityLabel("Personal instructions")
                    }.frame(minHeight: 190).background(.background, in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))
                    Label("Changes save automatically and apply to your next composition.", systemImage: "checkmark.circle")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
    private var keys: some View {
        VStack(alignment: .leading, spacing: 20) {
            card {
                VStack(alignment: .leading, spacing: 20) {
                    provider("Claude", detail: "Writing and corrections", saved: claudeSaved, key: $claudeKey)
                    Divider()
                    provider("Soniox", detail: "Voice transcription", saved: sonioxSaved, key: $sonioxKey)
                }
            }
            HStack {
                Label("Stored securely in this Mac’s Keychain.", systemImage: "lock.shield").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Save keys", action: saveKeys).buttonStyle(.borderedProminent)
            }
            Text("Enter only the keys you want to add or replace. Blank fields keep saved keys. Saved keys are never displayed here.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if !keyNotice.isEmpty {
                Label(keyNotice, systemImage: keyError ? "exclamationmark.triangle" : "checkmark.circle")
                    .font(.callout).foregroundStyle(keyError ? Color.orange : Color.secondary)
                    .accessibilityLabel(keyNotice)
            }
            Text("Saved means a key is present in Keychain; it does not verify the provider account.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
    private var shortcut: some View {
        VStack(alignment: .leading, spacing: 20) {
            card {
                VStack(alignment: .leading, spacing: 16) {
                    Label("Composer shortcut", systemImage: "command").font(.headline)
                    HotkeyRecorderView()
                    Text("Record a single modifier, such as Right ⌘, or a key combination. Press Escape or Cancel to keep your current shortcut.")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            permissions
        }
    }
    private var permissions: some View {
        card {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("Mac permissions").font(.headline)
                    Spacer()
                    Button { controller.permissions.refresh() } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.plain).help("Refresh permission status").accessibilityLabel("Refresh permission status")
                }
                readiness("Microphone", detail: "Capture your voice while composing.", ready: controller.permissions.micGranted, action: "Allow microphone") { Task { await controller.permissions.requestMicrophone() } }
                Divider()
                readiness("Accessibility", detail: "Insert your composition into other apps.", ready: controller.permissions.accessibility, action: "Open Settings") { controller.permissions.requestAccessibility() }
                Divider()
                readiness("Input Monitoring", detail: "Listen for your shortcut outside Legato.", ready: inputMonitoringGranted, action: "Open Settings") { controller.permissions.requestInputMonitoring() }
            }
        }
    }
    private func readiness(_ title: String, detail: String, ready: Bool, action: String, perform: @escaping () -> Void) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: ready ? "checkmark.circle.fill" : "circle.dashed")
                .foregroundStyle(ready ? Color.green : Color.secondary).accessibilityLabel(ready ? "Ready" : "Needs setup")
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.body.weight(.medium))
                Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if title == "Microphone" || title == "Accessibility" || title == "Input Monitoring" {
                if ready { Text("Allowed").font(.caption).foregroundStyle(.secondary) }
                else { Button(action, action: perform).controlSize(.small) }
            } else { Button(action, action: perform).controlSize(.small) }
        }
    }
    private func provider(_ name: String, detail: String, saved: Bool, key: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(name).font(.headline)
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Label(saved ? "Saved" : "Not added", systemImage: saved ? "checkmark.circle.fill" : "circle.dashed")
                    .font(.caption).foregroundStyle(saved ? Color.green : Color.secondary)
            }
            SecureField(saved ? "Enter replacement key" : "Enter API key", text: key)
                .textFieldStyle(.roundedBorder).accessibilityLabel("\(name) API key")
        }
    }
    private func card<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content().frame(maxWidth: .infinity, alignment: .leading).padding(20)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(.quaternary))
    }
    private func modelName(_ model: ModelChoice) -> String {
        switch model { case .haiku: "Claude Haiku 5.5"; case .sonnet: "Claude Sonnet 5.5"; case .opus: "Claude Opus 5.5" }
    }
    private func refreshKeys() {
        do {
            claudeSaved = try KeychainKeyStore().apiKey()?.isEmpty == false
            sonioxSaved = try KeychainKeyStore(service: "de.gruenwald.legato.soniox").apiKey()?.isEmpty == false
        } catch { keyError = true; keyNotice = "Could not read Keychain. Try again after unlocking your Mac." }
    }
    private func saveKeys() {
        do {
            let claude = claudeKey.trimmingCharacters(in: .whitespacesAndNewlines)
            let soniox = sonioxKey.trimmingCharacters(in: .whitespacesAndNewlines)
            if !claude.isEmpty { try KeychainKeyStore().save(apiKey: claude) }
            if !soniox.isEmpty { try KeychainKeyStore(service: "de.gruenwald.legato.soniox").save(apiKey: soniox) }
            claudeKey = ""; sonioxKey = ""; keyError = false
            keyNotice = claude.isEmpty && soniox.isEmpty ? "Saved keys kept unchanged." : "Keys saved on this Mac."
            refreshKeys()
        } catch { keyError = true; keyNotice = "Could not save keys. Your entries are kept here so you can try again." }
    }
}
