import SwiftUI

/// Onboarding until dictation can start, then a plain status screen. (The full Home, History and
/// Settings screens come in a later task.)
struct RootView: View {
    let controller: AppController
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            if controller.status.isReady {
                StatusView(controller: controller)
            } else {
                OnboardingView(controller: controller)
            }
        }
        .task { await controller.refreshReadiness() }
        .task { await controller.refreshLastTranscript() }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task {
                await controller.refreshReadiness()
                await controller.refreshLastTranscript()
            }
        }
    }
}

private struct StatusView: View {
    let controller: AppController

    var body: some View {
        VStack(spacing: 20) {
            Label(controller.isDictating ? "Listening" : "Ready", systemImage: controller.isDictating ? "mic.fill" : "mic")
                .font(.title2.bold())
            Button(controller.isDictating ? "Stop" : "Dictate") {
                Task { _ = await controller.toggle() }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            if let text = controller.lastTranscript {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Last transcript").font(.headline)
                    ScrollView { Text(text).frame(maxWidth: .infinity, alignment: .leading) }
                    Button("Copy") { controller.pasteboard.forceWrite(text) }
                        .buttonStyle(.bordered)
                }
            }
            Spacer()
        }
        .padding()
    }
}
