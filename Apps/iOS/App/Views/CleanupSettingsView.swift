import LegatoAppServices
import LegatoCore
import LegatoCoreML
import LegatoModels
import LegatoPostProcessing
import SwiftUI

/// Cleanup after dictation: on/off, how the cleaned text reaches the field, the style, the backend, ITN
/// and the time limit.
struct CleanupSettingsView: View {
    let controller: AppController

    @State private var enabled = Settings.cleanupEnabled
    @State private var delivery = Settings.cleanupDelivery
    @State private var style = Settings.cleanupStyle
    @State private var emoji = Settings.cleanupEmoji
    @State private var backend = Settings.cleanupBackend
    @State private var itn = Settings.cleanupITN
    @State private var timeout = Double(Settings.cleanupTimeoutSeconds)
    @State private var selectedModel: String?
    @State private var modelTerms: CleanupModelTerms?
    @State private var pending: String?
    @State private var failures: [String: String] = [:]

    private var models: ModelServices { controller.models }

    private var selectedModelName: String? {
        selectedModel.flatMap { id in models.cleanupModels.first { $0.id == id }?.displayName }
    }

    private var usesCoreML: Bool {
        backend == .coreML
    }

    var body: some View {
        Form {
            Section {
                Toggle("Clean up dictation", isOn: $enabled)
                    .accessibilityIdentifier("cleanup.enabled")
            } footer: {
                Text("A language model on this iPhone preserves your voice, writes natural messages or structures Markdown (after you stop, or continuously while you speak with Live). History keeps the raw text next to the cleaned one.")
            }

            Section {
                Picker("Delivery", selection: $delivery) {
                    Text("Live").tag(CleanupDelivery.live)
                    Text("Replace").tag(CleanupDelivery.replace)
                }
                .accessibilityIdentifier("cleanup.delivery")
            } header: {
                Text("In the Legato keyboard")
            } footer: {
                Text(Self.explain(delivery))
            }

            Section {
                Picker("Style", selection: $style) {
                    ForEach(CleanupStyle.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                if style == .message {
                    Picker("Emoji", selection: $emoji) {
                        ForEach(MessageEmojiStyle.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                }
            } footer: {
                Text(style.explanation + " Changes apply to the next run. Earlier text in long dictations may no longer be revised.")
            }

            #if ANE_CLEANUP_SPIKE
            Section("Backend") {
                LabeledContent("Cleanup", value: "ANEMLL Qwen3-1.7B")
                Text("CPU + Neural Engine requested. Weights stay loaded; microphone readiness follows Keep ready. Physical ANE placement remains unverified.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            #else
            Section {
                backendRow("Apple Foundation Models", detail: "Built in (Apple Intelligence)", choice: .foundationModels)
                ForEach(models.cleanupModels) { descriptor in
                    ModelRow(
                        descriptor: descriptor, manager: models.manager,
                        isSelected: backend == models.cleanupChoice(for: descriptor.id) && selectedModel == descriptor.id,
                        isPending: pending == descriptor.id, failure: failures[descriptor.id],
                        onCancel: { cancelDownload(descriptor.id) }
                    ) { pickModel(descriptor.id) }
                    .swipeActions {
                        Button("Delete", role: .destructive) { delete(descriptor.id) }
                    }
                    if descriptor.id == CoreMLModels.qwen3_0_6bID {
                        Text("Experimental: review numbers and times carefully; this model can change them incorrectly.")
                            .font(.caption).foregroundStyle(.secondary)
                    } else if descriptor.id == CoreMLModels.gemma3_1bID {
                        Text("Experimental: preparation can fail on some devices. If it fails, choose another model.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Cleanup model")
            } footer: {
                Text("Picking a downloaded model installs and prepares it first. While an installed model prepares, dictation can use Apple Foundation Models. The selected model is used for new dictations once ready.")
                if backend == .coreML, selectedModelName == nil { Text("Choose a Core ML model to install and prepare it.") }
                if usesCoreML, selectedModelName != nil {
                    Text(models.cleanupPreparation.description)
                        .foregroundStyle(models.cleanupPreparation.state == .failed ? .red : .secondary)
                    if models.cleanupPreparation.state == .failed {
                        Button("Retry preparation") {
                            Task { await models.retryCleanupPreparation(inBackground: false) }
                        }
                    }
                }
            }

            #endif

            Section {
                Toggle("Number normalization (ITN)", isOn: $itn)
                VStack(alignment: .leading) {
                    Text("Time limit: \(Int(timeout)) s")
                    Slider(value: $timeout, in: 1 ... 10, step: 1)
                }
            } header: {
                Text("Advanced")
            } footer: {
                Text("ITN applies only to Voice, turning spoken numbers into digits before the model (English only). Message and Markdown bypass it. Off by default: it merges \"ten thirty\" into \"40\". The time limit applies to each step; past it the raw text is kept.")
            }
        }
        .navigationTitle("Cleanup")
        .sheet(item: $modelTerms) { terms in
            CleanupTermsSheet(terms: terms) {
                modelTerms = nil
                downloadModel(terms.id)
            }
        }
        .onAppear { selectedModel = models.selected(.cleanup) }
        .onChange(of: enabled) { _, new in
            Settings.cleanupEnabled = new
            controller.cleanupSettingsChanged()
        }
        .onChange(of: delivery) { _, new in Settings.cleanupDelivery = new }
        .onChange(of: style) { _, new in Settings.cleanupStyle = new }
        .onChange(of: emoji) { _, new in Settings.cleanupEmoji = new }
        .onChange(of: backend) { _, new in
            Settings.cleanupBackend = new
            timeout = Double(Settings.cleanupTimeoutSeconds)
            controller.cleanupSettingsChanged()
        }
        .onChange(of: itn) { _, new in Settings.cleanupITN = new }
        .onChange(of: timeout) { _, new in
            // Reflecting a backend default must not turn it into an explicit user preference.
            if Settings.cleanupTimeoutSeconds != Int(new) { Settings.cleanupTimeoutSeconds = Int(new) }
        }
    }

    private func backendRow(_ title: String, detail: String, choice: CleanupBackendChoice) -> some View {
        Button {
            backend = choice
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).foregroundStyle(.primary)
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if backend == choice { Image(systemName: "checkmark").foregroundStyle(.tint) }
            }
        }
        .accessibilityIdentifier("cleanup.backend.\(choice.rawValue)")
    }

    private func pickModel(_ id: String) {
        do {
            if let terms = try CleanupModelTerms.forModel(id) { modelTerms = terms }
            else { downloadModel(id) }
        } catch { failures[id] = "Model terms could not be opened: \(error.localizedDescription)" }
    }

    private func downloadModel(_ id: String) {
        failures[id] = nil
        pending = id
        models.pick(id, role: .cleanup) { error in
            if pending == id { pending = nil }
            if let error {
                failures[id] = String(describing: error)
            } else {
                selectedModel = models.selected(.cleanup)
                backend = models.cleanupChoice(for: id)
                Settings.cleanupBackend = backend
                controller.cleanupSettingsChanged()
            }
        }
    }

    private func cancelDownload(_ id: String) {
        if pending == id { pending = nil }
        Task { await models.cancelDownload(id) }
    }

    private func delete(_ id: String) {
        if pending == id { pending = nil }
        Task {
            await models.manager.delete(id)
            selectedModel = models.selected(.cleanup)
            Settings.cleanupBackend = backend
            controller.cleanupSettingsChanged()
        }
    }

    static func explain(_ delivery: CleanupDelivery) -> String {
        switch delivery {
        case .replace:
            "Replace: the raw text streams in while you speak; when you stop, the whole text is cleaned once and only what changed is rewritten. Text you edited yourself stays; what could not be written goes to the clipboard."
        case .live:
            "Live: each sentence is cleaned as soon as you finish it, while you keep speaking; the rest is cleaned when you stop. Text you edit yourself is never changed again."
        }
    }
}

/// Terms stay available offline in the same flow that authorizes the download.
private struct CleanupTermsSheet: View {
    let terms: CleanupModelTerms
    let agree: () -> Void
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Gemma model terms").font(.title2)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(terms.notice)
                    Text("Your use of Gemma is governed by the Gemma Terms of Use and its Prohibited Use Policy below. Agreeing to download means you agree to comply with both, including the use restrictions in Section 3.2.")
                    Text("Terms of Use").font(.headline)
                    Text(terms.terms)
                    Text("Prohibited Use Policy").font(.headline)
                    Text(terms.restrictions)
                }
                .textSelection(.enabled)
            }
            HStack {
                Button("Cancel", role: .cancel) { dismiss() }
                Spacer()
                Button("Agree and download", action: agree).buttonStyle(.borderedProminent)
            }
        }
        .padding()
    }
}
