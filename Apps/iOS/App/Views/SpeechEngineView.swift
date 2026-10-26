import LegatoEngines
import LegatoModels
import SwiftUI

/// The live dictation engine: Apple Speech (the default, nothing to download) or one of the streaming
/// catalog models. Tapping a model installs and warms it, then switches; the previous engine stays live
/// until then. Swipe to delete a downloaded model.
struct SpeechEngineView: View {
    let controller: AppController

    @State private var selected: String?
    @State private var pending: String?
    @State private var failures: [String: String] = [:]
    @State private var languages: Set<String> = []
    @State private var silenceMs: Double = 1200

    static let offeredLanguages: [(code: String, name: String)] = [
        ("de", "German"), ("en", "English"), ("fr", "French"), ("es", "Spanish"), ("it", "Italian"), ("pt", "Portuguese"),
    ]

    private var models: ModelServices { controller.models }

    var body: some View {
        Form {
            Section {
                Button {
                    pending = nil
                    models.clearPick(.liveDictation)
                    selected = nil
                    Task { await controller.refreshEngine() }
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Apple Speech").foregroundStyle(.primary)
                            Text("Built in · nothing to download").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if selected == nil { Image(systemName: "checkmark").foregroundStyle(.tint) }
                    }
                }
                .accessibilityIdentifier("engine.apple")
                ForEach(models.streamingModels) { descriptor in
                    ModelRow(
                        descriptor: descriptor, manager: models.manager, isSelected: selected == descriptor.id,
                        isPending: pending == descriptor.id, failure: failures[descriptor.id]
                    ) { pick(descriptor.id) }
                    .swipeActions {
                        Button("Delete", role: .destructive) { delete(descriptor.id) }
                    }
                }
            } header: {
                Text("Engine")
            } footer: {
                Text("Picking a model downloads and prepares it first; dictation keeps using the current engine until it is ready. Swipe left on a model to delete it. Now in use: \(controller.engineStatus.name)\(controller.engineStatus.fallback.map { " (\($0))" } ?? "").")
            }

            Section {
                ForEach(Self.offeredLanguages, id: \.code) { language in
                    Toggle(language.name, isOn: Binding(
                        get: { languages.contains(language.code) },
                        set: { on in
                            if on { languages.insert(language.code) } else { languages.remove(language.code) }
                            saveLanguages()
                        }))
                }
            } header: {
                Text("Languages")
            } footer: {
                Text(languages.isEmpty
                    ? "None selected: the model detects the language (auto). Applies to the downloaded models."
                    : "The model expects these languages. With exactly one, cleanup also writes in it.")
            }

            Section {
                VStack(alignment: .leading) {
                    Text("End a segment after \(Int(silenceMs)) ms of silence")
                    Slider(value: $silenceMs, in: 300 ... 2000, step: 50) { editing in
                        if !editing { saveSilence() }
                    }
                }
            } header: {
                Text("Silence")
            } footer: {
                Text("Downloaded models only. Shorter commits text sooner; longer keeps a sentence together.")
            }
        }
        .navigationTitle("Speech engine")
        .onAppear {
            selected = models.selected(.liveDictation)
            languages = Set(models.engineSettings.preferredLocales.map { $0.language.languageCode?.identifier ?? $0.identifier })
            silenceMs = Double(models.engineSettings.silenceMs)
        }
    }

    private func pick(_ id: String) {
        guard id != selected else { return }
        failures[id] = nil
        pending = id
        models.pick(id, role: .liveDictation) { error in
            if pending == id { pending = nil }
            if let error {
                failures[id] = String(describing: error)
            } else {
                selected = models.selected(.liveDictation)
            }
            Task { await controller.refreshEngine() }
        }
    }

    private func delete(_ id: String) {
        if pending == id { pending = nil }
        Task {
            await models.manager.delete(id)
            selected = models.selected(.liveDictation)
            await controller.refreshEngine()
        }
    }

    private func saveLanguages() {
        let ordered = Self.offeredLanguages.map(\.code).filter(languages.contains)
        models.engineSettings.preferredLocales = ordered.map(Locale.init(identifier:))
        Task { await controller.refreshEngine() }
    }

    private func saveSilence() {
        models.engineSettings.silenceMs = Int(silenceMs)
        Task { await controller.refreshEngine() }
    }
}
