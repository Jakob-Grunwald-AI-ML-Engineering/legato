import SwiftUI

/// Shown when the Legato keyboard sends the user here: the keyboard has no microphone, so its first tap
/// only readies the mic here. The screen says so and how to get back; the next tap on the keyboard
/// starts the dictation. iOS can't return to the previous app on its own; it shows its own "◀" link at
/// the top left, or the user swipes back.
struct KeyboardHopView: View {
    let controller: AppController

    var body: some View {
        VStack(spacing: 24) {
            Spacer(minLength: 0)
            switch controller.keyboardHopState {
            case .running:
                run
            case .ready:
                ready
            case .failed(let failure):
                failed(failure)
            case .preparing:
                ProgressView("Getting the microphone ready…")
                    .accessibilityIdentifier("hop.arming")
            }
            Spacer(minLength: 0)
        }
        .padding()
    }

    /// The microphone is armed; nothing is recording.
    private var ready: some View {
        VStack(spacing: 24) {
            Image(systemName: "mic.circle")
                .font(.system(size: 56))
                .foregroundStyle(.tint)
            Text("Microphone ready")
                .font(.title2.bold())
                .accessibilityIdentifier("hop.ready")
            if controller.recognitionPreparing {
                Text("Your selected speech model is still preparing. You can return to the keyboard; dictation will wait for it.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            }
            Text("Go back with ◀ at the top left, or swipe back, then tap the microphone key on the keyboard to dictate.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button("Done") { controller.dismissKeyboardHop() }
                .buttonStyle(.bordered)
                .controlSize(.large)
        }
    }

    private func failed(_ message: String) -> some View {
        VStack(spacing: 24) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 56))
                .foregroundStyle(.orange)
            Text("Microphone not ready")
                .font(.title2.bold())
            Text(message)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button("Done") { controller.dismissKeyboardHop() }
                .buttonStyle(.bordered)
                .controlSize(.large)
        }
    }

    /// A dictation is running while the screen is up (for instance from the Action Button).
    private var run: some View {
        VStack(spacing: 24) {
            Image(systemName: "waveform")
                .font(.system(size: 56))
                .symbolEffect(.variableColor.iterative)
                .foregroundStyle(.tint)
            Text("Listening")
                .font(.title2.bold())
            ScrollView {
                Text(controller.liveText.isEmpty ? " " : controller.liveText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("hop.liveText")
            }
            .frame(maxHeight: 160)
            Button(role: .destructive) {
                Task { await controller.stopIfRunning() }
            } label: {
                Label("Stop", systemImage: "stop.fill").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
    }
}
