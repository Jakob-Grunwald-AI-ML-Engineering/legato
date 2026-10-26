import LegatoAppServices
import LegatoCore
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
    @State private var backend = Settings.cleanupBackend
    @State private var itn = Settings.cleanupITN
    @State private var timeout = Double(Settings.cleanupTimeoutSeconds)
    @State private var selectedMLX: String?
    @State private var pending: String?
    @State private var failures: [String: String] = [:]

    private var models: ModelServices { controller.models }

    private var selectedMLXName: String? {
        selectedMLX.flatMap { id in models.cleanupModels.first { $0.id == id }?.displayName }
    }

    var body: some View {
        Form {
            Section {
                Toggle("Clean up dictation", isOn: $enabled)
                    .accessibilityIdentifier("cleanup.enabled")
            } footer: {
                Text("After you stop, a language model on this iPhone adds punctuation and fixes misheard words. History keeps the raw text next to the cleaned one.")
            }

            Section {
                Picker("Delivery", selection: $delivery) {
                    Text("Replace").tag(CleanupDelivery.replace)
                    Text("Clipboard").tag(CleanupDelivery.clipboard)
                    Text("Hold").tag(CleanupDelivery.hold)
                }
                .accessibilityIdentifier("cleanup.delivery")
            } header: {
                Text("In the Legato keyboard")
            } footer: {
                Text(Self.explain(delivery))
            }

            Section {
                Picker("Style", selection: $style) {
                    Text("Verbatim").tag(CleanupStyle.verbatim)
                    Text("Message").tag(CleanupStyle.message)
                }
            } footer: {
                Text(style == .verbatim
                    ? "Verbatim: punctuation, casing, numbers and misheard words. Every word stays."
                    : "Message: also drops fillers and false starts and applies corrections like \"Friday, no wait, Thursday\". The keyboard's Refine key always uses Message.")
            }

            Section {
                backendRow("Auto", detail: "Your MLX model in the foreground, else Apple Foundation Models", choice: .auto)
                backendRow("Apple Foundation Models", detail: "Built in (Apple Intelligence) · works in the background", choice: .foundationModels)
                ForEach(models.cleanupModels) { descriptor in
                    ModelRow(
                        descriptor: descriptor, manager: models.manager,
                        isSelected: backend == .mlx && selectedMLX == descriptor.id,
                        isPending: pending == descriptor.id, failure: failures[descriptor.id]
                    ) { pickMLX(descriptor.id) }
                    .swipeActions {
                        Button("Delete", role: .destructive) { delete(descriptor.id) }
                    }
                }
            } header: {
                Text("Backend")
            } footer: {
                Text("MLX models need the app in front (no GPU in the background): a dictation from the background uses Apple Foundation Models instead. Picking a model downloads it first. Auto uses the MLX model picked last: \(selectedMLXName ?? "none yet").")
            }

            Section {
                Toggle("Number normalization (ITN)", isOn: $itn)
                VStack(alignment: .leading) {
                    Text("Time limit: \(Int(timeout)) s")
                    Slider(value: $timeout, in: 1 ... 10, step: 1)
                }
            } header: {
                Text("Advanced")
            } footer: {
                Text("ITN turns spoken numbers into digits before the model (English only). Off by default: it merges \"ten thirty\" into \"40\". The time limit applies to each step; past it the raw text is kept.")
            }
        }
        .navigationTitle("Cleanup")
        .onAppear { selectedMLX = models.selected(.cleanup) }
        .onChange(of: enabled) { _, new in Settings.cleanupEnabled = new }
        .onChange(of: delivery) { _, new in Settings.cleanupDelivery = new }
        .onChange(of: style) { _, new in Settings.cleanupStyle = new }
        .onChange(of: backend) { _, new in Settings.cleanupBackend = new }
        .onChange(of: itn) { _, new in Settings.cleanupITN = new }
        .onChange(of: timeout) { _, new in Settings.cleanupTimeoutSeconds = Int(new) }
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

    private func pickMLX(_ id: String) {
        failures[id] = nil
        pending = id
        models.pick(id, role: .cleanup) { error in
            if pending == id { pending = nil }
            if let error {
                failures[id] = String(describing: error)
            } else {
                selectedMLX = models.selected(.cleanup)
                backend = .mlx
            }
        }
    }

    private func delete(_ id: String) {
        if pending == id { pending = nil }
        Task {
            await models.manager.delete(id)
            selectedMLX = models.selected(.cleanup)
            if selectedMLX == nil, backend == .mlx { backend = .auto }
        }
    }

    static func explain(_ delivery: CleanupDelivery) -> String {
        switch delivery {
        case .replace:
            "Replace: the raw text streams in while you speak and is swapped for the cleaned text when you stop. If you typed after it meanwhile, the field is left alone and the cleaned text goes to the clipboard."
        case .clipboard:
            "Clipboard: the field keeps the raw text; the cleaned text goes to the clipboard."
        case .hold:
            "Hold: nothing is typed while you speak (the keyboard's top bar shows the live text); the cleaned text is inserted when you stop."
        }
    }
}
