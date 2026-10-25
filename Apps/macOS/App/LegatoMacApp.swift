import SwiftUI

@main
struct LegatoMacApp: App {
    private let controller = MacAppController.shared

    init() {
        MacAppController.shared.bootstrap()
    }

    var body: some Scene {
        MenuBarExtra {
            MenuContent()
                .environment(controller)
        } label: {
            MenuBarLabel()
                .environment(controller)
        }
        .menuBarExtraStyle(.window)

        Window("Set up Legato", id: MacAppController.onboardingWindowID) {
            OnboardingView()
                .environment(controller)
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.suppressed)

        Settings {
            SettingsView()
                .environment(controller)
        }
    }
}

/// The menu-bar icon. It is always on screen, so it also relays the controller's requests to open
/// the onboarding window (a view is the only place the `openWindow` action exists).
private struct MenuBarLabel: View {
    @Environment(MacAppController.self) private var controller
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Image(systemName: controller.isDictating ? "waveform.circle.fill" : "waveform")
            .onChange(of: controller.onboardingRequests, initial: true) { _, count in
                guard count > 0 else { return }
                NSApp.activate()
                openWindow(id: MacAppController.onboardingWindowID)
            }
    }
}
