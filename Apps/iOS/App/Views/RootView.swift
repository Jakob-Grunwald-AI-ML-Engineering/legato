import SwiftUI

/// Onboarding until dictation can start, then Home (with History and Settings one tap away).
struct RootView: View {
    let controller: AppController
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            if controller.status.isReady {
                NavigationStack { HomeView(controller: controller) }
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
