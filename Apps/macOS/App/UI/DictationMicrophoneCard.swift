import LegatoAudio
import SwiftUI

/// Settings, Voice: which microphone dictation and Magic record from. Meetings keep their own automatic choice.
/// The choice is stored by device UID; a chosen device that is not connected falls back to Automatic.
struct DictationMicrophoneCard: View {
    @AppStorage(MicrophonePreference.dictationKey) private var stored = MicrophonePreference.automatic.storageValue
    @AppStorage(MicrophonePreference.dictationNameKey) private var storedName = ""
    @State private var inputs: [AudioInputCandidate] = []

    var body: some View {
        SettingsCard {
            VStack(alignment: .leading, spacing: 14) {
                Label("Microphone", systemImage: "mic").font(.headline)
                Picker("Dictation microphone", selection: selection) {
                    Text("Automatic").tag(MicrophonePreference.automatic.storageValue)
                    Text("System default").tag(MicrophonePreference.systemDefault.storageValue)
                    if !inputs.isEmpty || missing { Divider() }
                    ForEach(inputs, id: \.preferenceUID) { input in
                        Text(input.name).tag(MicrophonePreference.device(uid: input.preferenceUID).storageValue)
                    }
                    if missing {
                        Text("\(storedName.isEmpty ? "Chosen microphone" : storedName) (not connected)").tag(stored)
                    }
                }
                .accessibilityIdentifier("settings.dictationMicrophone")
                Text(explanation)
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        // Inputs come and go (an iPhone nearby, a USB headset): list them again while Settings is open.
        .task {
            while !Task.isCancelled {
                let all = await AutomaticInputSource.availableInputs()
                inputs = all.filter(\.isSelectable).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private var selection: Binding<String> {
        Binding(get: { stored }, set: { value in
            stored = value
            if case .device(let uid) = MicrophonePreference(storageValue: value) {
                storedName = inputs.first { $0.preferenceUID == uid }?.name ?? storedName
            }
        })
    }

    /// A device was chosen that is not in the list now.
    private var missing: Bool {
        guard case .device(let uid) = MicrophonePreference(storageValue: stored) else { return false }
        return !inputs.contains { $0.preferenceUID == uid }
    }

    private var explanation: String {
        if missing { return "That microphone is not connected, so dictation uses Automatic until it is back." }
        switch MicrophonePreference(storageValue: stored) {
        case .automatic:
            return "Automatic prefers the Mac's built-in microphone, then a wired or USB one, then AirPods, and a nearby iPhone or iPad last, "
                + "whatever macOS made the default. Meetings always choose automatically."
        case .systemDefault:
            return "Uses the input selected in System Settings, Sound. If it fails, dictation falls back to Automatic."
        case .device:
            return "Dictation and Magic record from this microphone. If it fails or is unplugged, they fall back to Automatic."
        }
    }
}
