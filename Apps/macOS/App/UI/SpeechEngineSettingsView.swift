import LegatoAppServices
import LegatoModels
import SwiftUI

/// The live dictation engine: Apple Speech (the default, nothing to download) or one of the streaming model
/// families. Clicking a family installs and warms its chosen latency tier, then switches; the previous engine
/// stays live until then. Only the chosen tier downloads; each downloaded tier can be deleted on its own.
struct SpeechEngineSettingsView: View {
    @Environment(MacAppController.self) private var controller

    @State private var selected: String?
    @State private var activeFamilyID: String?
    @State private var tiers: [String: Int] = [:]
    /// The family whose pick is waiting for its install.
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
                    reload()
                    Task { await controller.refreshEngine() }
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Apple Speech")
                            Text("Built in · nothing to download").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if selected == nil { Image(systemName: "checkmark").foregroundStyle(.tint) }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                ForEach(models.streamingFamilies) { family in
                    FamilyRow(
                        family: family, manager: models.manager, isActive: activeFamilyID == family.id,
                        tierMs: tiers[family.id], isPending: pending == family.id, failure: failures[family.id],
                        onPick: { pick(family) }, onTier: { setTier($0, of: family) },
                        onDelete: { delete($0, of: family) }, onCancel: { cancel($0, of: family) })
                }
            } header: {
                Text("Engine")
            } footer: {
                Text("Picking a model downloads and prepares it first; dictation keeps using the current engine until it is ready. Latency is the audio the model waits for: a shorter wait shows words sooner, a longer one is more accurate. Only the tier you choose is downloaded. Now in use: \(controller.engineStatus.name)\(controller.engineStatus.fallback.map { " (\($0))" } ?? "").")
                    .font(.callout).foregroundStyle(.secondary)
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
                    .font(.callout).foregroundStyle(.secondary)
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
                Text("Downloaded models only. Shorter types text sooner; longer keeps a sentence together.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            reload()
            languages = Set(models.engineSettings.preferredLocales.map { $0.language.languageCode?.identifier ?? $0.identifier })
            silenceMs = Double(models.engineSettings.silenceMs)
        }
        .onChange(of: controller.engineStatus) { _, _ in reload() }
    }

    private func reload() {
        selected = models.selected(.liveDictation)
        activeFamilyID = models.activeFamily?.id
        tiers = Dictionary(uniqueKeysWithValues: models.streamingFamilies.compactMap { family in
            models.chosenTier(of: family).map { (family.id, $0) }
        })
    }

    private func pick(_ family: ModelFamily) {
        guard activeFamilyID != family.id else { return }
        failures[family.id] = nil
        pending = family.id
        models.pick(family: family) { finished(family, $0) }
    }

    private func setTier(_ tierMs: Int, of family: ModelFamily) {
        failures[family.id] = nil
        let isLive = activeFamilyID == family.id
        let switching = models.setTier(tierMs, of: family, done: { finished(family, $0) })
        reload()
        // The live pick stays on the old tier until the new one is installed; the picker shows the target.
        if switching, isLive { pending = family.id; tiers[family.id] = tierMs }
    }

    private func finished(_ family: ModelFamily, _ error: (any Error)?) {
        if pending == family.id { pending = nil }
        if let error { failures[family.id] = String(describing: error) }
        reload()
        Task { await controller.refreshEngine() }
    }

    /// Stops a tier's download: the pick waiting for it ends without switching and without an error.
    private func cancel(_ id: String, of family: ModelFamily) {
        if pending == family.id { pending = nil }
        Task {
            await models.cancelDownload(id)
            reload()
        }
    }

    private func delete(_ tier: InstalledTier?, of family: ModelFamily) {
        if pending == family.id { pending = nil }
        Task {
            if let tier {
                await models.manager.delete(tier.id)
            } else {
                await models.manager.delete(family: family)
            }
            reload()
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
