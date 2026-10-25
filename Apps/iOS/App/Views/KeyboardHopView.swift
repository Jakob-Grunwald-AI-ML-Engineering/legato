import SwiftUI

/// Shown when the Legato keyboard sends the user here to dictate: the words as they come, Stop, and
/// how to get back. iOS can't return to the previous app on its own; it shows its own "◀" link at the
/// top left, or the user swipes back.
struct KeyboardHopView: View {
    let controller: AppController

    var body: some View {
        VStack(spacing: 24) {
            Spacer(minLength: 0)
            Image(systemName: controller.keyboardRunActive ? "waveform" : "checkmark.circle")
                .font(.system(size: 56))
                .symbolEffect(.variableColor.iterative, isActive: controller.keyboardRunActive)
                .foregroundStyle(.tint)
            Text(controller.keyboardRunActive ? "Listening" : "Ready")
                .font(.title2.bold())
            Text("Tap ◀ at the top left, or swipe back, to return to your app. Your words appear there.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)

            ScrollView {
                Text(controller.liveText.isEmpty ? " " : controller.liveText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("hop.liveText")
            }
            .frame(maxHeight: 160)

            if controller.keyboardRunActive {
                Button(role: .destructive) {
                    Task { await controller.stopIfRunning() }
                } label: {
                    Label("Stop", systemImage: "stop.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            } else {
                Button("Done") { controller.dismissKeyboardHop() }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
            }
            Spacer(minLength: 0)
        }
        .padding()
    }
}
