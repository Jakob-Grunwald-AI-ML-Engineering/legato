import LegatoAppServices
import LegatoCore
import LegatoModels
import LegatoPostProcessing
import SwiftUI

/// Cleanup after dictation: on/off, how the cleaned text reaches the field, the style, the backend, ITN
/// and the time limit, plus what the last dictation actually ran.
struct CleanupSettingsView: View {
    @Environment(MacAppController.self) private var controller

    @State private var selectedMLX: String?
    @State private var pending: String?
    @State private var failures: [String: String] = [:]

    private var models: ModelServices { controller.models }

    private var selectedMLXName: String? {
        selectedMLX.flatMap { id in models.cleanupModels.first { $0.id == id }?.displayName }
    }

    var body: some View {
        @Bindable var settings = controller.settings
        Form {
            Section {
                Toggle("Clean up dictation", isOn: $settings.cleanupEnabled)
            } footer: {
                Text("A language model on this Mac adds punctuation and fixes misheard words (after you stop, or phrase by phrase with Live). History keeps the raw text next to the cleaned one.")
                    .font(.callout).foregroundStyle(.secondary)
            }

            Section {
                Picker("Delivery", selection: $settings.cleanupDelivery) {
                    ForEach(CleanupDelivery.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Picker("Style", selection: $settings.cleanupStyle) {
                    Text("Verbatim").tag(CleanupStyle.verbatim)
                    Text("Message").tag(CleanupStyle.message)
                }
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    Text(settings.cleanupDelivery.explanation)
                    Text(settings.cleanupStyle == .verbatim
                        ? "Verbatim: punctuation, casing, numbers and misheard words. Every word stays."
                        : "Message: also drops fillers and false starts and applies corrections like \"Friday, no wait, Thursday\". Refine always uses Message.")
                }
                .font(.callout).foregroundStyle(.secondary)
            }

            Section {
                backendRow("Auto", detail: "Your selected model; Apple Foundation Models when none is selected", choice: .auto)
                backendRow("Apple Foundation Models", detail: "Built in (Apple Intelligence)", choice: .foundationModels)
                ForEach(models.cleanupModels) { descriptor in
                    ModelRow(
                        descriptor: descriptor, manager: models.manager,
                        isSelected: settings.cleanupBackend == models.cleanupChoice(for: descriptor.id) && selectedMLX == descriptor.id,
                        isPending: pending == descriptor.id, failure: failures[descriptor.id],
                        onPick: { pickMLX(descriptor.id) }, onDelete: { delete(descriptor.id) },
                        onCancel: { cancelDownload(descriptor.id) })
                }
            } header: {
                Text("Backend")
            } footer: {
                Text("Picking a model downloads it first. Auto uses the model picked last: \(selectedMLXName ?? "none yet").")
                    .font(.callout).foregroundStyle(.secondary)
            }

            Section {
                Toggle("Number normalization (ITN)", isOn: $settings.cleanupITN)
                VStack(alignment: .leading) {
                    Text("Time limit: \(settings.cleanupTimeoutSeconds) s")
                    Slider(
                        value: Binding(
                            get: { Double(settings.cleanupTimeoutSeconds) },
                            set: { settings.cleanupTimeoutSeconds = Int($0) }),
                        in: 1 ... 10, step: 1)
                }
            } header: {
                Text("Advanced")
            } footer: {
                Text("ITN turns spoken numbers into digits before the model (English only). Off by default: it merges \"ten thirty\" into \"40\". The time limit applies to each step; past it the raw text is kept.")
                    .font(.callout).foregroundStyle(.secondary)
            }

            LastDictationSection()
        }
        .formStyle(.grouped)
        .onAppear { selectedMLX = models.selected(.cleanup) }
        .onChange(of: settings.cleanupEnabled) { _, _ in controller.cleanupSettingsChanged() }
        .onChange(of: settings.cleanupBackend) { _, _ in controller.cleanupSettingsChanged() }
    }

    private func backendRow(_ title: String, detail: String, choice: CleanupBackendChoice) -> some View {
        Button {
            controller.settings.cleanupBackend = choice
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if controller.settings.cleanupBackend == choice { Image(systemName: "checkmark").foregroundStyle(.tint) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func pickMLX(_ id: String) {
        failures[id] = nil
        pending = id
        models.pick(id, role: .cleanup) { error in
            if pending == id { pending = nil }
            if let error {
                failures[id] = String(describing: error)
            } else {
                selectedMLX = models.selected(.cleanup)
                controller.settings.cleanupBackend = models.cleanupChoice(for: id)
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
            selectedMLX = models.selected(.cleanup)
            if selectedMLX == nil,
               controller.settings.cleanupBackend == .mlx || controller.settings.cleanupBackend == .coreML {
                controller.settings.cleanupBackend = .auto
            }
            controller.cleanupSettingsChanged()
        }
    }
}

/// What actually ran last: the engine and duration from the newest history entry, the cleanup backend from
/// the last cleanup run (with why a preferred backend was passed over).
struct LastDictationSection: View {
    @Environment(MacAppController.self) private var controller

    var body: some View {
        let entry = controller.recent.first
        let report = controller.cleanupReports.last
        if entry != nil || report != nil {
            Section("Last dictation") {
                if let entry {
                    LabeledContent("Engine", value: controller.models.engineName(for: entry.engineID))
                    LabeledContent("Duration", value: Duration.seconds(entry.duration)
                        .formatted(.units(allowed: [.minutes, .seconds], width: .abbreviated, fractionalPart: .show(length: 1))))
                    LabeledContent("Cleaned", value: entry.rawText == nil ? "No change" : "Changed")
                }
                if let report {
                    LabeledContent(report.refine ? "Refine backend" : "Cleanup backend", value: report.backend)
                    LabeledContent("Outcome", value: report.outcome)
                    if let device = report.device { LabeledContent("Device", value: device) }
                    LabeledContent("Took", value: "\(report.milliseconds) ms · \(report.style.rawValue)")
                    ForEach(report.skipped, id: \.self) { reason in
                        Text("Skipped: \(reason)").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}
